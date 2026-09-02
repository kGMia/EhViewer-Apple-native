import SwiftUI
import EhSettings

extension AppAccentColor {
    /// `nil` means that no tint override is installed, preserving the native
    /// system/asset accent instead of resolving `.accentColor` recursively.
    var swiftUIColor: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .indigo: .indigo
        }
    }

    var previewColor: Color {
        swiftUIColor ?? .accentColor
    }
}

struct AppAccentTintModifier: ViewModifier {
    let accent: AppAccentColor

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color = accent.swiftUIColor {
            content.tint(color)
        } else {
            content
        }
    }
}
