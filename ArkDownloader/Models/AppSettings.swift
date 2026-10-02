import Foundation

struct AppSettings: Codable, Equatable {
    var defaultSaveDir: String = ""
    var maxThreads: Int = AppSettings.defaultConnections
    var maxConcurrentTasks: Int = AppSettings.defaultMaxRunning
    var chunkSize: Int = AppSettings.defaultChunk
    var autoStart: Bool = true
    var notifyOnComplete: Bool = true
    var userAgent: String = AppSettings.baiduUA
    var httpUserAgent: String = AppSettings.defaultHttpUserAgent
    var defaultHeadersJson: String = "{}"
    var rpcEnabled: Bool = true
    var rpcPort: Int = AppSettings.defaultRpcPort
    var rpcRemote: Bool = true
    var rpcToken: String = ""
    var parsePageUrl: String = AppSettings.defaultParsePageUrl

    var downloadDir: String { defaultSaveDir }
    var connections: Int { maxThreads }
    var maxRunning: Int { maxConcurrentTasks }
    var chunkSizeMb: Int {
        (chunkSize / (1024 * 1024)).clamped(to: AppSettings.minChunkMb...AppSettings.maxChunkMb)
    }

    static let appName = "ArkDownloader"
    static let version = "1.0.0"
    static let minChunkMb = 1
    static let maxChunkMb = 5
    static let minChunk = minChunkMb * 1024 * 1024
    static let maxChunk = maxChunkMb * 1024 * 1024
    static let defaultChunk = minChunk
    /// Baidu PCS single-chunk cap (5 MiB).
    static let chunkBaidu = maxChunk
    static let maxThreads = 16
    static let defaultConnections = 8
    static let maxRunning = 10
    static let defaultMaxRunning = 3
    static let defaultRpcPort = 18766
    static let baiduUA = "netdisk;P2SP;3.0.20.233;netdisk;8.7.9.102;PC;PC-Windows;10.0.19045;WindowsBaiduYunGuanJia"
    static let defaultUserAgent = baiduUA
    static let defaultHttpUserAgent = "ArkDownloader/1.0"
    static let defaultParsePageUrl = "https://clouds.arkdream.top/c?embed=1&theme=dark&jq=false"

    static func chunkBytesFromMb(_ mb: Int) -> Int {
        mb.clamped(to: minChunkMb...maxChunkMb) * 1024 * 1024
    }

    static func normalizeParsePageUrl(_ raw: String?) -> String {
        let u = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if u.isEmpty { return defaultParsePageUrl }
        if u.hasPrefix("http://") || u.hasPrefix("https://") { return u }
        if u.hasPrefix("//") { return "https:\(u)" }
        return defaultParsePageUrl
    }

    /// Ensure embed params: theme=dark and jq=false.
    static func ensureParsePageEmbedParams(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else {
            var out = url
            if !out.contains("theme=") {
                out += (out.contains("?") ? "&" : "?") + "theme=dark"
            }
            if !out.contains("jq=") {
                out += (out.contains("?") ? "&" : "?") + "jq=false"
            }
            return out
        }
        var items = comps.queryItems ?? []
        var hasTheme = false
        var hasJq = false
        for (i, item) in items.enumerated() {
            if item.name.lowercased() == "theme" {
                items[i] = URLQueryItem(name: "theme", value: "dark")
                hasTheme = true
            } else if item.name.lowercased() == "jq" {
                items[i] = URLQueryItem(name: "jq", value: "false")
                hasJq = true
            }
        }
        if !hasTheme { items.append(URLQueryItem(name: "theme", value: "dark")) }
        if !hasJq { items.append(URLQueryItem(name: "jq", value: "false")) }
        comps.queryItems = items
        return comps.string ?? url
    }

    func normalized() -> AppSettings {
        var s = self
        s.maxThreads = maxThreads.clamped(to: 1...AppSettings.maxThreads)
        s.maxConcurrentTasks = maxConcurrentTasks.clamped(to: 1...AppSettings.maxRunning)
        s.chunkSize = chunkSize.clamped(to: AppSettings.minChunk...AppSettings.maxChunk)
        s.rpcPort = rpcPort.clamped(to: 0...65535)
        s.userAgent = userAgent.isEmpty ? AppSettings.baiduUA : userAgent
        s.httpUserAgent = httpUserAgent.isEmpty ? AppSettings.defaultHttpUserAgent : httpUserAgent
        s.parsePageUrl = AppSettings.normalizeParsePageUrl(parsePageUrl)
        return s
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
