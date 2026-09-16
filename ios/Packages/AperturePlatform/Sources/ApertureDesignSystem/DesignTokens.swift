import SwiftUI

/// Design tokens, generated in spirit from `contracts/tokens/design-tokens.json` and
/// hand-maintained until the generator lands in a later phase.
///
/// Two requirements here are functional rather than cosmetic, and both come from the
/// field rather than from a style guide.
///
/// Touch targets are 48 points, not the 44 point platform minimum, because inspectors
/// operate the capture controls wearing gloves.
///
/// There is a high-contrast surface set beyond the system light and dark appearances,
/// because the screen is read at up to roughly 100,000 lux in direct sunlight, where
/// translucent chrome over a live camera preview stops being legible.
public enum Tokens {

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    public enum Size {
        /// Minimum interactive dimension. Exceeds the platform minimum deliberately.
        public static let minimumTouchTarget: CGFloat = 48
        /// Primary capture control, sized to be hit without looking.
        public static let captureControl: CGFloat = 76
        public static let iconSmall: CGFloat = 20
        public static let iconMedium: CGFloat = 28
    }

    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 20
        public static let capsule: CGFloat = 999
    }

    /// Semantic colors. Every one resolves through the asset catalog so light, dark, and
    /// increased-contrast variants are supplied by the system rather than branched in code.
    public enum Color {
        public static let surface = SwiftUI.Color("SurfacePrimary", bundle: .module)
        public static let surfaceElevated = SwiftUI.Color("SurfaceElevated", bundle: .module)
        public static let textPrimary = SwiftUI.Color("TextPrimary", bundle: .module)
        public static let textSecondary = SwiftUI.Color("TextSecondary", bundle: .module)
        public static let accent = SwiftUI.Color("Accent", bundle: .module)
        public static let destructive = SwiftUI.Color("Destructive", bundle: .module)
        public static let warning = SwiftUI.Color("Warning", bundle: .module)
        /// Pending sync indication. Never red: unsynced work is a normal state in this
        /// product, not an error, and colouring it as failure teaches inspectors to
        /// distrust a working app.
        public static let pending = SwiftUI.Color("Pending", bundle: .module)
    }

    /// Typography, always relative to Dynamic Type so the largest accessibility sizes
    /// scale rather than clip.
    public enum Typography {
        public static let displayTitle = Font.system(.largeTitle, design: .default, weight: .bold)
        public static let sectionTitle = Font.system(.title3, design: .default, weight: .semibold)
        public static let body = Font.system(.body)
        public static let bodyEmphasis = Font.system(.body, weight: .semibold)
        public static let caption = Font.system(.caption)
        /// Measurements and serial numbers, where digit alignment aids verification.
        public static let numeric = Font.system(.body, design: .monospaced)
    }

    public enum Motion {
        public static let quick: Double = 0.18
        public static let standard: Double = 0.28

        /// Honors Reduce Motion by collapsing to a cross-fade rather than removing the
        /// transition entirely, which would make state changes hard to notice.
        public static func transition(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: quick) : .spring(response: standard, dampingFraction: 0.85)
        }
    }
}
