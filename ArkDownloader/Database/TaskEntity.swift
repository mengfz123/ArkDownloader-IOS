import Foundation

struct TaskEntity: Equatable {
    let id: String
    var url: String
    var fileName: String
    var saveDir: String
    var filePath: String
    var stagingPath: String
    var totalSize: Int64
    var loaded: Int64
    var speed: Int64
    var status: String
    var errorMsg: String?
    var threads: Int
    var chunkSize: Int
    var userAgent: String?
    var headersJson: String
    var createdAt: Int64
    var startedAt: Int64?
    var completedAt: Int64?
    var isFolder: Bool = false
    var folderChildrenJson: String = "[]"
    var currentFileName: String? = nil
    var filesCompleted: Int = 0
    var filesTotal: Int = 0
}

struct ChunkEntity: Equatable {
    let taskId: String
    let index: Int
    let start: Int64
    let end: Int64
    var loaded: Int64
    var completed: Bool
    var partPath: String
}
