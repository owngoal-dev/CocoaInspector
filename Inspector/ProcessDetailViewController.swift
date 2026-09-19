import Combine
import UIKit

final class ProcessDetailViewController: UITableViewController {
    private struct Section {
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    private enum Row {
        case value(label: String, value: String)
        case link(title: String, kind: ProcessDetailKind)
        case text(String)

        // What decides whether a live update can redraw cells in place: the
        // values move with every sample, the rows around them almost never do.
        var shape: String {
            switch self {
            case .value(let label, _): "value:\(label)"
            case .link(let title, _): "link:\(title)"
            case .text: "text"
            }
        }

        var copyableText: String? {
            switch self {
            case .value(_, let value): value
            case .link: nil
            case .text(let text): text
            }
        }
    }

    private let row: ProcessRow
    private let model: ProcessListModel
    private var observation: AnyCancellable?
    private var sections: [Section] = []
    private var summary: ProcessDetailSnapshot?
    private var summaryFailure: String?
    private var isSendingSignal = false
    private var isExporting = false {
        didSet { updateOptionsItem() }
    }

    private var identity: ProcessIdentity { row.record.identity }
    private var liveRow: ProcessRow? { model.row(for: identity) }
    // Summary carries fields the periodic sample doesn't collect (paths, fd/port
    // counts); the live sample keeps the dynamic numbers moving between refreshes.
    private var record: ProcessRecord { summary?.process ?? row.record }
    private var stats: ProcessRecord { liveRow?.record ?? record }
    // The row handed in is a snapshot, so this screen survives the process
    // exiting and can say so instead of vanishing.
    private var hasExited: Bool {
        model.phase == .active && !model.rows.isEmpty && liveRow == nil
    }

    init(row: ProcessRow, model: ProcessListModel) {
        self.row = row
        self.model = model
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = row.displayName
        navigationItem.largeTitleDisplayMode = .never
        updateOptionsItem()

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        refreshControl = refresh

        observation = model.changes.sink { [weak self] in self?.render() }
        render()
        Task { await loadSummary() }
    }

    // MARK: Rendering

