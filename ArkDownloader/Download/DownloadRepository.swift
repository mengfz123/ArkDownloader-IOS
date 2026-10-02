import Foundation
import Combine
import UIKit

/// Bridges the download engine, settings, and RPC server.
/// Acts as the RPC bridge implementation.
final class DownloadRepository: DownloadRepositoryBridge {
    let engine: DownloadEngine
    let settingsRepo: SettingsRepository
    let rpcServer: RpcServer

    private let rpcQueue = DispatchQueue(label: "ark.rpc.bridge")
    private var lastRpcFingerprint: String?

    init(engine: DownloadEngine, settingsRepo: SettingsRepository, rpcServer: RpcServer) {
        self.engine = engine
        self.settingsRepo = settingsRepo
        self.rpcServer = rpcServer
    }

    func initialize() {
        Task {
            await engine.resumePendingOnBoot()
            syncRpc(settingsRepo.current())
        }
        // Observe settings changes to restart RPC when needed.
        settingsRepo.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                self?.syncRpc(settings)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func syncRpc(_ settings: AppSettings) {
        let fingerprint = "\(settings.rpcEnabled)|\(settings.rpcPort)|\(settings.rpcRemote)|\(settings.rpcToken)"
        if fingerprint == lastRpcFingerprint { return }
        lastRpcFingerprint = fingerprint
        if settings.rpcEnabled {
            rpcServer.start(port: settings.rpcPort, rpcToken: settings.rpcToken, remote: settings.rpcRemote, bridge: self)
        } else {
            rpcServer.stop()
        }
    }

    // MARK: - Task creation helpers

    func createTasksFromUrls(_ urls: [String], fileName: String?, threads: Int, chunkSize: Int, headersJson: String) async {
        let cleaned = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let headers = FormatUtil.parseHeaders(headersJson)
        for url in cleaned {
            let name = cleaned.count == 1 ? fileName : nil
            do {
                _ = try await engine.createTask(url: url, fileName: name, saveDir: nil, threads: threads,
                    chunkSize: chunkSize, totalSize: nil, userAgent: nil, headers: headers)
            } catch {
                print("ArkRepo: create failed: \(url.prefix(80)) — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - DownloadRepositoryBridge

    func getInfo() -> [String: Any?] {
        let s = settingsRepo.current()
        return [
            "name": AppSettings.appName,
            "version": AppSettings.version,
            "machineId": machineId(),
            "downloadDir": s.downloadDir.isEmpty ? FilePublish.defaultDownloadDir().path : s.downloadDir,
            "rpc": rpcServer.status()
        ]
    }

    func resolveUrl(_ body: [String: Any]) throws -> [String: Any?] {
        let url = (body["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !url.isEmpty else { throw NSError(domain: "Ark", code: 400, userInfo: [NSLocalizedDescriptionKey: "url required"]) }
        let nameHint = (body["name"] as? String)?.nilIfEmpty
        let sizeHint = (body["size"] as? Int64) ?? (body["total_size"] as? Int64) ?? 0
        let resolved = UrlResolve.resolve(url, nameHint: nil, sizeHint: sizeHint)
        var size = resolved.size
        var name = UrlResolve.canonicalFileName(resolved.url, nameHint: nameHint)
        if size <= 0 && resolved.kind == .http {
            let settings = settingsRepo.current()
            let ua = UrlResolve.pickUserAgent(resolved.kind, settings)
            let sem = DispatchSemaphore(value: 0)
            var probe: ChunkDownloader.ProbeResult?
            Task {
                probe = await ChunkDownloader().probe(url: resolved.url, headers: [:], userAgent: ua, skipHead: false, forceHeaders: true)
                sem.signal()
            }
            sem.wait()
            if let p = probe {
                size = p.totalSize
                name = UrlResolve.canonicalFileName(resolved.url, contentDisposition: p.contentDisposition, nameHint: nameHint)
            }
        }
        return [
            "url": resolved.url,
            "size": size,
            "name": name,
            "kind": resolved.kind == .baidu ? "baidu" : "http"
        ]
    }

    func listTasks(_ status: String?) throws -> [[String: Any?]] {
        let all = awaitAllTasks()
        let filtered: [TaskEntity]
        if let status = status, !status.isEmpty {
            guard let wanted = TaskStatus.fromApi(status) else {
                throw NSError(domain: "Ark", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unknown status filter: \(status)"])
            }
            filtered = all.filter { entity in
                guard let st = TaskStatus(rawValue: entity.status) ?? TaskStatus.fromApi(entity.status) else { return false }
                switch wanted {
                case .downloading: return st == .downloading || st == .merging || st == .pending
                case .failed: return st == .failed || st == .canceled
                default: return st == wanted
                }
            }
        } else {
            filtered = all
        }
        return filtered.map { taskToV1($0) }
    }

    private func awaitAllTasks() -> [TaskEntity] {
        let sem = DispatchSemaphore(value: 0)
        var result: [TaskEntity] = []
        Task {
            result = await engine.observeTasks()
            sem.signal()
        }
        sem.wait()
        return result
    }

    func getTaskEntity(_ id: String) -> TaskEntity? {
        let sem = DispatchSemaphore(value: 0)
        var result: TaskEntity?
        Task {
            result = await engine.getTask(id)
            sem.signal()
        }
        sem.wait()
        return result
    }

    func taskToDict(_ task: TaskEntity) -> [String: Any?] {
        let name = UrlResolve.displayFileName(task.fileName, task.url)
        return [
            "id": task.id, "url": task.url, "file_name": name, "save_dir": task.saveDir,
            "file_path": task.filePath, "total": task.totalSize, "loaded": task.loaded,
            "progress": task.totalSize > 0 ? Double(task.loaded) / Double(task.totalSize) * 100 : 0,
            "speed": task.speed, "status": (TaskStatus(rawValue: task.status) ?? .failed).apiValue,
            "error_msg": task.errorMsg, "threads": task.threads, "chunk_size": task.chunkSize,
            "created_at": task.createdAt, "started_at": task.startedAt ?? NSNull(), "completed_at": task.completedAt ?? NSNull()
        ]
    }

    func taskToV1(_ task: TaskEntity) -> [String: Any?] {
        let kind = UrlResolve.isBaiduUrl(task.url) ? "baidu" : "http"
        let chunks = awaitChunks(task.id)
        let name = UrlResolve.displayFileName(task.fileName, task.url)
        let status = TaskStatus(rawValue: task.status) ?? .failed
        return [
            "id": task.id, "name": name, "path": task.saveDir, "url": task.url,
            "size": task.totalSize, "kind": kind, "status": status.v1Value,
            "connections": task.threads, "chunkSize": task.chunkSize, "downloaded": task.loaded,
            "speed": status == .downloading ? task.speed : 0,
            "speedBps": status == .downloading ? task.speed : 0,
            "progress": task.totalSize > 0 ? (Double(task.loaded) / Double(task.totalSize) * 10000).rounded() / 100 : 0,
            "chunks": ["total": chunks.count, "done": chunks.filter { $0.completed }.count],
            "error": task.errorMsg ?? NSNull(),
            "createdAt": task.createdAt,
            "updatedAt": task.completedAt ?? task.startedAt ?? task.createdAt,
            "out": task.filePath
        ]
    }

    private func awaitChunks(_ taskId: String) -> [ChunkEntity] {
        let sem = DispatchSemaphore(value: 0)
        var result: [ChunkEntity] = []
        Task {
            result = await AppDatabase.shared.getChunks(taskId)
            sem.signal()
        }
        sem.wait()
        return result
    }

    func getSettings() -> [String: Any?] {
        let s = settingsRepo.current()
        let dir = s.downloadDir.isEmpty ? FilePublish.defaultDownloadDir().path : s.downloadDir
        return [
            "downloadDir": dir, "connections": s.connections, "maxRunning": s.maxRunning,
            "chunkSizeMb": s.chunkSizeMb, "autoStart": s.autoStart, "notifyOnComplete": s.notifyOnComplete,
            "userAgent": s.userAgent, "httpUserAgent": s.httpUserAgent,
            "rpcEnabled": s.rpcEnabled, "rpcPort": s.rpcPort, "rpcRemote": s.rpcRemote,
            "rpcToken": s.rpcToken, "rpcStatus": rpcServer.status(),
            "max_concurrent": s.maxConcurrentTasks, "max_threads": s.maxThreads,
            "chunk_size": s.chunkSize, "default_save_path": dir,
            "default_user_agent": s.userAgent,
            "default_headers": FormatUtil.parseHeaders(s.defaultHeadersJson),
            "rpc_enabled": s.rpcEnabled, "rpc_port": s.rpcPort
        ]
    }

    func updateSettings(_ body: [String: Any]) throws -> [String: Any?] {
        settingsRepo.update { current in
            var next = current
            if body["downloadDir"] != nil || body["default_save_path"] != nil {
                let dir = (body["downloadDir"] as? String) ?? (body["default_save_path"] as? String) ?? ""
                next.defaultSaveDir = dir
            }
            if body["connections"] != nil || body["max_threads"] != nil {
                let n = (body["connections"] as? Int) ?? (body["max_threads"] as? Int) ?? next.maxThreads
                next.maxThreads = n
            }
            if body["maxRunning"] != nil || body["max_concurrent"] != nil {
                let n = (body["maxRunning"] as? Int) ?? (body["max_concurrent"] as? Int) ?? next.maxConcurrentTasks
                next.maxConcurrentTasks = n
            }
            if let v = body["chunkSizeMb"] as? Int {
                next.chunkSize = AppSettings.chunkBytesFromMb(v)
            } else if let v = body["chunk_size"] as? Int {
                next.chunkSize = v
            }
            if let v = body["autoStart"] as? Bool { next.autoStart = v }
            if let v = body["notifyOnComplete"] as? Bool { next.notifyOnComplete = v }
            if body["userAgent"] != nil || body["default_user_agent"] != nil {
                let ua = (body["userAgent"] as? String) ?? (body["default_user_agent"] as? String) ?? next.userAgent
                next.userAgent = ua
            }
            if let v = body["httpUserAgent"] as? String { next.httpUserAgent = v }
            if let h = body["default_headers"] as? [String: String] {
                next.defaultHeadersJson = FormatUtil.headersToJson(h)
            }
            if body["rpcEnabled"] != nil || body["rpc_enabled"] != nil {
                let v = (body["rpcEnabled"] as? Bool) ?? (body["rpc_enabled"] as? Bool) ?? next.rpcEnabled
                next.rpcEnabled = v
            }
            if body["rpcPort"] != nil || body["rpc_port"] != nil {
                let p = (body["rpcPort"] as? Int) ?? (body["rpc_port"] as? Int) ?? next.rpcPort
                next.rpcPort = p
            }
            if let v = body["rpcRemote"] as? Bool { next.rpcRemote = v }
            if body["rpcToken"] != nil || body["rpc_token"] != nil {
                let t = (body["rpcToken"] as? String) ?? (body["rpc_token"] as? String) ?? next.rpcToken
                next.rpcToken = t
            }
            return next
        }
        return getSettings()
    }

    func createTask(_ body: [String: Any]) throws -> String {
        let task = try createTaskFromBody(body)
        return task.id
    }

    func createTasksBatch(_ body: [String: Any]) throws -> [String: Any?] {
        let items: [[String: Any]]
        if let reqs = body["reqs"] as? [[String: Any]] { items = reqs }
        else if let tasks = body["tasks"] as? [[String: Any]] { items = tasks }
        else if let urls = body["urls"] as? [String] { items = urls.map { ["url": $0] } }
        else { items = [] }
        var ids: [String] = []
        var errors: [[String: String]] = []
        for item in items {
            do {
                ids.append(try createTaskFromBody(item).id)
            } catch {
                errors.append(["url": ((item["url"] as? String) ?? "").prefix(80).description, "error": error.localizedDescription])
            }
        }
        if ids.isEmpty && !errors.isEmpty {
            throw NSError(domain: "Ark", code: 400, userInfo: [NSLocalizedDescriptionKey: errors.first?["error"] ?? "batch failed"])
        }
        return ["ids": ids, "errors": errors]
    }

    func createFolderTasks(_ body: [String: Any]) throws -> [String: Any?] {
        let rawFiles: [[String: Any]]
        if let f = body["files"] as? [[String: Any]] { rawFiles = f }
        else if let t = body["tasks"] as? [[String: Any]] { rawFiles = t }
        else if let r = body["reqs"] as? [[String: Any]] { rawFiles = r }
        else { rawFiles = [] }
        guard !rawFiles.isEmpty else {
            throw NSError(domain: "Ark", code: 400, userInfo: [NSLocalizedDescriptionKey: "files required"])
        }
        var folderName = ([body["name"], body["folderName"], body["folder"]] as? [String])?.compactMap { $0 }.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let parentDir = ([body["dir"], body["save_path"], body["save_dir"]] as? [String])?.compactMap { $0 }.first?.trimmingCharacters(in: .whitespaces)
        var children: [FolderChildFile] = []
        var threads: Int? = (body["connections"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? (body["threads"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        var absoluteSaveDir: String? = parentDir.flatMap { looksAbsoluteFsPath($0) ? $0 : nil }

        for item in rawFiles {
            guard let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { continue }
            let parsed = parseEmbedItem(item)
            if absoluteSaveDir == nil { absoluteSaveDir = parsed.absoluteSaveDir }
            if threads == nil { threads = parsed.threads }
            if folderName.isEmpty {
                folderName = parsed.groupKey ?? parsed.relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first.map(String.init)?.nilIfEmpty ?? "文件夹"
            }
            children.append(FolderChildFile(url: parsed.url, name: parsed.name, relativePath: parsed.relativePath.isEmpty ? parsed.name : parsed.relativePath,
                size: parsed.size, headersJson: FormatUtil.headersToJson(parsed.headers), userAgent: parsed.userAgent))
        }
        guard !children.isEmpty else {
            throw NSError(domain: "Ark", code: 400, userInfo: [NSLocalizedDescriptionKey: "无有效文件"])
        }
        folderName = folderName.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first.map(String.init)?.nilIfEmpty ?? "文件夹"

        let sem = DispatchSemaphore(value: 0)
        var task: TaskEntity?
        var createError: Error?
        Task {
            do {
                task = try await engine.createFolderTask(folderName: folderName, children: children, saveDir: absoluteSaveDir, threads: threads, chunkSize: nil)
            } catch {
                createError = error
            }
            sem.signal()
        }
        sem.wait()
        if let e = createError { throw e }
        guard let t = task else { throw NSError(domain: "Ark", code: 500, userInfo: [NSLocalizedDescriptionKey: "create failed"]) }
        return ["id": t.id, "ids": [t.id], "errors": []]
    }

    private func createTaskFromBody(_ body: [String: Any]) throws -> TaskEntity {
        let url = (body["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !url.isEmpty else {
            throw NSError(domain: "Ark", code: 400, userInfo: [NSLocalizedDescriptionKey: "url required"])
        }
        let headers = normalizeHeaders(body["headers"])
        let fileName = [body["name"], body["file_name"], body["filename"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let threads = (body["connections"] as? Int) ?? (body["threads"] as? Int)
        let chunkSize: Int?
        if let mb = body["chunkSizeMb"] as? Int { chunkSize = AppSettings.chunkBytesFromMb(mb) }
        else if let cs = body["chunk_size"] as? Int { chunkSize = cs }
        else { chunkSize = nil }
        let totalSize = (body["size"] as? Int64).flatMap { $0 > 0 ? $0 : nil } ?? (body["total_size"] as? Int64).flatMap { $0 > 0 ? $0 : nil }
        let ua = (body["user_agent"] as? String)?.nilIfEmpty ?? (body["userAgent"] as? String)?.nilIfEmpty

        let sem = DispatchSemaphore(value: 0)
        var task: TaskEntity?
        var createError: Error?
        Task {
            do {
                task = try await engine.createTask(url: url, fileName: fileName, saveDir: nil, threads: threads,
                    chunkSize: chunkSize, totalSize: totalSize, userAgent: ua, headers: headers)
            } catch {
                createError = error
            }
            sem.signal()
        }
        sem.wait()
        if let e = createError { throw e }
        guard let t = task else { throw NSError(domain: "Ark", code: 500, userInfo: [NSLocalizedDescriptionKey: "create failed"]) }
        return t
    }

    private struct ParsedEmbedItem {
        let url: String
        let groupKey: String?
        let relativePath: String
        let name: String
        let size: Int64
        let headers: [String: String]
        let threads: Int?
        let chunkSize: Int?
        let userAgent: String?
        let absoluteSaveDir: String?
    }

    private func parseEmbedItem(_ body: [String: Any]) -> ParsedEmbedItem {
        let url = (body["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let headers = normalizeHeaders(body["headers"])
        let fileName = [body["name"], body["file_name"], body["filename"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "download.bin"
        let fullRelative = [body["relativePath"], body["relative_path"], body["path"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !looksAbsoluteFsPath($0) }
        let dirField = [body["dir"], body["folderPath"], body["folder_path"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let absoluteSaveDir = [body["save_path"], body["save_dir"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            ?? dirField.flatMap { looksAbsoluteFsPath($0) ? $0 : nil }
        let relativeDir = dirField.flatMap { !looksAbsoluteFsPath($0) ? $0 : nil }
        let nested = buildNestedDownloadName(fullRelative, relativeDir, fileName)?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? fileName
        let groupKey = folderGroupKey(nested, relativeDir)
        let size = (body["size"] as? Int64).flatMap { $0 > 0 ? $0 : nil } ?? (body["total_size"] as? Int64).flatMap { $0 > 0 ? $0 : nil } ?? 0
        let threads = (body["connections"] as? Int) ?? (body["threads"] as? Int)
        let chunkSize: Int?
        if let mb = body["chunkSizeMb"] as? Int { chunkSize = AppSettings.chunkBytesFromMb(mb) }
        else if let cs = body["chunk_size"] as? Int { chunkSize = cs }
        else { chunkSize = nil }
        let ua = (body["user_agent"] as? String)?.nilIfEmpty ?? (body["userAgent"] as? String)?.nilIfEmpty
        return ParsedEmbedItem(url: url, groupKey: groupKey, relativePath: nested,
            name: fileName.split(separator: "/").last.map(String.init)?.split(separator: "\\").last.map(String.init)?.nilIfEmpty ?? "download.bin",
            size: size, headers: headers, threads: threads, chunkSize: chunkSize, userAgent: ua, absoluteSaveDir: absoluteSaveDir)
    }

    private func folderGroupKey(_ relativePath: String?, _ relativeDir: String?) -> String? {
        if let p = relativePath?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           !p.isEmpty, p.contains("/") {
            return String(p.split(separator: "/")[0])
        }
        if let d = relativeDir?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           !d.isEmpty {
            return String(d.split(separator: "/")[0])
        }
        return nil
    }

    private func buildNestedDownloadName(_ fullRelative: String?, _ relativeDir: String?, _ fileName: String?) -> String? {
        if let path = fullRelative?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")), !path.isEmpty {
            return path
        }
        let dir = relativeDir?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfEmpty
        let leaf = fileName?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let d = dir, let l = leaf {
            let base = String(l.split(separator: "/").last ?? l[...])
            return d.hasSuffix("/\(base)") || d == base ? d : "\(d)/\(base)"
        }
        return dir ?? leaf
    }

    private func looksAbsoluteFsPath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") || p.hasPrefix("\\") { return true }
        if p.count >= 3 && p[p.index(p.startIndex, offsetBy: 1)] == ":" { return true }
        return false
    }

    private func normalizeHeaders(_ raw: Any?) -> [String: String] {
        guard let raw = raw, !(raw is NSNull) else { return [:] }
        if let dict = raw as? [String: String] { return dict }
        if let dict = raw as? [String: Any] { return dict.compactMapValues { $0 as? String } }
        return [:]
    }

    func pauseTask(_ id: String) { Task { await engine.pauseTask(id) } }
    func resumeTask(_ id: String) { Task { await engine.resumeTask(id) } }
    func cancelTask(_ id: String) { Task { await engine.cancelTask(id) } }
    func restartTask(_ id: String) -> TaskEntity {
        let sem = DispatchSemaphore(value: 0)
        var result: TaskEntity?
        Task {
            await engine.restartTask(id)
            result = await engine.getTask(id)
            sem.signal()
        }
        sem.wait()
        return result ?? TaskEntity(id: id, url: "", fileName: "", saveDir: "", filePath: "", stagingPath: "",
            totalSize: 0, loaded: 0, speed: 0, status: TaskStatus.failed.rawValue, errorMsg: nil,
            threads: 0, chunkSize: 0, userAgent: nil, headersJson: "{}", createdAt: 0)
    }
    func deleteTask(_ id: String, deleteFiles: Bool) { Task { await engine.deleteTask(id, deleteFiles: deleteFiles) } }
    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }
    func clearCompleted() { Task { await engine.clearCompleted() } }

    private func machineId() -> String {
        if let id = UIDevice.current.identifierForVendor?.uuidString { return id }
        return "ios-device"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

