//
//  ProcessListViewController.swift
//  Inspector
//
//  Created by qaq on 3/8/2026.
//

import Combine
import UIKit

final class ProcessListViewController: UITableViewController, UISearchResultsUpdating {
    /// Set by the split view controller, which owns where a process opens.
    var openProcess: (ProcessRow) -> Void = { _ in }

    private let model: ProcessListModel
    private var observation: AnyCancellable?
    private var dataSource: ProcessListDataSource!
    private var shownIdentities: [ProcessIdentity] = []
    // Kept so the row stays highlighted beside its detail column, including
    // across the reloads a live sample causes.
    private var selectedIdentity: ProcessIdentity?
    private let creditsView = ProcessListCreditsView()

    init(model: ProcessListModel) {
        self.model = model
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Inspector")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: statsButton)
        // The first item sits at the edge: the live-updates toggle, with the
        // sort and filter menu beside it.
        navigationItem.rightBarButtonItems = [
            liveUpdatesItem,
            UIBarButtonItem(customView: actionsButton),
        ]

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search by name or PID")
        navigationItem.searchController = search
        definesPresentationContext = true

        clearsSelectionOnViewWillAppear = false
        tableView.register(ProcessRowCell.self, forCellReuseIdentifier: ProcessRowCell.reuseIdentifier)
        dataSource = ProcessListDataSource(tableView: tableView) { [weak self] tableView, indexPath, identity in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ProcessRowCell.reuseIdentifier,
                for: indexPath
            )
            if let row = self?.model.row(for: identity) {
                (cell as? ProcessRowCell)?.configure(with: row)
            }
            return cell
        }

        observation = model.changes.sink { [weak self] in
            self?.render()
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from a pushed detail screen: nothing is open any more.
        if splitViewController?.isCollapsed ?? true {
            selectedIdentity = nil
            if let selected = tableView.indexPathForSelectedRow {
                tableView.deselectRow(at: selected, animated: animated)
            }
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applySidebarAppearance()
    }

    // From iOS 26 the primary column floats as a glass sidebar, where grouped
    // cards read as gray boxes on glass. Beside the detail column the rows go
    // bare, like any sidebar; pushed full-screen they keep their cards.
    private var usesSidebarAppearance: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return splitViewController?.isCollapsed == false
    }

    private var appliedSidebarAppearance: Bool?

    private func applySidebarAppearance() {
        let isSidebar = usesSidebarAppearance
        guard isSidebar != appliedSidebarAppearance else { return }
        appliedSidebarAppearance = isSidebar
        tableView.backgroundColor = isSidebar ? .clear : .systemGroupedBackground
        for cell in tableView.visibleCells {
            style(cell, isSidebar: isSidebar)
        }
    }

    // A sidebar row has no card, and its selection is a rounded highlight
    // rather than a gray slab from edge to edge.
    private func style(_ cell: UITableViewCell, isSidebar: Bool) {
        cell.backgroundColor = isSidebar ? .clear : .secondarySystemGroupedBackground
        guard isSidebar != (cell.selectedBackgroundView is SidebarSelectionView) else { return }
        cell.selectedBackgroundView = isSidebar ? SidebarSelectionView() : nil
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        style(cell, isSidebar: usesSidebarAppearance)
    }

    func updateSearchResults(for searchController: UISearchController) {
        model.searchText = searchController.searchBar.text ?? ""
    }

    // MARK: Rendering