    private func render() {
        let next = makeSections()
        let isSameShape = next.count == sections.count && zip(next, sections).allSatisfy { new, old in
            new.title == old.title && new.footer == old.footer
                && new.rows.map(\.shape) == old.rows.map(\.shape)
        }
        sections = next
        guard isViewLoaded else { return }
        if isSameShape {
            for cell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell) else { continue }
                configure(cell, with: sections[indexPath.section].rows[indexPath.row])
            }
        } else {
            tableView.reloadData()
        }
    }

    // The drill-downs sit right under the overview: they are what this screen
    // is for, and scrolling past every stat to reach them is not.
    private func makeSections() -> [Section] {
        var result = [overviewSection, detailLinksSection, resourceSection]
        if !record.executablePath.isEmpty {
            result.append(Section(title: String(localized: "Executable"), rows: [.text(record.executablePath)]))
        }
        if !record.arguments.isEmpty {
            result.append(
                Section(
                    title: String(localized: "Command Line"),
                    rows: [.text(record.arguments.joined(separator: " "))]
                )
            )
        }
        if let bundle = summary?.bundle {
            result.append(bundleSection(bundle))
        }
        return result
    }

    private var overviewSection: Section {
        var rows: [Row] = [
            .value(label: String(localized: "PID"), value: String(record.pid)),
            .value(label: String(localized: "Started By (PPID)"), value: String(record.parentPID)),
            .value(label: String(localized: "Running As"), value: InspectorFormat.user(record.userID)),
            .value(
                label: String(localized: "Threads"),
                value: String(
                    localized: "\(Int(stats.threadCount)) (\(Int(stats.runningThreadCount)) running)"
                )
            ),
            .value(
                label: String(localized: "Priority"),
                value: String(
                    localized: "\(Int(record.priority)) (base \(Int(record.basePriority)))"
                )
            ),
            .value(label: String(localized: "Nice Value"), value: String(record.nice)),
            .value(label: String(localized: "Sandbox"), value: InspectorFormat.sandbox(record.sandboxStatus)),
        ]
        if record.availability.contains(.fileDescriptors) {
            rows.append(
                .value(
                    label: String(localized: "Open Files"),
                    value: String(
                        localized: "\(Int(record.fileDescriptorCount)) (\(Int(record.socketCount)) sockets)"
                    )
                )
            )
        }
        if record.availability.contains(.ports) {
            rows.append(.value(label: String(localized: "Mach Ports"), value: String(record.portCount)))
        }
        var footer: String?
        if hasExited {
            footer = String(localized: "This process is no longer running.")
        } else if let summaryFailure {
            footer = String(localized: "Couldn’t refresh the details: \(summaryFailure)")
        }
        return Section(title: String(localized: "Overview"), footer: footer, rows: rows)
    }

    private var detailLinksSection: Section {
        Section(
            title: String(localized: "More Details"),
            rows: [
                .link(title: String(localized: "Threads"), kind: .threads),
                .link(title: String(localized: "Open Files"), kind: .files),
                .link(title: String(localized: "Mach Ports"), kind: .ports),
                .link(title: String(localized: "Loaded Modules"), kind: .modules),
            ]
        )
    }

    private var resourceSection: Section {
        var rows: [Row] = [
            .value(
                label: String(localized: "CPU"),
                value: InspectorFormat.percent(liveRow?.cpuFraction ?? 0)
            ),
            .value(
                label: String(localized: "Total CPU Time"),
                value: InspectorFormat.cpuTime(
                    stats.totalCPUTime,
                    numerator: model.machTimebaseNumerator,
                    denominator: model.machTimebaseDenominator
                )
            ),
            .value(
                label: String(localized: "Memory Footprint"),
                value: InspectorFormat.memoryBytes(stats.physicalFootprint)
            ),
            .value(
                label: String(localized: "Resident Memory"),
                value: InspectorFormat.memoryBytes(stats.residentSize)
            ),
            .value(
                label: String(localized: "Virtual Memory"),
                value: InspectorFormat.memoryBytes(stats.virtualSize)
            ),
            .value(
                label: String(localized: "Read from Disk"),
                value: InspectorFormat.dataBytes(stats.diskBytesRead)
            ),
            .value(
                label: String(localized: "Written to Disk"),
                value: InspectorFormat.dataBytes(stats.diskBytesWritten)
            ),
        ]
        if record.availability.contains(.network) {
            rows.append(
                .value(
                    label: String(localized: "Downloaded"),
                    value: InspectorFormat.dataBytes(record.networkBytesReceived)
                )
            )
            rows.append(
                .value(
                    label: String(localized: "Uploaded"),
                    value: InspectorFormat.dataBytes(record.networkBytesSent)
                )
            )
        }
        return Section(title: String(localized: "Resource Use"), rows: rows)
    }

    private func bundleSection(_ bundle: BundleMetadata) -> Section {
        var rows: [Row] = [.value(label: String(localized: "Bundle ID"), value: bundle.identifier)]
        if !bundle.displayName.isEmpty {
            rows.append(.value(label: String(localized: "Display Name"), value: bundle.displayName))
        }
        if !bundle.version.isEmpty {
            rows.append(.value(label: String(localized: "Version"), value: bundle.version))
        }
        if !bundle.minimumOSVersion.isEmpty {
            rows.append(.value(label: String(localized: "Requires iOS"), value: bundle.minimumOSVersion))
        }
        if !bundle.SDKName.isEmpty {
            rows.append(.value(label: String(localized: "SDK"), value: bundle.SDKName))
        }
        return Section(title: String(localized: "App Bundle"), rows: rows)
    }

    // MARK: Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let identifier: String
        let style: UITableViewCell.CellStyle
        switch row {
        case .value: (identifier, style) = ("value", .value1)
        case .link: (identifier, style) = ("link", .default)
        case .text: (identifier, style) = ("text", .default)
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: style, reuseIdentifier: identifier)
        configure(cell, with: row)
        return cell
    }

    private func configure(_ cell: UITableViewCell, with row: Row) {
        switch row {
        case .value(let label, let value):
            cell.selectionStyle = .none
            cell.textLabel?.text = label
            cell.detailTextLabel?.text = value
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
        case .link(let title, _):
            cell.textLabel?.text = title
            cell.accessoryType = .disclosureIndicator
        case .text(let text):
            cell.selectionStyle = .none
            cell.textLabel?.text = text
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.font = .inspector(.footnote, design: .monospaced)
            cell.textLabel?.adjustsFontForContentSizeCategory = true
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard case .link(_, let kind) = sections[indexPath.section].rows[indexPath.row] else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        let list = ProcessDetailListViewController(
            kind: kind,
            identity: identity,
            processName: row.displayName,
            model: model
        )
        navigationController?.pushViewController(list, animated: true)
    }

    // Touch and hold copies a value — paths and bundle IDs are what people
    // come here to take away.
    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let text = sections[indexPath.section].rows[indexPath.row].copyableText else {
            return nil
        }
        return .copy(text)
    }

    // MARK: Loading

    @objc private func refreshPulled() {
        Task {
            await loadSummary()
            refreshControl?.endRefreshing()
        }
    }

    private func loadSummary() async {
        summaryFailure = nil
        do {
            let result = try await model.details(.summary, for: identity)
            if result.status == .available || result.status == .partial {
                summary = result
            } else {
                summaryFailure = String(localized: "error \(Int(result.errorCode))")
            }
        } catch {
            summaryFailure = InspectorErrorText.describe(error)
        }
        render()
    }

    // MARK: Options

    private lazy var optionsButton = InspectorMenuButton(
        symbolName: "ellipsis"
    ) { [weak self] in
        InspectorMenu(sections: self?.optionSections() ?? [])
    }

    // While an export runs the button gives way to a spinner, so a second
    // export can't be started on top of the first.
    private func updateOptionsItem() {
        if isExporting {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: optionsButton)
        }
    }

    private func optionSections() -> [[InspectorMenuItem]] {
        var result = [[
            InspectorMenuItem(
                title: String(localized: "Export as Property List"),
                symbolName: "square.and.arrow.up"
            ) { [weak self] in
                Task { await self?.exportDetails() }
            },
        ]]
        if record.pid > 1 && !hasExited {
            result.append([
                InspectorMenuItem(
                    title: String(localized: "Ask It to Quit"),
                    symbolName: "stop.circle",
                    isDestructive: true,
                    isDisabled: isSendingSignal
                ) { [weak self] in self?.confirm(.terminate) },
                InspectorMenuItem(
                    title: String(localized: "Force Quit"),
                    symbolName: "xmark.octagon",
                    isDestructive: true,
                    isDisabled: isSendingSignal
                ) { [weak self] in self?.confirm(.forceKill) },
            ])
        }
        return result
    }

    // Gathers every collector, not just what's on screen: the file is meant to
    // be read back later, when the process may well be gone.
    private func exportDetails() async {
        isExporting = true
        defer { isExporting = false }
        let document = await ProcessExport.document(for: identity, using: model)
        do {
            let url = try ProcessExport.write(
                document,
                named: "\(row.displayName)-\(record.pid)"
            )
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            // The plist lives in a temporary directory only until the share
            // sheet is done with it; nothing is left lying around afterwards.
            share.completionWithItemsHandler = { _, _, _, _ in ProcessExport.removeExports() }
            share.popoverPresentationController?.sourceView = optionsButton
            share.popoverPresentationController?.sourceRect = optionsButton.bounds
            present(share, animated: true)
        } catch {
            presentFailure(
                title: String(localized: "Couldn’t Export the Details"),
                message: error.localizedDescription
            )
        }
    }

    // MARK: Signals

    private func confirm(_ signal: InspectorSignal) {
        let sheet = UIAlertController(
            title: String(localized: "Stop \(row.displayName)?"),
            message: signal == .forceKill
                ? String(localized: "This ends the process immediately. Unsaved work can be lost.")
                : String(localized: "This asks the process to shut down on its own."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(
            title: signal == .forceKill
                ? String(localized: "Force Quit (SIGKILL)")
                : String(localized: "Ask It to Quit (SIGTERM)"),
            style: .destructive
        ) { [weak self] _ in
            Task { await self?.send(signal) }
        })
        sheet.addAction(UIAlertAction(title: String(systemLocalized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = optionsButton
        sheet.popoverPresentationController?.sourceRect = optionsButton.bounds
        present(sheet, animated: true)
    }

    private func send(_ signal: InspectorSignal) async {
        isSendingSignal = true
        defer { isSendingSignal = false }
        do {
            try await model.sendSignal(signal, to: identity)
            (splitViewController as? InspectorSplitViewController)?.closeDetail()
        } catch {
            presentFailure(
                title: String(localized: "Couldn’t Send the Signal"),
                message: InspectorErrorText.describe(error)
            )
        }
    }
}

extension UIContextMenuConfiguration {
    static func copy(_ text: String) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: [
                UIAction(
                    title: String(localized: "Copy"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = text
                },
            ])
        }
    }
}
