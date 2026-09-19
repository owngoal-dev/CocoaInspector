import UIKit

// One description of a menu, shown two ways: a pull-down UIMenu from iOS 14,
// and a chain of action sheets on iOS 13, which has no menus on buttons.
struct InspectorMenuItem {
    var title: String
    // Shown under the title where the system supports it, after it otherwise.
    var value: String?
    var symbolName: String?
    var isOn = false
    var isDestructive = false
    var isDisabled = false
    // A non-empty list makes this a submenu; `handler` is then unused.
    var children: [InspectorMenuItem] = []
    var handler: () -> Void = {}
}

struct InspectorMenu {
    var title = ""
    // Each inner list is one group, separated from the next by a divider.
    var sections: [[InspectorMenuItem]]
}

// The menu is asked for every time it opens, never stored: what it shows
// (live stats, checkmarks, progress) is current at the moment of the tap, and
// an open menu is not rebuilt underneath the person by the next sample.
final class InspectorMenuButton: UIButton {
    private let provider: () -> InspectorMenu

    init(
        symbolName: String,
        accessibilityLabel: String? = nil,
        provider: @escaping () -> InspectorMenu
    ) {
        self.provider = provider
        super.init(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        setSymbol(symbolName)
        // Without one, the system reads the symbol's own name ("More").
        if let accessibilityLabel { self.accessibilityLabel = accessibilityLabel }
        if #available(iOS 14.0, *) {
            showsMenuAsPrimaryAction = true
            isContextMenuInteractionEnabled = true
        } else {
            addTarget(self, action: #selector(presentRootActionSheet), for: .touchUpInside)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setSymbol(_ name: String) {
        setImage(UIImage(systemName: name), for: .normal)
    }

    @available(iOS 14.0, *)
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self.map { Self.menu(from: $0.provider()) }
        }
    }

    @available(iOS 14.0, *)
    private static func menu(from menu: InspectorMenu) -> UIMenu {
        // A lone group needs no inline wrapper around it.
        if menu.sections.count == 1 {
            return UIMenu(title: menu.title, children: menu.sections[0].map { element(from: $0) })
        }
        return UIMenu(
            title: menu.title,
            children: menu.sections.map { section in
                UIMenu(title: "", options: .displayInline, children: section.map { element(from: $0) })
            }
        )
    }

    @available(iOS 14.0, *)
    private static func element(from item: InspectorMenuItem) -> UIMenuElement {
        let image = item.symbolName.flatMap { UIImage(systemName: $0) }
        if !item.children.isEmpty {
            let submenu = UIMenu(title: item.title, image: image, children: item.children.map { element(from: $0) })
            if #available(iOS 15.0, *) {
                submenu.subtitle = item.value
            }
            return submenu
        }
        let action = UIAction(title: item.title, image: image) { _ in item.handler() }
        if #available(iOS 15.0, *) {
            action.subtitle = item.value
        } else if let value = item.value {
            action.title = "\(item.title): \(value)"
        }
        action.state = item.isOn ? .on : .off
        if item.isDestructive { action.attributes.insert(.destructive) }
        if item.isDisabled { action.attributes.insert(.disabled) }
        return action
    }

    @objc private func presentRootActionSheet() {
        let menu = provider()
        presentActionSheet(title: menu.title, items: menu.sections.flatMap { $0 })
    }

    private func presentActionSheet(title: String, items: [InspectorMenuItem]) {
        guard let presenter = nearestViewController else { return }
        let sheet = UIAlertController(
            title: title.isEmpty ? nil : title,
            message: nil,
            preferredStyle: .actionSheet
        )
        for item in items {
            var label = item.value.map { "\(item.title): \($0)" } ?? item.title
            if item.isOn { label = "✓ \(label)" }
            let action = UIAlertAction(
                title: label,
                style: item.isDestructive ? .destructive : .default
            ) { [weak self] _ in
                if item.children.isEmpty {
                    item.handler()
                } else {
                    self?.presentActionSheet(title: item.title, items: item.children)
                }
            }
            action.isEnabled = !item.isDisabled
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: String(systemLocalized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = bounds
        presenter.present(sheet, animated: true)
    }

    private var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return window?.rootViewController
    }
}
