import Foundation
import Combine

/// Persists app settings to UserDefaults with a Combine publisher.
final class SettingsRepository: ObservableObject {
    static let shared = SettingsRepository()

    @Published private(set) var settings: AppSettings

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "ark.settings")

    private init() {
        self.settings = SettingsRepository.load()
    }

    func current() -> AppSettings { settings }

    func update(_ transform: (AppSettings) -> AppSettings) {
        queue.sync {
            let next = transform(settings).normalized()
            settings = next
            persist(next)
        }
    }

    private func persist(_ s: AppSettings) {
        defaults.set(s.defaultSaveDir, forKey: "save_dir")
        defaults.set(s.maxThreads, forKey: "max_threads")
        defaults.set(s.maxConcurrentTasks, forKey: "max_concurrent")
        defaults.set(s.chunkSize, forKey: "chunk_size")
        defaults.set(s.autoStart, forKey: "auto_start")
        defaults.set(s.notifyOnComplete, forKey: "notify_on_complete")
        defaults.set(s.userAgent, forKey: "user_agent")
        defaults.set(s.httpUserAgent, forKey: "http_user_agent")
        defaults.set(s.defaultHeadersJson, forKey: "headers_json")
        defaults.set(s.rpcEnabled, forKey: "rpc_enabled")
        defaults.set(s.rpcPort, forKey: "rpc_port")
        defaults.set(s.rpcRemote, forKey: "rpc_remote")
        defaults.set(s.rpcToken, forKey: "rpc_token")
        defaults.set(s.parsePageUrl, forKey: "parse_page_url")
    }

    private static func load() -> AppSettings {
        let d = UserDefaults.standard
        var s = AppSettings()
        s.defaultSaveDir = d.string(forKey: "save_dir") ?? ""
        s.maxThreads = (d.object(forKey: "max_threads") as? Int) ?? AppSettings.defaultConnections
        s.maxConcurrentTasks = (d.object(forKey: "max_concurrent") as? Int) ?? AppSettings.defaultMaxRunning
        s.chunkSize = (d.object(forKey: "chunk_size") as? Int) ?? AppSettings.defaultChunk
        s.autoStart = d.object(forKey: "auto_start") as? Bool ?? true
        s.notifyOnComplete = d.object(forKey: "notify_on_complete") as? Bool ?? true
        s.userAgent = d.string(forKey: "user_agent") ?? AppSettings.baiduUA
        s.httpUserAgent = d.string(forKey: "http_user_agent") ?? AppSettings.defaultHttpUserAgent
        s.defaultHeadersJson = d.string(forKey: "headers_json") ?? "{}"
        s.rpcEnabled = d.object(forKey: "rpc_enabled") as? Bool ?? true
        s.rpcPort = (d.object(forKey: "rpc_port") as? Int) ?? AppSettings.defaultRpcPort
        s.rpcRemote = d.object(forKey: "rpc_remote") as? Bool ?? true
        s.rpcToken = d.string(forKey: "rpc_token") ?? ""
        s.parsePageUrl = AppSettings.normalizeParsePageUrl(d.string(forKey: "parse_page_url"))
        return s.normalized()
    }
}
