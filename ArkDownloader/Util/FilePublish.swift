import Foundation
import UIKit

enum FilePublish {
    /// Default download directory under the app's Documents folder.
    static func defaultDownloadDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ArkDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Resolve a writable directory. If `saveDir` is blank, use the default.
    static func resolveWritableDir(_ saveDir: String?) -> URL {
        if let s = saveDir, !s.isEmpty {
            let url = URL(fileURLWithPath: s)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
        return defaultDownloadDir()
    }

    /// Notify the system that a file was added (triggers media library / Files app indexing).
    static func scanFile(_ url: URL) {
        // iOS does not expose a direct media-scan API; Files app will discover files in
        // the app's Documents directory automatically when sharing is enabled.
    }

    /// Attempt to open a file with the system document interaction controller.
    @MainActor
    static func openFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let vc = UIDocumentInteractionController(url: url)
        // Best-effort: present preview via a transient window.
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
            as? UIWindowScene
        let root = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        return vc.presentPreview(animated: true)
    }
}
