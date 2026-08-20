import Foundation
import ObjectiveC.runtime
import SwiftUI
import UIKit

enum ApplicationBundleLocator {
    // proc_pidpath for an app extension points inside
    // Host.app/PlugIns/Extension.appex. Taking the first .app component makes
    // both the main executable and every plug-in resolve to the host app.
    static func hostApplicationPath(for executablePath: String) -> String? {
        let path = (executablePath as NSString).standardizingPath
        guard path.range(of: "/Bundle/Application/", options: .caseInsensitive) != nil
                || path.range(of: "/Applications/", options: .caseInsensitive) != nil,
              let appBoundary = path.range(of: ".app/", options: .caseInsensitive) else {
            return nil
        }
        let trailingSlash = path.index(before: appBoundary.upperBound)
        return String(path[..<trailingSlash])
    }
}

actor ApplicationIconProvider {
    static let shared = ApplicationIconProvider()

    private static let listRowFormat: Int32 = 1
    private static let fallbackBundleIdentifier = "com.apple.WebSheet"
    private var cachedIcons: [String: UIImage] = [:]
    private var pendingLoads: [String: Task<UIImage?, Never>] = [:]

    func icon(for executablePath: String, scale: CGFloat) async -> UIImage? {
        guard let applicationPath = ApplicationBundleLocator.hostApplicationPath(
            for: executablePath
        ) else { return nil }

        let key = "\(applicationPath)#\(scale)"
        if let cached = cachedIcons[key] { return cached }
        if let pending = pendingLoads[key] { return await pending.value }

        let load = Task.detached(priority: .utility) {
            Self.loadIcon(applicationPath: applicationPath, scale: scale)
        }
        pendingLoads[key] = load
        let icon = await load.value
        pendingLoads[key] = nil
        if let icon { cachedIcons[key] = icon }
        return icon
    }

    private nonisolated static func loadIcon(
        applicationPath: String,
        scale: CGFloat
    ) -> UIImage? {
        autoreleasepool {
            let bundle = Bundle(path: applicationPath)
            if let identifier = bundle?.bundleIdentifier,
               let icon = iconServicesImage(bundleIdentifier: identifier, scale: scale) {
                return icon
            }
            if let bundle, let icon = bundledIcon(in: bundle) {
                return icon
            }
            return iconServicesImage(
                bundleIdentifier: fallbackBundleIdentifier,
                scale: scale
            )
        }
    }

    private typealias ApplicationIconImplementation = @convention(c) (
        AnyObject,
        Selector,
        NSString,
        Int32,
        CGFloat
    ) -> Unmanaged<UIImage>?

    private nonisolated static func iconServicesImage(
        bundleIdentifier: String,
        scale: CGFloat
    ) -> UIImage? {
        let selector = NSSelectorFromString(
            "_applicationIconImageForBundleIdentifier:format:scale:"
        )
        guard let method = class_getClassMethod(UIImage.self, selector) else { return nil }
        let implementation = unsafeBitCast(
            method_getImplementation(method),
            to: ApplicationIconImplementation.self
        )
        return implementation(
            UIImage.self,
            selector,
            bundleIdentifier as NSString,
            listRowFormat,
            scale
        )?.takeUnretainedValue()
    }

    // IconServices is preferred because it understands compiled asset
    // catalogs. Loose CFBundleIconFiles remain a useful fallback for older and
    // hand-packaged jailbreak apps.
    private nonisolated static func bundledIcon(in bundle: Bundle) -> UIImage? {
        let info = bundle.infoDictionary ?? [:]
        var names = info["CFBundleIconFiles"] as? [String] ?? []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            names.append(contentsOf: files)
        }
        for name in names.reversed() {
            if let image = UIImage(
                named: name,
                in: bundle,
                compatibleWith: nil
            ) {
                return image
            }
        }
        return nil
    }
}

struct ProcessApplicationIcon: View, Equatable {
    let executablePath: String

    @Environment(\.displayScale) private var displayScale
    @State private var icon: UIImage?

    private let size: CGFloat = 36

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.executablePath == rhs.executablePath
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.tertiary)
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: requestID) {
            icon = await ApplicationIconProvider.shared.icon(
                for: executablePath,
                scale: displayScale
            )
        }
    }

    private var requestID: String {
        "\(executablePath)#\(displayScale)"
    }
}
