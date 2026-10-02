import Foundation

struct ChunkEntity: Equatable {
    let taskId: String
    let index: Int
    let start: Int64
    let end: Int64
    var loaded: Int64
    var completed: Bool
    var partPath: String
}
