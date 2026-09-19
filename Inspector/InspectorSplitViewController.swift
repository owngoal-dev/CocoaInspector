import UIKit

// The classic two-column split view: the column-style API only starts at
// iOS 14, while this one behaves the same from iOS 13 on. The process list is
// the primary column; each opened process gets a fresh navigation stack in the
// secondary one, which hosts the drill-downs (threads, files, ports, modules).
final class InspectorSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let model: ProcessListModel
    private let listNavigation: UINavigationController

    init(model: ProcessListModel) {
        self.model = model
        let list = ProcessListViewController(model: model)
        listNavigation = UINavigationController(rootViewController: list)
        super.init(nibName: nil, bundle: nil)
        list.openProcess = { [weak self] row in self?.open(row) }
        delegate = self
        viewControllers = [listNavigation, makePlaceholder()]
        // Both columns from the start, so an iPad launch doesn't open on an
        // empty detail pane with the process list hidden behind a button.
        if #available(iOS 14.0, *) {
            preferredDisplayMode = .oneBesideSecondary
        } else {
            preferredDisplayMode = .allVisible
        }
        minimumPrimaryColumnWidth = 320
        maximumPrimaryColumnWidth = 380
        preferredPrimaryColumnWidthFraction = 0.4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func open(_ row: ProcessRow) {
        let detail = ProcessDetailViewController(row: row, model: model)
        showDetailViewController(UINavigationController(rootViewController: detail), sender: self)
    }

    /// Returns to the process list where the detail screen covers it.
    func closeDetail() {
        guard isCollapsed else { return }
        listNavigation.popToRootViewController(animated: true)
    }

    private func makePlaceholder() -> UINavigationController {
        UINavigationController(rootViewController: ProcessPlaceholderViewController())
    }

    // MARK: UISplitViewControllerDelegate

    // A compact launch has nothing selected yet: show the list, not the
    // "Select a Process" placeholder.
    func splitViewController(
        _ splitViewController: UISplitViewController,
        collapseSecondary secondaryViewController: UIViewController,
        onto primaryViewController: UIViewController
    ) -> Bool {
        let top = (secondaryViewController as? UINavigationController)?.viewControllers.first
        return top is ProcessPlaceholderViewController
    }

    // The default pops an opened process back out into the secondary column.
    // With nothing opened there is nothing to pop, so the placeholder returns.
    func splitViewController(
        _ splitViewController: UISplitViewController,
        separateSecondaryFrom primaryViewController: UIViewController
    ) -> UIViewController? {
        listNavigation.topViewController is UINavigationController ? nil : makePlaceholder()
    }
}

private final class ProcessPlaceholderViewController: UIViewController {
    override func loadView() {
        view = InspectorUnavailableView(
            .message(
                symbolName: "square.stack.3d.up",
                title: String(localized: "Select a Process"),
                description: String(localized: "Choose a process on the left to see what it’s up to."),
                actionTitle: nil
            )
        )
    }
}
