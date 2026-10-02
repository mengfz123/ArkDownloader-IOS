import Foundation

struct DownloadTask: Identifiable, Equatable {
    let id: String
    let url: String
    let fileName: String
    let saveDir: String
    let filePath: String
    let totalSize: Int64
    let loaded: Int64
    let speed: Int64
    let status: TaskStatus
    let errorMsg: String?
    let threads: Int
    let chunkSize: Int
    let userAgent: String?
    let headersJson: String
    let createdAt: Int64
    let startedAt: Int64?
    let completedAt: Int64?
    let isFolder: Bool
    let folderChildrenJson: String
    let currentFileName: String?
    let filesCompleted: Int
    let filesTotal: Int

    var progress: Double {
        totalSize > 0 ? (Double(loaded) / Double(totalSize) * 100.0).clamped(to: 0...100) : 0
    }
    var speedBps: Int64 { speed }
}
