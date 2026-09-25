import UIKit

final class ProcessDetailListViewController: UITableViewController, UISearchResultsUpdating {
    private let kind: ProcessDetailKind
    private let identity: ProcessIdentity
    private let processName: String
    private let model: ProcessListModel
    private let columns: [DetailColumn]
    private let defaults = UserDefaults.standard

    private var detail: ProcessDetailSnapshot?
    // Filtering and sorting run once per load, query, or order change — never
    // while cells are being configured.
    private var visible = ProcessDetailRecords()
    private var rows: [(cells: [String], inspection: DetailRowInspection)] = []
    private var rowsByID: [String: (cells: [String], inspection: DetailRowInspection)] = [:]
    private var dataSource: UITableViewDiffableDataSource<Int, String>!
    private var failure: String?
    // Details that come back quickly show a blank screen, not a flash of a
    // spinner; details that take a while show one long enough to be read.
    private let loadingIndicator = DelayedLoadingIndicator()
    private var searchText = ""
    private var sort: ProcessDetailSort {
        didSet {
            guard sort != oldValue else { return }
            defaults.set(sort.order.rawValue, forKey: sortOrderKey)
            defaults.set(sort.ascending, forKey: sortAscendingKey)
            rebuildVisible()
        }
    }

    // One stored order per kind: "sort by size" means nothing to threads.
    private var sortOrderKey: String { "processDetail.sortOrder.\(kind.rawValue)" }
    private var sortAscendingKey: String { "processDetail.sortAscending.\(kind.rawValue)" }

