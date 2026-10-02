import SwiftUI

/// Uni-app ArkDownloader palette (dark theme).
enum ArkColors {
    static let bg = Color(hex: 0x1F1F1F)
    static let sidebar = Color(hex: 0x181818)
    static let card = Color(hex: 0x252525)
    static let card2 = Color(hex: 0x2D2D2D)
    static let border = Color(hex: 0x3A3A3A)

    static let text = Color(hex: 0xE8E8E8)
    static let sub = Color(hex: 0x9AA0A6)
    static let muted = Color(hex: 0x9AA0A6)

    static let primary = Color(hex: 0x4A84FF)
    static let primaryHover = Color(hex: 0x3D74EB)
    static let primarySoft = Color(hex: 0x4A84FF).opacity(0.15)

    static let success = Color(hex: 0x3ECF8E)
    static let successSoft = Color(hex: 0x3ECF8E).opacity(0.15)
    static let warn = Color(hex: 0xFFB020)
    static let warnSoft = Color(hex: 0xFFB020).opacity(0.15)
    static let error = Color(hex: 0xF07178)
    static let errorSoft = Color(hex: 0xF07178).opacity(0.15)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
