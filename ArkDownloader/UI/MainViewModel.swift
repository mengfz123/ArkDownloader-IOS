import Foundation
import Combine

/// UI-facing view model. Mirrors the Android MainViewModel.
@MainActor
final class MainViewModel: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var settings: AppSettings
    @Published private(set) var rpcRunning: Bool = false

    let repository: DownloadRepository
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(repository: DownloadRepository) {
        self.repository = repository
        self.settings = repository.settingsRepo.current()
        self.rpcRunning = repository.rpcServer.running

        // Mirror settings changes.
        repository.settingsRepo.$settings
            .receive(on: DispatchQueue.main)
            .assign(to: &$settings)

        // Poll task list every 800ms (SQLite has no native change notification here).
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { await self?.refreshTasks() }
        }
        Task { await refreshTasks() }
    }

    deinit { timer?.invalidate() }

    func refreshTasks() async {
        let entities = await repository.engine.observeTasks()
        self.tasks = entities.map { $0.toModel() }
        self.rpcRunning = repository.rpcServer.running
    }

    func createTasks(_ urls: [String], fileName: String?, threads: Int, chunkSize: Int, headersJson: String) {
        Task {
            await repository.createTasksFromUrls(urls, fileName: fileName, threads: threads, chunkSize: chunkSize, headersJson: headersJson)
        }
    }

    func createTask(_ url: String, fileName: String?, threads: Int, chunkSize: Int, headersJson: String) {
        createTasks([url], fileName: fileName, threads: threads, chunkSize: chunkSize, headersJson: headersJson)
    }

    func pauseTask(_ task: DownloadTask) {
        Task { await repository.engine.pauseTask(task.id) }
    }
    func resumeTask(_ task: DownloadTask) {
        Task { await repository.engine.resumeTask(task.id) }
    }
    func restartTask(_ task: DownloadTask) {
        Task { await repository.engine.restartTask(task.id) }
    }
    func deleteTask(_ task: DownloadTask, deleteFiles: Bool) {
        Task { await repository.engine.deleteTask(task.id, deleteFiles: deleteFiles) }
    }
    func pauseAll() { Task { await repository.engine.pauseAll() } }
    func resumeAll() { Task { await repository.engine.resumeAll() } }
    func clearCompleted() { Task { await repository.engine.clearCompleted() } }

    func updateSettings(_ transform: @escaping (AppSettings) -> AppSettings) {
        repository.settingsRepo.update(transform)
    }

    static func parseUrlPaste(_ paste: String) -> [String] {
        paste.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension TaskEntity {
    func toModel() -> DownloadTask {
        DownloadTask(id: id, url: url, fileName: fileName, saveDir: saveDir, filePath: filePath,
            totalSize: totalSize, loaded: loaded, speed: speed,
            status: TaskStatus(rawValue: status) ?? .failed, errorMsg: errorMsg, threads: threads,
            chunkSize: chunkSize, userAgent: userAgent, headersJson: headersJson, createdAt: createdAt,
            startedAt: startedAt, completedAt: completedAt, isFolder: isFolder,
            folderChildrenJson: folderChildrenJson, currentFileName: currentFileName,
            filesCompleted: filesCompleted, filesTotal: filesTotal)
    }
}
