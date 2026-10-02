import Foundation

enum FormatUtil {
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    static func formatSpeed(_ bytesPerSec: Int64) -> String {
        "\(formatBytes(bytesPerSec))/s"
    }

    static func formatEta(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "—" }
        let s = Int64(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        let h = m / 60
        return "\(h)h \(m % 60)m"
    }

    static func parseHeaders(_ json: String) -> [String: String] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    static func headersToJson(_ headers: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: headers, options: [])
        else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