    private func render() {
        let rows = model.visibleRows
        let identities = rows.map(\.id)
        if identities != shownIdentities {
            shownIdentities = identities
            var snapshot = NSDiffableDataSourceSnapshot<Int, ProcessIdentity>()
            if !identities.isEmpty {
                snapshot.appendSections([0])
                snapshot.appendItems(identities)
            }
            // Rows change places without animating: sliding rows made the
            // list restless, and let taps land on rows mid-move.
            dataSource.apply(snapshot, animatingDifferences: false)
            restoreSelection()
        }
        for case let cell as ProcessRowCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  let identity = dataSource.itemIdentifier(for: indexPath),
                  let row = model.row(for: identity) else { continue }
            cell.configure(with: row)
        }
        if let header = tableView.headerView(forSection: 0) {
            header.textLabel?.text = processHeader(visibleCount: rows.count)
            header.setNeedsLayout()
        }
        statsButton.isEnabled = !model.rows.isEmpty
        renderLiveUpdatesItem()
        tableView.tableFooterView = model.rows.isEmpty ? nil : creditsView
        renderOverlay()
    }

    private func restoreSelection() {
        guard let selectedIdentity,
              let indexPath = dataSource.indexPath(for: selectedIdentity),
              tableView.indexPathForSelectedRow != indexPath else { return }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    private func renderOverlay() {
        switch model.phase {
        case .connecting where model.rows.isEmpty:
            tableView.setUnavailableContent(
                .loading(String(localized: "Connecting to the inspector service…"))
            )
        case .failed(let message):
            tableView.setUnavailableContent(
                .message(
                    symbolName: "bolt.slash",
                    title: String(localized: "Can’t Connect"),
                    description: message,
                    actionTitle: String(localized: "Try Again")
                )
            ) { [weak self] in self?.model.start() }
        case .active where !model.rows.isEmpty && model.visibleRows.isEmpty:
            if model.searchText.isEmpty {
                tableView.setUnavailableContent(
                    .message(
                        symbolName: "line.3.horizontal.decrease.circle",
                        title: String(localized: "Nothing to Show"),
                        description: String(
                            localized: "No process matches the “\(model.scopeFilter.label)” filter right now."
                        ),
                        actionTitle: nil
                    )
                )
            } else {
                tableView.setUnavailableContent(
                    .message(
                        symbolName: "magnifyingglass",
                        title: String(localized: "No Results"),
                        description: String(localized: "No processes match “\(model.searchText)”."),
                        actionTitle: nil
                    )
                )
            }
        default:
            tableView.setUnavailableContent(nil)
        }
    }

    // Each fragment is translated on its own, then joined — a single key with
    // every optional clause baked in would be untranslatable.
    private func processHeader(visibleCount: Int) -> String {
        let total = model.rows.count
        var parts = [
            visibleCount == total
                ? String(localized: "\(total) processes")
                : String(localized: "\(visibleCount) of \(total) processes"),
        ]
        if model.scopeFilter != .all {
            parts.append(model.scopeFilter.label)
        }
        if model.isPaused {
            parts.append(String(localized: "Paused"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Table view

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let identifier = "header"
        return tableView.dequeueReusableHeaderFooterView(withIdentifier: identifier)
            ?? UITableViewHeaderFooterView(reuseIdentifier: identifier)
    }

    // Set here rather than through titleForHeaderInSection, which uppercases
    // the text on older systems — once, so later live updates wouldn't match.
    override func tableView(
        _ tableView: UITableView,
        willDisplayHeaderView view: UIView,
        forSection section: Int
    ) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.text = processHeader(
            visibleCount: model.visibleRows.count
        )
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let identity = dataSource.itemIdentifier(for: indexPath),
              let row = model.row(for: identity) else { return }
        selectedIdentity = identity
        openProcess(row)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let identity = dataSource.itemIdentifier(for: indexPath),
              let row = model.row(for: identity),
              row.record.pid > 1 else { return nil }
        let stop = UIContextualAction(
            style: .destructive,
            title: String(localized: "Stop")
        ) { [weak self] _, view, completion in
            self?.confirmSignal(for: row, from: view)
            // The row stays: the process is only gone once a sample says so.
            completion(false)
        }
        return UISwipeActionsConfiguration(actions: [stop])
    }

    // MARK: Signals

    private func confirmSignal(for target: ProcessRow, from sourceView: UIView) {
        let sheet = UIAlertController(
            title: String(localized: "Stop \(target.displayName)?"),
            message: String(
                localized: "“Ask It to Quit” lets the process shut down on its own. “Force Quit” ends it right away, so unsaved work can be lost."
            ),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(
            title: String(localized: "Ask It to Quit (SIGTERM)"),
            style: .destructive
        ) { [weak self] _ in self?.send(.terminate, to: target) })
        sheet.addAction(UIAlertAction(
            title: String(localized: "Force Quit (SIGKILL)"),
            style: .destructive
        ) { [weak self] _ in self?.send(.forceKill, to: target) })
        sheet.addAction(UIAlertAction(title: String(systemLocalized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        sheet.popoverPresentationController?.sourceRect = sourceView.bounds
        present(sheet, animated: true)
    }

    private func send(_ signal: InspectorSignal, to target: ProcessRow) {
        Task {
            do {
                try await model.sendSignal(signal, to: target.id)
            } catch {
                presentFailure(
                    title: String(localized: "Couldn’t Send the Signal"),
                    message: InspectorErrorText.describe(error)
                )
            }
        }
    }

    // MARK: Menus

    private lazy var statsButton = InspectorMenuButton(
        symbolName: {
            if #available(iOS 17.0, *) { return "gauge.with.needle" }
            return "gauge"
        }(),
        accessibilityLabel: String(localized: "System Stats")
    ) { [weak self] in
        InspectorMenu(
            title: String(localized: "This Device"),
            sections: [self?.statsItems() ?? []]
        )
    }

    // Green while samples keep arriving, yellow while they are paused: the
    // button shows the state, and a tap flips it. The two glyphs differ in
    // width, and a bar item sized to its image grew and shrank with every
    // flip, shoving the menu beside it. A custom view with a fixed width, the
    // same as the menu buttons', keeps the glyph centred in a slot that never
    // moves.
    private lazy var liveUpdatesButton: UIButton = {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.addTarget(self, action: #selector(toggleLiveUpdates), for: .touchUpInside)
        return button
    }()

    private lazy var liveUpdatesItem = UIBarButtonItem(customView: liveUpdatesButton)

    private func renderLiveUpdatesItem() {
        let isPaused = model.isPaused
        liveUpdatesButton.setImage(
            UIImage(systemName: isPaused ? "pause.fill" : "dot.radiowaves.left.and.right"),
            for: .normal
        )
        liveUpdatesButton.tintColor = isPaused ? .systemYellow : .systemGreen
        // The label names what a tap does next. While paused the button
        // resumes, so keeping "Pause Live Updates" there reads backwards, and
        // .selected alone leaves the state to be inferred. A custom view is
        // what VoiceOver reads, so the label and traits go on the button.
        liveUpdatesButton.accessibilityLabel = isPaused
            ? String(localized: "Resume Live Updates")
            : String(localized: "Pause Live Updates")
        liveUpdatesButton.accessibilityTraits = isPaused ? [.button, .selected] : .button
    }

    @objc private func toggleLiveUpdates() {
        model.isPaused.toggle()
    }

    private lazy var actionsButton = InspectorMenuButton(
        symbolName: "line.3.horizontal.decrease",
        accessibilityLabel: String(localized: "Sort and Filter")
    ) { [weak self] in
        InspectorMenu(sections: [self?.actionItems() ?? []])
    }

    private func statsItems() -> [InspectorMenuItem] {
        let cpuUsage = InspectorFormat.percent(model.totalCPUFraction)
        let cores = Int(model.system.activeProcessorCount)
        let cpu = cores > 0
            ? "\(cpuUsage) · \(String(localized: "\(cores) cores"))"
            : cpuUsage
        let totalMemory = model.system.physicalMemory
        let freeMemory = model.system.freeMemory
        let usedMemory = totalMemory > freeMemory ? totalMemory - freeMemory : 0
        let memory = String(
            localized: "\(InspectorFormat.memoryBytes(usedMemory)) of \(InspectorFormat.memoryBytes(totalMemory)) in use"
        )
        let processCount = model.rows.count
        let threadCount = Int(model.system.totalThreadCount)
        let processes = String(localized: "\(processCount) processes · \(threadCount) threads")
        return [
            stat(String(localized: "CPU"), value: cpu, symbolName: "cpu"),
            stat(String(localized: "Memory"), value: memory, symbolName: "memorychip"),
            stat(String(localized: "Processes"), value: processes, symbolName: "square.stack.3d.up"),
            stat(
                String(localized: "Up and Running"),
                value: InspectorFormat.duration(model.uptimeNanoseconds),
                symbolName: "clock"
            ),
        ]
    }

    // Choosing a stat copies it, which is the only thing to do with one.
    private func stat(_ title: String, value: String, symbolName: String) -> InspectorMenuItem {
        InspectorMenuItem(title: title, value: value, symbolName: symbolName) {
            UIPasteboard.general.string = "\(title): \(value)"
        }
    }

    private func actionItems() -> [InspectorMenuItem] {
        let model = model
        return [
            InspectorMenuItem(
                title: String(localized: "Sort By"),
                value: model.sortOrder.label,
                symbolName: "arrow.up.arrow.down",
                children: ProcessSortOrder.allCases.map { order in
                    InspectorMenuItem(title: order.label, isOn: order == model.sortOrder) {
                        model.sortOrder = order
                    }
                }
            ),
            InspectorMenuItem(
                title: String(localized: "Show"),
                value: model.scopeFilter.label,
                symbolName: "line.3.horizontal.decrease.circle",
                children: ProcessScopeFilter.allCases.map { filter in
                    InspectorMenuItem(title: filter.label, isOn: filter == model.scopeFilter) {
                        model.scopeFilter = filter
                    }
                }
            ),
        ]
    }
}

extension UIViewController {
    func presentFailure(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }
}

private final class SidebarSelectionView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// Swipe actions only appear on rows the data source calls editable, and the
// diffable data source says no unless told otherwise.
private final class ProcessListDataSource: UITableViewDiffableDataSource<Int, ProcessIdentity> {
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }
}

// The credit line sits under the last row, without a card behind it. Hidden
// while an overlay (connecting/failed/empty) owns the screen.
private final class ProcessListCreditsView: UIView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 64))
        let credit = UIButton(type: .system)
        credit.setTitle(String(localized: "Made with ❤️ by OwnGoal Studio"), for: .normal)
        credit.setTitleColor(.label, for: .normal)
        credit.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        credit.titleLabel?.adjustsFontForContentSizeCategory = true
        credit.addTarget(self, action: #selector(openWebsite), for: .touchUpInside)
        // The credit line reads as a signature, not as something that leaves
        // the app, so the hint says where a tap goes.
        credit.accessibilityHint = String(localized: "Opens the OwnGoal Studio website")

        let version = UILabel()
        version.text = InspectorFormat.appVersion
        version.textColor = .secondaryLabel
        version.font = .inspector(.footnote, design: .monospacedDigit)
        version.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [credit, version])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.alpha = 0.5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func openWebsite() {
        guard let url = URL(string: "https://owngoal.dev") else { return }
        UIApplication.shared.open(url)
    }
}
