import UIKit

extension UIFont {
    enum InspectorDesign {
        case standard
        case monospacedDigit
        case monospaced
    }

    // A Dynamic Type font in a weight or design preferredFont(forTextStyle:)
    // doesn't offer. Sized from the default category and then scaled, so the
    // person's text size is applied once, not twice.
    static func inspector(
        _ style: TextStyle,
        weight: Weight = .regular,
        design: InspectorDesign = .standard
    ) -> UIFont {
        let size = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let base: UIFont
        switch design {
        case .standard: base = .systemFont(ofSize: size, weight: weight)
        case .monospacedDigit: base = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        case .monospaced: base = .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}
