import Foundation
import ObjectiveC.runtime
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
    //
    // Loose means a file: a name out of someone else's plist is never handed
    // to `UIImage(named:in:)`. A catalogue built from an Icon Composer `.icon`
    // holds names that are image stacks with no bitmap, and iOS 26 answers a
    // lookup of one with an assertion, not nil (Xrash 0.2.0 crashed so).
    private nonisolated static func bundledIcon(in bundle: Bundle) -> UIImage? {
        let info = bundle.infoDictionary ?? [:]
        var names = info["CFBundleIconFiles"] as? [String] ?? []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            names.append(contentsOf: files)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bundle.bundlePath)) ?? []
        // Last first: the list names the smallest icon first. Within a name
        // the longest file is the densest (`@3x` over `@2x` over none).
        for name in names.reversed() {
            let stem = (name as NSString).deletingPathExtension
            let matches = files.filter { $0.hasPrefix(stem) && $0.lowercased().hasSuffix(".png") }
            for file in matches.sorted(by: { $0.count > $1.count }) {
                if let image = UIImage(contentsOfFile: bundle.bundlePath + "/" + file) {
                    return image
                }
            }
        }
        return nil
    }
}

// Pass nil for anything that isn't an app bundle: those rows get the Terminal
// icon so every row shares the same leading inset.
final class ProcessApplicationIconView: UIView {
    static let size: CGFloat = 36

    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    // Distinguishes "never configured" from a nil path, so the first
    // configuration of a non-app row still draws the Terminal icon.
    private var isConfigured = false

    var executablePath: String? {
        didSet {
            guard !isConfigured || executablePath != oldValue else { return }
            isConfigured = true
            reload()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.size, height: Self.size)
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = nil
        guard let executablePath else {
            show(UIImage(named: "TerminalIcon"), isPlaceholder: false)
            return
        }
        show(nil, isPlaceholder: true)
        let scale = traitCollection.displayScale
        loadTask = Task { [weak self] in
            let icon = await ApplicationIconProvider.shared.icon(for: executablePath, scale: scale)
            guard !Task.isCancelled, let self, self.executablePath == executablePath else { return }
            if let icon { self.show(icon, isPlaceholder: false) }
        }
    }

    private func show(_ image: UIImage?, isPlaceholder: Bool) {
        if isPlaceholder {
            imageView.image = UIImage(
                systemName: "app.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)
            )
            imageView.tintColor = .secondaryLabel
            imageView.contentMode = .center
        } else {
            imageView.image = image
            imageView.contentMode = .scaleAspectFill
        }
    }
}
