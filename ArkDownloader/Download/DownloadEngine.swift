import Foundation

/// Multi-connection download engine. Mirrors the Android DownloadEngine.
/// All DB access goes through AppDatabase actor; scheduling is serialized via this actor.
actor DownloadEngine {
    private let db = AppDatabase.shared
    private let settingsRepo = SettingsRepository.shared
    private let downloader = ChunkDownloader()

    private var jobs: [String: Task<Void, Never>] = [:]
    private var runtimes: [String: TaskRuntime] = [:]
    private var activeCount: Int = 0

    private let progressIntervalMs: UInt64 = 500_000_000 // 0.5s in nanoseconds
    private let maxChunkRetries = 5

    func observeTasks() async -> [TaskEntity] {
        await db.getAll()
    }

    func getTask(_ id: String) async -> TaskEntity? {
        await db.getById(id)
    }

    func createTask(
        url: String,
        fileName: String?,
        saveDir: String?,
        threads: Int?,
        chunkSize: Int?,
        totalSize: Int64?,
        userAgent: String?,
        headers: [String: String]?
    ) async throws -> TaskEntity {
        let settings = settingsRepo.current()
        let resolved = UrlResolve.resolve(url, nameHint: fileName, sizeHint: totalSize ?? 0)
        let kind = resolved.kind
        let id = UUID().uuidString
        let dir = FilePublish.resolveWritableDir(saveDir?.isEmpty == false ? saveDir : (settings.defaultSaveDir.isEmpty ? nil : settings.defaultSaveDir))

        var mergedHeaders = FormatUtil.parseHeaders(settings.defaultHeadersJson)
        if let h = headers { mergedHeaders.merge(h) { _, new in new } }
        let ua = UrlResolve.pickUserAgent(kind, settings, override: userAgent)
        let th = (threads ?? settings.maxThreads).clamped(to: 1...AppSettings.maxThreads)
        let requestedChunk = chunkSize ?? settings.chunkSize
        let cs = UrlResolve.chunkBytes(requestedChunk, kind)

        var total = resolved.size
        var contentDisposition: String? = nil
        if kind == .http {
            let needSize = total <= 0
            let provisional = UrlResolve.canonicalFileName(url: resolved.url, contentDisposition: nil, nameHint: fileName)
            let needNameProbe = UrlResolve.isQuarkOrCdnUrl(resolved.url) ||
                provisional == "download.bin" || (fileName?.isEmpty ?? true)
            if needSize || needNameProbe {
                let probe = await downloader.probe(
                    url: resolved.url, headers: mergedHeaders, userAgent: ua,
                    knownSize: needSize ? -1 : total, skipHead: false, forceHeaders: needNameProbe)
                if needSize && probe.totalSize > 0 { total = probe.totalSize }
                contentDisposition = probe.contentDisposition
            }
        }
        let resolvedName = UrlResolve.canonicalFileName(url: resolved.url, contentDisposition: contentDisposition, nameHint: fileName)
        guard total > 0 else {
            throw NSError(domain: "ArkDownloader", code: 0, userInfo: [NSLocalizedDescriptionKey: "无法获取文件大小，请检查链接是否有效"])
        }

        let (relativeDir, baseName) = UrlResolve.splitRelativeDownloadPath(resolvedName)
        let destDir = relativeDir.isEmpty ? dir : dir.appendingPathComponent(relativeDir)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let uniqueName = uniqueFileName(destDir, baseName)
        let outFile = destDir.appendingPathComponent(uniqueName)
        let storedName = relativeDir.isEmpty ? uniqueName : "\(relativeDir)/\(uniqueName)"
        let initialStatus: TaskStatus = settings.autoStart ? .pending : .paused
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let entity = TaskEntity(id: id, url: resolved.url, fileName: storedName, saveDir: destDir.path,
            filePath: outFile.path, stagingPath: outFile.path, totalSize: total, loaded: 0, speed: 0,
            status: initialStatus.rawValue, errorMsg: nil, threads: th, chunkSize: cs, userAgent: ua,
            headersJson: FormatUtil.headersToJson(mergedHeaders), createdAt: now, startedAt: nil, completedAt: nil)
        await db.upsert(entity)
        await prepareChunks(entity)
        if settings.autoStart {
            await scheduleNow(entity.id)
        }
        return entity
    }

    func createFolderTask(
        folderName: String,
        children: [FolderChildFile],
        saveDir: String?,
        threads: Int?,
        chunkSize: Int?
    ) async throws -> TaskEntity {
        guard !children.isEmpty else {
            throw NSError(domain: "ArkDownloader", code: 0, userInfo: [NSLocalizedDescriptionKey: "folder has no files"])
        }
        let settings = settingsRepo.current()
        let id = UUID().uuidString
        let root = FilePublish.resolveWritableDir(saveDir?.isEmpty == false ? saveDir : (settings.defaultSaveDir.isEmpty ? nil : settings.defaultSaveDir))
        let safeFolder = UrlResolve.sanitizePathSegment(folderName.isEmpty ? "folder" : folderName)
        let folderDir = root.appendingPathComponent(safeFolder)
        try? FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        let th = (threads ?? settings.maxThreads).clamped(to: 1...AppSettings.maxThreads)
        let kindHint: UrlResolve.Kind = children.contains { UrlResolve.isBaiduUrl($0.url) } ? .baidu : .http
        let cs = UrlResolve.chunkBytes(chunkSize ?? settings.chunkSize, kindHint)
        let normalized = children.map { child -> FolderChildFile in
            let rel = child.relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let ensured = rel.hasPrefix("\(safeFolder)/") ? rel : "\(safeFolder)/\(rel)"
            var c = child
            c.name = child.name.isEmpty ? String(ensured.split(separator: "/").last ?? "download.bin") : child.name
            c.relativePath = ensured
            return c
        }
        let total = normalized.reduce(0) { $0 + max($1.size, 0) }
        let firstPending = normalized.first { !$0.completed } ?? normalized[0]
        let initialStatus: TaskStatus = settings.autoStart ? .pending : .paused
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let entity = TaskEntity(id: id, url: firstPending.url, fileName: safeFolder, saveDir: root.path,
            filePath: folderDir.path, stagingPath: folderDir.path, totalSize: total,
            loaded: normalized.filter { $0.completed }.reduce(0) { $0 + max($1.size, 0) },
            speed: 0, status: initialStatus.rawValue, errorMsg: nil, threads: th, chunkSize: cs,
            userAgent: firstPending.userAgent, headersJson: firstPending.headersJson.isEmpty ? "{}" : firstPending.headersJson,
            createdAt: now, startedAt: nil, completedAt: nil, isFolder: true,
            folderChildrenJson: FolderChildFile.encodeList(normalized), currentFileName: firstPending.relativePath,
            filesCompleted: normalized.filter { $0.completed }.count, filesTotal: normalized.count)
        await db.upsert(entity)
        if settings.autoStart { await scheduleNow(entity.id) }
        return entity
    }

    private func uniqueFileName(_ dir: URL, _ desired: String) -> String {
        let safe = UrlResolve.sanitizeFileName(desired.isEmpty ? "download.bin" : desired)
        let fileURL = dir.appendingPathComponent(safe)
        if !FileManager.default.fileExists(atPath: fileURL.path) { return safe }
        let dot = safe.lastIndex(of: ".")
        let base = dot != nil ? String(safe[..<dot!]) : safe
        let ext = dot != nil ? String(safe[dot!...]) : ""
        for i in 1..<10_000 {
            let name = "\(base) (\(i))\(ext)"
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        }
        return "\(base)-\(Int64(Date().timeIntervalSince1970))\(ext)"
    }

    private func prepareChunks(_ task: TaskEntity) async {
        let existing = await db.getChunks(task.id)
        if !existing.isEmpty { return }
        let ranges = ChunkDownloader.buildChunks(totalSize: task.totalSize, chunkSize: task.chunkSize)
        let chunks = ranges.enumerated().map { (index, range) -> ChunkEntity in
            ChunkEntity(taskId: task.id, index: index, start: range.lowerBound, end: range.upperBound,
                loaded: 0, completed: false, partPath: "")
        }
        await db.upsertChunks(chunks)
        writeSidecar(task, completed: [])
    }

    func schedule(_ taskId: String) {
        Task { await scheduleNow(taskId) }
    }

    private func scheduleNow(_ taskId: String) async {
        await startIfSlotAvailable(taskId)
    }

    private func pumpQueue() {
        Task {
            let settings = settingsRepo.current()
            let waiting = (await db.getAll()).filter {
                $0.status == TaskStatus.pending.rawValue && jobs[$0.id]?.isCancelled == false
            }.sorted { $0.createdAt < $1.createdAt }
            for t in waiting {
                if activeJobCount() >= settings.maxConcurrentTasks { break }
                await startIfSlotAvailable(t.id)
            }
        }
    }

    private func activeJobCount() -> Int {
        jobs.values.filter { !$0.isCancelled }.count
    }

    private func fairWorkerCount(_ requested: Int, _ kind: UrlResolve.Kind) -> Int {
        let running = max(activeJobCount(), 1)
        let hardCap = kind == .baidu ? 8 : 12
        let want = requested.clamped(to: 1...hardCap)
        let fair = (48 / running).clamped(to: 2...hardCap)
        return min(want, fair)
    }

    private func startIfSlotAvailable(_ taskId: String) async {
        if let existing = jobs[taskId], !existing.isCancelled { return }
        jobs[taskId]?.cancel()
        jobs.removeValue(forKey: taskId)
        guard let task = await db.getById(taskId) else { return }
        guard task.status == TaskStatus.pending.rawValue else { return }
        let settings = settingsRepo.current()
        if activeJobCount() >= settings.maxConcurrentTasks { return }

        let job = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.jobs.removeValue(forKey: taskId)
                self.runtimes.removeValue(forKey: taskId)
                self.activeCount = self.activeJobCount()
                self.pumpQueue()
            }
            await self.runTask(taskId)
        }
        jobs[taskId] = job
        activeCount = activeJobCount()
    }

    func pauseTask(_ id: String) async {
        if let rt = runtimes[id] {
            rt.pauseRequested = true
            rt.cancelAllCalls()
        }
        jobs[id]?.cancel()
        jobs.removeValue(forKey: id)
        runtimes.removeValue(forKey: id)
        if let task = await db.getById(id) {
            var t = task
            t.status = TaskStatus.paused.rawValue
            t.speed = 0
            t.errorMsg = nil
            await db.upsert(t)
        }
        activeCount = activeJobCount()
        pumpQueue()
    }

    func resumeTask(_ id: String) async {
        guard let task = await db.getById(id) else { return }
        guard task.status != TaskStatus.completed.rawValue else { return }
        var t = task
        t.status = TaskStatus.pending.rawValue
        t.errorMsg = nil
        t.speed = 0
        await db.upsert(t)
        await scheduleNow(id)
    }

    func cancelTask(_ id: String) async {
        if let rt = runtimes[id] {
            rt.cancelRequested = true
            rt.pauseRequested = true
            rt.cancelAllCalls()
        }
        jobs[id]?.cancel()
        jobs.removeValue(forKey: id)
        runtimes.removeValue(forKey: id)
        await updateStatus(id, status: .canceled)
        activeCount = activeJobCount()
        pumpQueue()
    }

    func restartTask(_ id: String) async {
        guard let task = await db.getById(id) else { return }
        runtimes[id]?.cancelAllCalls()
        jobs[id]?.cancel()
        jobs.removeValue(forKey: id)
        runtimes.removeValue(forKey: id)
        deleteSidecar(task)
        await db.deleteChunks(id)
        if task.isFolder {
            var children = FolderChildFile.decodeList(task.folderChildrenJson)
            for i in children.indices {
                let f = URL(fileURLWithPath: task.saveDir).appendingPathComponent(children[i].relativePath)
                try? FileManager.default.removeItem(at: f)
                var sidecarTask = task; sidecarTask.stagingPath = f.path; deleteSidecar(sidecarTask)
                children[i].completed = false
                children[i].filePath = ""
            }
            var reset = task
            reset.loaded = 0; reset.speed = 0; reset.status = TaskStatus.pending.rawValue
            reset.errorMsg = nil; reset.startedAt = nil; reset.completedAt = nil
            reset.folderChildrenJson = FolderChildFile.encodeList(children)
            reset.filesCompleted = 0; reset.filesTotal = children.count
            reset.currentFileName = children.first?.relativePath
            reset.totalSize = children.reduce(0) { $0 + max($1.size, 0) }
            await db.upsert(reset)
            await scheduleNow(id)
            return
        }
        try? FileManager.default.removeItem(atPath: task.stagingPath)
        if task.filePath != task.stagingPath {
            try? FileManager.default.removeItem(atPath: task.filePath)
        }
        var reset = task
        reset.loaded = 0; reset.speed = 0; reset.status = TaskStatus.pending.rawValue
        reset.errorMsg = nil; reset.startedAt = nil; reset.completedAt = nil
        await db.upsert(reset)
        await prepareChunks(reset)
        await scheduleNow(id)
    }

    func deleteTask(_ id: String, deleteFiles: Bool) async {
        await cancelTask(id)
        if let task = await db.getById(id) {
            deleteSidecar(task)
            if deleteFiles {
                if task.isFolder {
                    for child in FolderChildFile.decodeList(task.folderChildrenJson) {
                        let f = URL(fileURLWithPath: task.saveDir).appendingPathComponent(child.relativePath)
                        try? FileManager.default.removeItem(at: f)
                        var sidecarTask = task; sidecarTask.stagingPath = f.path; deleteSidecar(sidecarTask)
                    }
                    try? FileManager.default.removeItem(atPath: task.filePath)
                } else {
                    try? FileManager.default.removeItem(atPath: task.stagingPath)
                    try? FileManager.default.removeItem(atPath: task.filePath)
                }
            }
        }
        await db.deleteTaskFully(id)
    }

    func pauseAll() async {
        let all = await db.getAll()
        for t in all where t.status == TaskStatus.downloading.rawValue || t.status == TaskStatus.pending.rawValue || t.status == TaskStatus.merging.rawValue {
            await pauseTask(t.id)
        }
    }

    func resumeAll() async {
        let all = await db.getAll()
        for t in all where t.status == TaskStatus.paused.rawValue || t.status == TaskStatus.failed.rawValue {
            await resumeTask(t.id)
        }
    }

    func clearCompleted() async {
        let all = await db.getAll()
        for t in all where t.status == TaskStatus.completed.rawValue {
            await deleteTask(t.id, deleteFiles: false)
        }
    }

    private func updateStatus(_ id: String, status: TaskStatus, error: String? = nil) async {
        guard var task = await db.getById(id) else { return }
        task.status = status.rawValue
        task.errorMsg = error
        task.speed = status == .downloading ? task.speed : 0
        await db.upsert(task)
    }

    private func runTask(_ taskId: String) async {
        guard let task = await db.getById(taskId) else { return }
        if task.status == TaskStatus.completed.rawValue { return }
        if task.status == TaskStatus.paused.rawValue || task.status == TaskStatus.canceled.rawValue { return }
        if task.isFolder {
            await runFolderTask(taskId)
        } else {
            await runSingleFileTask(taskId)
        }
    }

    private func runFolderTask(_ taskId: String) async {
        guard var task = await db.getById(taskId) else { return }
        var children = FolderChildFile.decodeList(task.folderChildrenJson)
        guard !children.isEmpty else { await fail(taskId, "文件夹内没有可下载文件"); return }
        let folderName = task.fileName.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").first.map(String.init)?
            .nilIfEmpty ?? children.first?.relativePath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first.map(String.init)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "folder"
        let folderDir = URL(fileURLWithPath: task.saveDir).appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let rt = TaskRuntime()
        runtimes[taskId] = rt
        var t = task
        t.status = TaskStatus.downloading.rawValue
        t.fileName = folderName
        t.filePath = folderDir.path
        t.stagingPath = folderDir.path
        t.isFolder = true
        t.startedAt = t.startedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        t.errorMsg = nil
        t.speed = 0
        t.filesTotal = children.count
        t.filesCompleted = children.filter { $0.completed }.count
        await db.upsert(t)
        task = (await db.getById(taskId))!

        do {
            for i in children.indices {
                if rt.cancelRequested { return }
                if rt.pauseRequested { await updateStatus(taskId, status: .paused); return }
                if children[i].completed { continue }
                var child = children[i]
                task = (await db.getById(taskId))!
                let root = URL(fileURLWithPath: task.saveDir)
                let rel = child.relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let outFile = root.appendingPathComponent(rel)
                try? FileManager.default.createDirectory(at: outFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let headers = FormatUtil.parseHeaders(child.headersJson)
                let kind: UrlResolve.Kind = UrlResolve.isBaiduUrl(child.url) ? .baidu : .http
                let settings = settingsRepo.current()
                let ua = (child.userAgent?.isEmpty == false) ? child.userAgent : UrlResolve.pickUserAgent(kind, settings)
                var childSize = child.size
                if childSize <= 0 {
                    childSize = kind == .baidu ? UrlResolve.parseBaiduSize(child.url) :
                        (await downloader.probe(url: child.url, headers: headers, userAgent: ua, skipHead: false)).totalSize
                    if childSize > 0 { child.size = childSize; children[i] = child }
                }
                guard childSize > 0 else { await fail(taskId, "无法获取文件大小：\(child.relativePath)"); return }

                let completedBytes = children.filter { $0.completed }.reduce(0) { $0 + max($1.size, 0) }
                let folderTotal = max(task.totalSize, children.reduce(0) { $0 + max($1.size, 0) })
                rt.aggregateBaseLoaded = completedBytes
                rt.loaded = 0
                rt.inFlightBytes = 0

                var t2 = task
                t2.url = child.url
                t2.headersJson = child.headersJson.isEmpty ? task.headersJson : child.headersJson
                t2.userAgent = ua
                t2.fileName = folderName
                t2.filePath = folderDir.path
                t2.stagingPath = folderDir.path
                t2.isFolder = true
                t2.currentFileName = child.relativePath
                t2.filesCompleted = children.filter { $0.completed }.count
                t2.filesTotal = children.count
                t2.totalSize = folderTotal
                t2.loaded = completedBytes
                t2.folderChildrenJson = FolderChildFile.encodeList(children)
                t2.status = TaskStatus.downloading.rawValue
                t2.speed = 0
                await db.upsert(t2)

                var fileTask = task
                fileTask.url = child.url
                fileTask.fileName = child.relativePath
                fileTask.filePath = outFile.path
                fileTask.stagingPath = outFile.path
                fileTask.totalSize = childSize
                fileTask.loaded = 0
                fileTask.headersJson = child.headersJson.isEmpty ? "{}" : child.headersJson
                fileTask.userAgent = ua
                fileTask.isFolder = false
                fileTask.currentFileName = child.relativePath

                await db.deleteChunks(taskId)
                deleteSidecar(fileTask)
                await prepareChunks(fileTask)

                let result = await downloadPreparedFile(taskId, fileTask: fileTask, rt: rt)
                switch result {
                case .paused:
                    await persistFolderProgress(taskId, rt: rt, children: children)
                    await updateStatus(taskId, status: .paused)
                    return
                case .canceled: return
                case .failed: return
                case .completed:
                    child.completed = true
                    child.size = childSize
                    child.filePath = outFile.path
                    children[i] = child
                    FilePublish.scanFile(outFile)
                    let doneCount = children.filter { $0.completed }.count
                    let loadedAll = children.filter { $0.completed }.reduce(0) { $0 + max($1.size, 0) }
                    if var latest = await db.getById(taskId) {
                        latest.folderChildrenJson = FolderChildFile.encodeList(children)
                        latest.filesCompleted = doneCount
                        latest.filesTotal = children.count
                        latest.loaded = loadedAll
                        latest.totalSize = children.reduce(0) { $0 + max($1.size, 0) }
                        latest.fileName = folderName
                        latest.filePath = folderDir.path
                        latest.stagingPath = folderDir.path
                        latest.isFolder = true
                        latest.currentFileName = child.relativePath
                        latest.speed = 0
                        await db.upsert(latest)
                    }
                    await db.deleteChunks(taskId)
                    deleteSidecar(fileTask)
                }
            }
            if var latest = await db.getById(taskId) {
                latest.status = TaskStatus.completed.rawValue
                latest.fileName = folderName
                latest.filePath = folderDir.path
                latest.stagingPath = folderDir.path
                latest.isFolder = true
                latest.loaded = latest.totalSize
                latest.speed = 0
                latest.completedAt = Int64(Date().timeIntervalSince1970 * 1000)
                latest.errorMsg = nil
                latest.currentFileName = nil
                latest.filesCompleted = children.count
                await db.upsert(latest)
            }
        } catch {
            if rt.pauseRequested {
                await updateStatus(taskId, status: .paused)
            } else {
                await fail(taskId, error.localizedDescription)
            }
        }
    }

    private func persistFolderProgress(_ taskId: String, rt: TaskRuntime, children: [FolderChildFile]) async {
        guard var task = await db.getById(taskId) else { return }
        let completedBytes = children.filter { $0.completed }.reduce(0) { $0 + max($1.size, 0) }
        let current = rt.loaded + max(rt.inFlightBytes, 0)
        let loadedNow = completedBytes + current
        let cap = task.totalSize > 0 ? task.totalSize : Int64.max
        task.loaded = min(max(loadedNow, 0), cap)
        task.speed = rt.speed.speedBps
        task.folderChildrenJson = FolderChildFile.encodeList(children)
        await db.upsert(task)
    }

    private func runSingleFileTask(_ taskId: String) async {
        let settings = settingsRepo.current()
        guard var task = await db.getById(taskId) else { return }
        let headers = FormatUtil.parseHeaders(task.headersJson)
        let kind: UrlResolve.Kind = UrlResolve.isBaiduUrl(task.url) ? .baidu : .http
        let ua = (task.userAgent?.isEmpty == false) ? task.userAgent : UrlResolve.pickUserAgent(kind, settings)
        let rt = TaskRuntime()
        runtimes[taskId] = rt
        task.status = TaskStatus.downloading.rawValue
        task.startedAt = task.startedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        task.errorMsg = nil
        task.userAgent = ua
        task.speed = 0
        await db.upsert(task)
        task = (await db.getById(taskId))!

        if task.totalSize <= 0 {
            if kind == .baidu {
                let fromUrl = UrlResolve.parseBaiduSize(task.url)
                if fromUrl > 0 { task.totalSize = fromUrl; await db.upsert(task) }
            } else {
                let probe = await downloader.probe(url: task.url, headers: headers, userAgent: ua, skipHead: false)
                if probe.totalSize > 0 { task.totalSize = probe.totalSize; await db.upsert(task) }
            }
            if task.totalSize > 0 {
                await db.deleteChunks(taskId)
                await prepareChunks(task)
            }
        }
        let chunkSize = UrlResolve.chunkBytes(task.chunkSize, kind)
        if chunkSize != task.chunkSize {
            task.chunkSize = chunkSize
            await db.upsert(task)
            await db.deleteChunks(taskId)
            await prepareChunks(task)
        }
        restoreFromSidecar(task)
        var chunks = await db.getChunks(taskId)
        if chunks.isEmpty && task.totalSize > 0 {
            await prepareChunks(task)
            chunks = await db.getChunks(taskId)
        }
        if chunks.isEmpty {
            await fail(taskId, "无法确定文件大小或不支持分片下载")
            return
        }
        ensurePreallocated(URL(fileURLWithPath: task.stagingPath), task.totalSize)
        let result = await downloadPreparedFile(taskId, fileTask: task, rt: rt)
        switch result {
        case .completed: await finishTask(taskId)
        case .paused: await updateStatus(taskId, status: .paused)
        case .canceled, .failed: break
        }
    }

    private enum ChildDownloadResult { case completed, paused, canceled, failed }

    private func downloadPreparedFile(_ taskId: String, fileTask: TaskEntity, rt: TaskRuntime) async -> ChildDownloadResult {
        var task = fileTask
        let headers = FormatUtil.parseHeaders(task.headersJson)
        let kind: UrlResolve.Kind = UrlResolve.isBaiduUrl(task.url) ? .baidu : .http
        let ua = (task.userAgent?.isEmpty == false) ? task.userAgent : UrlResolve.pickUserAgent(kind, settingsRepo.current())
        restoreFromSidecar(task)
        var chunks = await db.getChunks(taskId)
        if chunks.isEmpty && task.totalSize > 0 {
            await prepareChunks(task)
            chunks = await db.getChunks(taskId)
        }
        if chunks.isEmpty {
            await fail(taskId, "无法确定文件大小或不支持分片下载")
            return .failed
        }
        ensurePreallocated(URL(fileURLWithPath: task.stagingPath), task.totalSize)

        let completed = ConcurrentSet<Int>()
        for c in chunks where c.completed { completed.insert(c.index) }
        rt.loaded = chunks.filter { $0.completed }.reduce(0) { $0 + ($1.end - $1.start + 1) }
        await persistProgress(taskId, rt: rt, force: true)

        let pendingChunks = chunks.filter { !$0.completed }.sorted { $0.index < $1.index }
        if pendingChunks.isEmpty { return .completed }

        let workers = fairWorkerCount(task.threads, kind)
        let queue = ConcurrentQueue(pendingChunks)
        let stagingFile = URL(fileURLWithPath: task.stagingPath)
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.progressIntervalMs ?? 500_000_000)
                if Task.isCancelled { break }
                rt.speed.sample()
                await self?.persistProgress(taskId, rt: rt, force: false)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    do {
                        let handle = try FileHandle(forWritingTo: stagingFile)
                        defer { try? handle.close() }
                        while true {
                            if rt.pauseRequested || rt.cancelRequested { return }
                            guard let chunk = queue.dequeue() else { return }
                            do {
                                try await self.downloadChunkDirect(task: task, chunk: chunk, headers: headers, ua: ua, handle: handle, rt: rt, completed: completed)
                            } catch is CancellationError {
                                return
                            } catch {
                                if rt.pauseRequested || rt.cancelRequested { return }
                                throw error
                            }
                        }
                    } catch {
                        rt.fatalError = error
                    }
                }
            }
            await group.waitForAll()
        }
        progressTask.cancel()

        if rt.cancelRequested { return .canceled }
        if rt.pauseRequested {
            await persistProgress(taskId, rt: rt, force: true, speedOverride: 0)
            return .paused
        }
        if let err = rt.fatalError {
            await fail(taskId, err.localizedDescription)
            return .failed
        }
        let left = await db.getChunks(taskId).contains { !$0.completed }
        if left {
            await persistProgress(taskId, rt: rt, force: true, speedOverride: 0)
            return .paused
        }
        let out = URL(fileURLWithPath: task.stagingPath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        if !FileManager.default.fileExists(atPath: out.path) || (task.totalSize > 0 && fileSize != task.totalSize) {
            await fail(taskId, "文件大小校验失败：\(task.fileName)")
            return .failed
        }
        return .completed
    }

    private func downloadChunkDirect(
        task: TaskEntity, chunk: ChunkEntity, headers: [String: String], ua: String?,
        handle: FileHandle, rt: TaskRuntime, completed: ConcurrentSet<Int>
    ) async throws {
        let expected = chunk.end - chunk.start + 1
        guard expected > 0 else { return }
        guard !chunk.completed, !completed.contains(chunk.index) else { return }
        var attempt = 0
        while attempt < maxChunkRetries {
            if rt.pauseRequested || rt.cancelRequested { return }
            attempt += 1
            do {
                let written = try await downloader.downloadRange(
                    url: task.url, range: chunk.start...chunk.end, handle: handle,
                    writeOffset: chunk.start, headers: headers, userAgent: ua,
                    isCancelled: { rt.pauseRequested || rt.cancelRequested },
                    onBytes: { n in
                        rt.speed.add(n)
                        rt.inFlightBytes += n
                    })
                if rt.pauseRequested || rt.cancelRequested {
                    rt.inFlightBytes -= written
                    return
                }
                if written != expected {
                    throw NSError(domain: "ArkDownloader", code: 0, userInfo: [NSLocalizedDescriptionKey: "分片长度不符 \(written) != \(expected)"])
                }
                rt.inFlightBytes -= written
                rt.loaded += expected
                var updated = chunk
                updated.loaded = expected
                updated.completed = true
                await db.upsertChunks([updated])
                completed.insert(chunk.index)
                return
            } catch is CancellationError {
                return
            } catch {
                if rt.pauseRequested || rt.cancelRequested { return }
                if attempt >= maxChunkRetries { throw error }
                try? await Task.sleep(nanoseconds: UInt64(400 * attempt) * 1_000_000)
            }
        }
    }

    private func persistProgress(_ taskId: String, rt: TaskRuntime, force: Bool, speedOverride: Int64? = nil) async {
        guard var task = await db.getById(taskId) else { return }
        if !force && (task.status != TaskStatus.downloading.rawValue && task.status != TaskStatus.pending.rawValue) { return }
        task.speed = speedOverride ?? rt.speed.speedBps
        let fileLoaded = rt.loaded + max(rt.inFlightBytes, 0)
        let loadedNow: Int64
        if task.isFolder {
            let cap = task.totalSize > 0 ? task.totalSize : Int64.max
            loadedNow = min(max(rt.aggregateBaseLoaded + fileLoaded, 0), cap)
        } else {
            loadedNow = min(max(fileLoaded, 0), max(task.totalSize, 0))
        }
        task.loaded = loadedNow
        await db.upsert(task)
    }

    private func finishTask(_ taskId: String) async {
        guard var task = await db.getById(taskId) else { return }
        guard !task.isFolder else { return }
        task.status = TaskStatus.merging.rawValue
        task.speed = 0
        await db.upsert(task)

        let path = task.filePath.isEmpty ? task.stagingPath : task.filePath
        var out = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        if !FileManager.default.fileExists(atPath: out.path) || (task.totalSize > 0 && fileSize != task.totalSize) {
            await fail(taskId, "文件大小校验失败")
            return
        }
        let incomplete = await db.getChunks(taskId).contains { !$0.completed }
        if incomplete { await fail(taskId, "仍有未完成分片"); return }

        let bestName = UrlResolve.canonicalFileName(url: task.url, nameHint: (task.fileName as NSString).lastPathComponent)
        var finalName = task.fileName
        var finalPath = out.path
        if !bestName.isEmpty && bestName != "download.bin" &&
            (bestName as NSString).lastPathComponent != (task.fileName as NSString).lastPathComponent {
            if let renamed = renameCompletedFile(out, (bestName as NSString).lastPathComponent) {
                out = renamed
                let parentRel = (task.fileName.replacingOccurrences(of: "\\", with: "/") as NSString).deletingLastPathComponent
                finalName = parentRel.isEmpty ? renamed.lastPathComponent : "\(parentRel)/\(renamed.lastPathComponent)"
                finalPath = renamed.path
            }
        }
        FilePublish.scanFile(out)
        task.status = TaskStatus.completed.rawValue
        task.fileName = finalName
        task.filePath = finalPath
        task.stagingPath = finalPath
        task.loaded = task.totalSize
        task.completedAt = Int64(Date().timeIntervalSince1970 * 1000)
        task.errorMsg = nil
        task.speed = 0
        await db.upsert(task)
        deleteSidecar(task)
    }

    private func renameCompletedFile(_ current: URL, _ desiredName: String) -> URL? {
        let parent = current.deletingLastPathComponent()
        let unique = uniqueFileName(parent, desiredName)
        let target = parent.appendingPathComponent(unique)
        if target.path == current.path { return current }
        do {
            try FileManager.default.moveItem(at: current, to: target)
            return target
        } catch {
            return nil
        }
    }

    private func fail(_ taskId: String, _ message: String) async {
        guard var task = await db.getById(taskId) else { return }
        task.status = TaskStatus.failed.rawValue
        task.errorMsg = message
        task.speed = 0
        await db.upsert(task)
    }

    func resumePendingOnBoot() async {
        let all = await db.getAll()
        for t in all where t.status == TaskStatus.downloading.rawValue || t.status == TaskStatus.merging.rawValue {
            var m = t
            m.status = TaskStatus.paused.rawValue
            m.speed = 0
            await db.upsert(m)
        }
        if settingsRepo.current().autoStart {
            pumpQueue()
        }
    }

    private func ensurePreallocated(_ file: URL, _ size: Int64) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
        } catch {}
    }

    private func sidecarFile(_ task: TaskEntity) -> URL {
        URL(fileURLWithPath: task.stagingPath + ".arkmeta.json")
    }

    private func writeSidecar(_ task: TaskEntity, completed: Set<Int>) {
        let obj: [String: Any] = [
            "id": task.id,
            "completed": Array(completed).sorted()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: sidecarFile(task))
        }
    }

    private func restoreFromSidecar(_ task: TaskEntity) {
        let url = sidecarFile(task)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let completed = obj["completed"] as? [Int] else { return }
        let set = Set(completed)
        Task {
            let chunks = await db.getChunks(task.id)
            let updated = chunks.map { c -> ChunkEntity in
                var m = c
                if set.contains(c.index) {
                    m.completed = true
                    m.loaded = c.end - c.start + 1
                }
                return m
            }
            await db.upsertChunks(updated)
        }
    }

    private func deleteSidecar(_ task: TaskEntity) {
        try? FileManager.default.removeItem(at: sidecarFile(task))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Thread-safe FIFO queue for chunk distribution.
private final class ConcurrentQueue<T> {
    private let lock = NSLock()
    private var items: [T]
    init(_ items: [T]) { self.items = items }
    func dequeue() -> T? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

private final class ConcurrentSet<T: Hashable> {
    private let lock = NSLock()
    private var set = Set<T>()
    func insert(_ item: T) {
        lock.lock(); defer { lock.unlock() }
        set.insert(item)
    }
    func contains(_ item: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return set.contains(item)
    }
}

/// Per-task runtime state: cancellation flags, speed meter, in-flight bytes.
private final class TaskRuntime: @unchecked Sendable {
    let lock = NSLock()
    var pauseRequested = false
    var cancelRequested = false
    var loaded: Int64 = 0
    var inFlightBytes: Int64 = 0
    var aggregateBaseLoaded: Int64 = 0
    let speed = SpeedMeter()
    var fatalError: Error? = nil
    private var calls: [Int: URLSessionDataTask] = [:]
    private var callId = 0

    func registerCall(_ call: URLSessionDataTask) -> Int {
        lock.lock(); defer { lock.unlock() }
        callId += 1
        calls[callId] = call
        return callId
    }

    func unregisterCall(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        calls.removeValue(forKey: id)
    }

    func cancelAllCalls() {
        lock.lock()
        let all = calls.values
        calls.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}





