import Foundation

enum TaskStatus: String, Codable, CaseIterable {
    case pending
    case downloading
    case paused
    case merging
    case completed
    case failed
    case canceled

    /// Legacy / RPC display strings (aligned with Android).
    var apiValue: String {
        switch self {
        case .pending: return "pending"
        case .downloading: return "running"
        case .paused: return "paused"
        case .merging: return "merging"
        case .completed: return "done"
        case .failed: return "error"
        case .canceled: return "error"
        }
    }

    /// Gopeed / mobile-aligned status.
    var v1Value: String {
        switch self {
        case .pending: return "pending"
        case .downloading, .merging: return "running"
        case .paused: return "paused"
        case .completed: return "done"
        case .failed, .canceled: return "error"
        }
    }

    var isActive: Bool {
        self == .downloading || self == .merging || self == .pending
    }

    static func fromApi(_ value: String?) -> TaskStatus? {
        guard let v = value?.lowercased() else { return nil }
        switch v {
        case "pending": return .pending
        case "downloading", "running": return .downloading
        case "paused": return .paused
        case "merging": return .merging
        case "completed", "done": return .completed
        case "failed", "error": return .failed
        case "cancelled", "canceled": return .canceled
        default: return nil
        }
    }
}
