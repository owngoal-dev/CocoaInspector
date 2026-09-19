import Foundation

// String(localized:) and String.LocalizationValue start at iOS 15. This is the
// same call shape for older systems: an interpolated literal becomes the
// format key the string catalog already stores ("\(count) processes" looks up
// "%lld processes"), and the arguments are applied to the translated format,
// so plural variations keep working.
//
// The specifier follows the argument's type exactly as Foundation's does —
// Int is %lld, Int32 is %d, String is %@ — because the specifier is part of
// the catalog key.
struct LocalizedText: ExpressibleByStringInterpolation {
    let key: String
    let arguments: [CVarArg]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [CVarArg] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + interpolationCount * 4)
        }

        mutating func appendLiteral(_ literal: String) {
            key += LocalizedText.escaped(literal)
        }

        mutating func appendInterpolation(_ value: Int) {
            key += "%lld"
            arguments.append(value)
        }

        mutating func appendInterpolation(_ value: Int32) {
            key += "%d"
            arguments.append(value)
        }

        mutating func appendInterpolation(_ value: String) {
            key += "%@"
            arguments.append(value)
        }
    }

    private static func escaped(_ literal: String) -> String {
        literal.replacingOccurrences(of: "%", with: "%%")
    }
}

extension String {
    init(localized text: LocalizedText) {
        let format = Bundle.main.localizedString(forKey: text.key, value: nil, table: nil)
        self = text.arguments.isEmpty
            ? format
            : String(format: format, locale: .current, arguments: text.arguments)
    }

    // The system's own translation of a standard button title, so an alert's
    // Cancel button reads the way it does everywhere else on the device.
    init(systemLocalized key: String) {
        self = Bundle(identifier: "com.apple.UIKit")?
            .localizedString(forKey: key, value: key, table: nil) ?? key
    }
}
