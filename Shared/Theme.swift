import SwiftUI
import WidgetKit

/// Colour palettes for the contribution grid.
///
/// Each theme has a dark and a light ramp of five stops, matching GitHub's
/// "Less → More" legend. The empty stop is shared so every theme sits on the
/// same widget background.
enum ContributionTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case github
    case ocean
    case amber
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .ocean: "Ocean"
        case .amber: "Amber"
        case .mono: "Mono"
        }
    }

    /// The fill for a cell at `level`.
    ///
    /// On the macOS desktop, widgets switch to a monochrome "vibrant" or "accented"
    /// style while windows cover them. Hue is lost there, so levels become
    /// steps of opacity and the graph stays readable.
    func color(
        for level: ContributionLevel,
        in scheme: ColorScheme,
        renderingMode: WidgetRenderingMode = .fullColor
    ) -> Color {
        guard renderingMode == .fullColor else {
            return Color.primary.opacity(Self.monochromeOpacity[level.rawValue])
        }
        let ramp = scheme == .dark ? darkRamp : lightRamp
        return Color(hex: ramp[level.rawValue])
    }

    /// A strong colour from the ramp, for icons and highlights next to the grid.
    func accent(in scheme: ColorScheme) -> Color {
        color(for: scheme == .dark ? .fourth : .third, in: scheme)
    }

    // MARK: Ramps (empty → most active)

    private static let monochromeOpacity: [Double] = [0.1, 0.32, 0.52, 0.76, 1]

    private var darkRamp: [UInt32] {
        switch self {
        case .github: [0x161B22, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
        case .ocean: [0x161B22, 0x0B2F55, 0x10569B, 0x2F81F7, 0x79C0FF]
        case .amber: [0x161B22, 0x4A2C03, 0x8A5300, 0xD18616, 0xF9C74F]
        case .mono: [0x161B22, 0x30363D, 0x6E7681, 0xADBAC7, 0xF0F6FC]
        }
    }

    private var lightRamp: [UInt32] {
        switch self {
        case .github: [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        case .ocean: [0xEBEDF0, 0xB6E3FF, 0x54AEFF, 0x0969DA, 0x0A3069]
        case .amber: [0xEBEDF0, 0xFFDF8A, 0xF5B13D, 0xD4870F, 0x8A5300]
        case .mono: [0xEBEDF0, 0xC4CBD3, 0x8C959F, 0x57606A, 0x24292F]
        }
    }
}

/// Surface colours shared by every widget size, taken from GitHub's own UI.
enum WidgetSurface {
    static func background(in scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? 0x0D1117 : 0xFFFFFF)
    }

    static func border(in scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? 0x30363D : 0xD0D7DE)
    }
}

extension Color {
    /// An sRGB colour from a `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
