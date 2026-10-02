import Foundation

/// One file inside a folder download task.
struct FolderChildFile: Codable, Equatable {
    let url: String
    let name: String
    let relativePath: String
    var size: Int64 = 0
    var headersJson: String = "{}"
    var userAgent: String? = nil
    var completed: Bool = false
    var filePath: String = ""

    enum CodingKeys: String, CodingKey {
        case url, name, relativePath, size, headersJson, userAgent, completed, filePath
    }

    static func encodeList(_ list: [FolderChildFile]) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(list) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeList(_ raw: String?) -> [FolderChildFile] {
        guard let raw = raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([FolderChildFile].self, from: data)) ?? []
    }
}