    init(
        kind: ProcessDetailKind,
        identity: ProcessIdentity,
        processName: String,
        model: ProcessListModel
    ) {
        self.kind = kind
        self.identity = identity
        self.processName = processName
        self.model = model
        columns = ProcessDetailTable.columns(for: kind)
        let fallback = ProcessDetailSort.default(for: kind)
        let orderKey = "processDetail.sortOrder.\(kind.rawValue)"
        let ascendingKey = "processDetail.sortAscending.\(kind.rawValue)"
        sort = ProcessDetailSort(
            order: defaults.string(forKey: orderKey)
                .flatMap(ProcessDetailSortOrder.init(rawValue:)) ?? fallback.order,
            ascending: defaults.object(forKey: ascendingKey) as? Bool ?? fallback.ascending
        )
        // Plain rows keep the header pinned to the top of the list while it
        // scrolls, which is what makes this read as a table.
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var screenTitle: String {
        switch kind {
        case .summary: String(localized: "Overview")
        case .threads: String(localized: "Threads")
        case .files: String(localized: "Open Files")
        case .ports: String(localized: "Mach Ports")
        case .modules: String(localized: "Loaded Modules")
        }
    }

    private var searchPrompt: String {
        switch kind {
        case .summary: String(localized: "Search")
        case .threads: String(localized: "Search by name or thread ID")
        case .files: String(localized: "Search by path or descriptor")
        case .ports: String(localized: "Search by port name or rights")
        case .modules: String(localized: "Search by name or path")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = screenTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: shareButton)

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = searchPrompt
        navigationItem.searchController = search
        definesPresentationContext = true

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        refreshControl = refresh

        tableView.register(DetailTableCell.self, forCellReuseIdentifier: DetailTableCell.reuseIdentifier)
        tableView.register(
            DetailTableHeaderView.self,
            forHeaderFooterViewReuseIdentifier: DetailTableHeaderView.reuseIdentifier
        )
        tableView.rowHeight = 44
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: DetailTableMetrics.horizontalInset,
            bottom: 0,
            right: 0
        )
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: DetailTableCell.reuseIdentifier,
                for: indexPath
            )
            if let self, let row = self.rowsByID[id] {
                (cell as? DetailTableCell)?.configure(columns: self.columns, cells: row.cells)
            }
            // Nothing on a row says that it opens onto the whole record.
            cell.accessibilityHint = String(localized: "Shows the full record")
            return cell
        }
        loadingIndicator.onChange = { [weak self] in
            self?.render()
        }
        render()
        Task { await load() }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != searchText else { return }
        searchText = text
        rebuildVisible()
    }

    // MARK: Rendering

    private func render() {
        // Rows that arrive just after the spinner appeared wait out its
        // minimum time rather than blinking it away; a message never waits.
        if loadingIndicator.holdsContent, !rows.isEmpty { return }
        let showsLoading = loadingIndicator.update(isLoading: failure == nil && detail == nil)
        shareButton.isEnabled = detail != nil
        // An overlay owns the whole screen, so nothing is listed under one.
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        if !rows.isEmpty {
            snapshot.appendSections([0])
            snapshot.appendItems(rows.map(\.inspection.id))
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        // A refresh keeps a row's identity but can change what it says.
        for case let cell as DetailTableCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let row = rowsByID[id] else { continue }
            cell.configure(columns: columns, cells: row.cells)
        }
        (tableView.headerView(forSection: 0) as? DetailTableHeaderView)?
            .configure(columns: columns, sort: sort)
        renderFooter()
        if let failure {
            tableView.setUnavailableContent(
                .message(
                    symbolName: "exclamationmark.triangle",
                    title: String(localized: "Couldn’t Load This"),
                    description: failure,
                    actionTitle: String(localized: "Try Again")
                )
            ) { [weak self] in
                Task { await self?.load() }
            }
        } else if let detail {
            if ProcessDetailRecords.total(in: detail, kind: kind) == 0 {
                tableView.setUnavailableContent(
                    .message(
                        symbolName: "tray",
                        title: String(localized: "Nothing Here Yet"),
                        description: nil,
                        actionTitle: nil
                    )
                )
            } else if visible.isEmpty {
                tableView.setUnavailableContent(
                    .message(
                        symbolName: "magnifyingglass",
                        title: String(localized: "No Results"),
                        description: String(localized: "Nothing matches “\(searchText)”."),
                        actionTitle: nil
                    )
                )
            } else {
                tableView.setUnavailableContent(nil)
            }
        } else {
            tableView.setUnavailableContent(showsLoading ? .loading(nil) : nil)
        }
    }

    private func rebuildVisible() {
        if let detail {
            visible = ProcessDetailRecords.visible(
                in: detail,
                kind: kind,
                sort: sort,
                query: searchText
            )
        } else {
            visible = ProcessDetailRecords()
        }
        switch kind {
        case .summary:
            rows = []
        case .threads:
            rows = visible.threads.map {
                (ProcessDetailTable.cells(thread: $0), DetailRowInspection(thread: $0))
            }
        case .files:
            rows = visible.files.map {
                (ProcessDetailTable.cells(file: $0), DetailRowInspection(file: $0))
            }
        case .ports:
            rows = visible.ports.map {
                (ProcessDetailTable.cells(port: $0), DetailRowInspection(port: $0))
            }
        case .modules:
            rows = visible.modules.map {
                (ProcessDetailTable.cells(module: $0), DetailRowInspection(module: $0))
            }
        }
        // The data source identifies rows by id; one the daemon reports twice
        // is listed once.
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.inspection.id).inserted }
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.inspection.id, $0) })
        render()
    }

    private var footerText: String? {
        guard let detail else { return nil }
        var lines = [String]()
        let total = ProcessDetailRecords.total(in: detail, kind: kind)
        if total > 0 {
            lines.append(
                visible.count == total
                    ? String(localized: "\(total) in total")
                    : String(localized: "\(visible.count) of \(total) shown")
            )
        }
        if detail.status == .partial {
            lines.append(String(localized: "Some of this couldn’t be read (error \(detail.errorCode))."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // Under the last row rather than a section footer, which a plain table
    // pins to the bottom of the screen, over the rows.
    private func renderFooter() {
        guard let text = footerText, !rows.isEmpty else {
            tableView.tableFooterView = nil
            return
        }
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        let inset = DetailTableMetrics.horizontalInset
        let width = tableView.bounds.width - inset * 2
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height + 24))
        label.frame = CGRect(x: inset, y: 12, width: width, height: height)
        label.autoresizingMask = [.flexibleWidth]
        footer.addSubview(label)
        tableView.tableFooterView = footer
    }

    // MARK: Table view

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: DetailTableHeaderView.reuseIdentifier
        ) as? DetailTableHeaderView
        header?.configure(columns: columns, sort: sort)
        header?.selectOrder = { [weak self] order in self?.sort.select(order) }
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        ceil(UIFont.inspector(.caption1, weight: .semibold).lineHeight) + 16
    }

    // A row shows only what fits on one line; tapping it opens everything the
    // record carries, including the full path.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let row = rowsByID[id] else { return }
        let sheet = UINavigationController(
            rootViewController: RowInspectionViewController(inspection: row.inspection)
        )
        if #available(iOS 15.0, *) {
            sheet.sheetPresentationController?.detents = [.medium(), .large()]
        }
        present(sheet, animated: true)
    }

    // MARK: Loading

    @objc private func refreshPulled() {
        Task {
            await load()
            refreshControl?.endRefreshing()
        }
    }

    private func load() async {
        failure = nil
        do {
            let result = try await model.details(kind, for: identity)
            switch result.status {
            case .available, .partial:
                detail = result
            case .processExited:
                failure = String(localized: "This process has ended.")
            case .permissionDenied:
                failure = String(
                    localized: "This app isn’t allowed to read that (error \(Int(result.errorCode)))."
                )
            case .unsupported:
                failure = String(localized: "This isn’t available on this device.")
            case .failed:
                failure = String(
                    localized: "Couldn’t read this data (error \(Int(result.errorCode)))."
                )
            }
        } catch {
            failure = InspectorErrorText.describe(error)
        }
        rebuildVisible()
    }

    // MARK: Sharing

    private lazy var shareButton = InspectorMenuButton(
        symbolName: "ellipsis",
        accessibilityLabel: String(localized: "More Options")
    ) { [weak self] in
        InspectorMenu(sections: [[
            InspectorMenuItem(
                title: String(localized: "Share"),
                symbolName: "square.and.arrow.up",
                isDisabled: self?.visible.isEmpty ?? true
            ) { self?.share() },
        ]])
    }

    // The text is only built once someone asks for it.
    private func share() {
        let item = DetailShareItem(
            text: ProcessDetailExport.text(title: screenTitle, process: processName, records: visible),
            subject: "\(screenTitle) — \(processName)"
        )
        let share = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = shareButton
        share.popoverPresentationController?.sourceRect = shareButton.bounds
        present(share, animated: true)
    }
}

private final class DetailShareItem: NSObject, UIActivityItemSource {
    private let text: String
    private let subject: String

    init(text: String, subject: String) {
        self.text = text
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        text
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject
    }
}
