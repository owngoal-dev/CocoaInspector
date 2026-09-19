import UIKit

// A Mac-style table for the detail screens: a sticky row of tappable column
// headers over one line per record. The columns are laid out by hand — header
// cells and body cells share these specs and one layout routine, which is what
// keeps them aligned.
struct DetailColumn {
    // Every column is a sort key, so the key doubles as the column's identity.
    let order: ProcessDetailSortOrder
    let title: String
    // nil takes whatever width the fixed columns leave over. Exactly one
    // column per table is flexible; the rest are sized for their content.
    let width: CGFloat?
    var alignment: Alignment = .leading
    var style: Style = .plain
    var lineBreakMode: NSLineBreakMode = .byTruncatingTail

    enum Alignment {
        case leading
        case trailing
    }

    enum Style {
        case plain
        case monospaced
        case number

        var font: UIFont {
            switch self {
            case .plain: .preferredFont(forTextStyle: .footnote)
            case .monospaced: .inspector(.footnote, design: .monospaced)
            case .number: .inspector(.footnote, design: .monospacedDigit)
            }
        }
    }
}

enum ProcessDetailTable {
    static func columns(for kind: ProcessDetailKind) -> [DetailColumn] {
        switch kind {
        case .summary:
            []
        case .threads:
            [
                DetailColumn(order: .name, title: String(localized: "Thread"), width: nil),
                DetailColumn(order: .state, title: String(localized: "State"), width: 74),
                DetailColumn(
                    order: .priority,
                    title: String(localized: "Pri"),
                    // Fits localized titles such as “优先级” together with
                    // the sort chevron without breaking row/header alignment.
                    width: 60,
                    alignment: .trailing,
                    style: .number
                ),
                DetailColumn(
                    order: .cpu,
                    title: String(localized: "CPU"),
                    width: 48,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        case .files:
            [
                // Paths are read from the right: the file name matters more
                // than the directory it sits in.
                DetailColumn(order: .name, title: String(localized: "File"), width: nil, lineBreakMode: .byTruncatingHead),
                DetailColumn(order: .fileKind, title: String(localized: "Kind"), width: 56),
                DetailColumn(
                    order: .descriptor,
                    title: String(localized: "FD"),
                    width: 34,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        case .ports:
            [
                DetailColumn(order: .port, title: String(localized: "Port"), width: 66, style: .monospaced),
                DetailColumn(order: .rights, title: String(localized: "Rights"), width: nil),
                DetailColumn(
                    order: .references,
                    title: String(localized: "Refs"),
                    width: 38,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        case .modules:
            [
                DetailColumn(order: .name, title: String(localized: "Module"), width: nil),
                DetailColumn(order: .address, title: String(localized: "Address"), width: 92, style: .monospaced),
                DetailColumn(
                    order: .size,
                    title: String(localized: "Size"),
                    width: 58,
                    alignment: .trailing,
                    style: .number
                ),
                DetailColumn(
                    order: .references,
                    title: String(localized: "Ref"),
                    width: 28,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        }
    }

    // One string per column, in column order.
    static func cells(thread: ThreadRecord) -> [String] {
        [
            thread.name.isEmpty ? InspectorFormat.hex(thread.id) : thread.name,
            InspectorFormat.threadState(thread.runState),
            "\(thread.currentPriority)",
            String(format: "%.1f%%", Double(thread.cpuUsage) / 10),
        ]
    }

    static func cells(file: FileDescriptorRecord) -> [String] {
        let name = ProcessDetailRecords.fileName(file)
        return [
            name.isEmpty ? file.detail : name,
            InspectorFormat.fileKind(file.kind),
            "\(file.descriptor)",
        ]
    }

    static func cells(port: MachPortRecord) -> [String] {
        [
            InspectorFormat.hex(UInt64(port.name)),
            InspectorFormat.portRights(port.rights),
            "\(port.userReferences)",
        ]
    }

    static func cells(module: ModuleRecord) -> [String] {
        [
            ProcessDetailRecords.moduleName(module),
            InspectorFormat.hex(module.address),
            module.size > 0 ? InspectorFormat.memoryBytes(module.size) : "—",
            "\(module.referenceCount)",
        ]
    }
}

// The full record behind a row, for the sheet that opens when it is tapped —
// a one-line row has to drop paths and secondary fields somewhere.
struct DetailRowInspection: Identifiable {
    let id: String
    let title: String
    let fields: [DetailField]

    var text: String {
        ([title] + fields.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }
}

// The label is already localized: it is copied into the shared text as well as
// shown, so it has to be a plain string by the time it gets here.
struct DetailField: Identifiable {
    let label: String
    let value: String
    var isMonospaced = false

    var id: String { label }
}

extension DetailRowInspection {
    init(thread: ThreadRecord) {
        id = "thread-\(thread.id)"
        title = thread.name.isEmpty
            ? String(localized: "Thread \(InspectorFormat.hex(thread.id))")
            : thread.name
        fields = [
            DetailField(label: String(localized: "Thread ID"), value: InspectorFormat.hex(thread.id), isMonospaced: true),
            DetailField(label: String(localized: "State"), value: InspectorFormat.threadState(thread.runState)),
            DetailField(label: String(localized: "CPU Usage"),
                value: String(format: "%.1f%%", Double(thread.cpuUsage) / 10)
            ),
            DetailField(label: String(localized: "Priority"), value: "\(thread.currentPriority)"),
            DetailField(label: String(localized: "Base Priority"), value: "\(thread.basePriority)"),
            DetailField(label: String(localized: "Maximum Priority"), value: "\(thread.maximumPriority)"),
            DetailField(label: String(localized: "Scheduling Policy"), value: "\(thread.policy)"),
            DetailField(label: String(localized: "Sleeping For"), value: "\(thread.sleepTime)"),
        ]
    }

    init(file: FileDescriptorRecord) {
        id = "file-\(file.descriptor)"
        title = String(localized: "File Descriptor \(file.descriptor)")
        var fields = [
            DetailField(label: String(localized: "Kind"), value: InspectorFormat.fileKind(file.kind)),
        ]
        if !file.path.isEmpty {
            fields.append(DetailField(label: String(localized: "Path"), value: file.path, isMonospaced: true))
        }
        if !file.localAddress.isEmpty {
            fields.append(
                DetailField(label: String(localized: "Local Address"), value: file.localAddress, isMonospaced: true)
            )
        }
        if !file.remoteAddress.isEmpty {
            fields.append(
                DetailField(label: String(localized: "Remote Address"), value: file.remoteAddress, isMonospaced: true)
            )
        }
        if !file.detail.isEmpty {
            fields.append(DetailField(label: String(localized: "Detail"), value: file.detail))
        }
        fields.append(
            DetailField(label: String(localized: "Open Flags"),
                value: InspectorFormat.hex(UInt64(file.openFlags)),
                isMonospaced: true
            )
        )
        fields.append(
            DetailField(label: String(localized: "Status"),
                value: InspectorFormat.hex(UInt64(file.status)),
                isMonospaced: true
            )
        )
        if file.object != 0 {
            fields.append(
                DetailField(label: String(localized: "Object"),
                    value: InspectorFormat.hex(file.object),
                    isMonospaced: true
                )
            )
        }
        if file.peer != 0 {
            fields.append(
                DetailField(label: String(localized: "Peer"), value: InspectorFormat.hex(file.peer), isMonospaced: true)
            )
        }
        self.fields = fields
    }

    init(port: MachPortRecord) {
        id = "port-\(port.name)"
        title = String(localized: "Port \(InspectorFormat.hex(UInt64(port.name)))")
        var fields = [
            DetailField(label: String(localized: "Rights"), value: InspectorFormat.portRights(port.rights)),
            DetailField(label: String(localized: "References"), value: "\(port.userReferences)"),
            DetailField(label: String(localized: "Object"),
                value: InspectorFormat.hex(UInt64(port.object)),
                isMonospaced: true
            ),
        ]
        if port.objectType != 0 {
            fields.append(DetailField(label: String(localized: "Kernel Object Type"), value: "\(port.objectType)"))
        }
        if !port.setMembers.isEmpty {
            fields.append(
                DetailField(label: String(localized: "Port Set Members"),
                    value: port.setMembers
                        .map { InspectorFormat.hex(UInt64($0)) }
                        .joined(separator: ", "),
                    isMonospaced: true
                )
            )
        }
        self.fields = fields
    }

    init(module: ModuleRecord) {
        id = "module-\(module.address)-\(module.path)"
        title = ProcessDetailRecords.moduleName(module)
        var fields = [
            DetailField(label: String(localized: "Address"),
                value: InspectorFormat.hex(module.address),
                isMonospaced: true
            ),
        ]
        if module.size > 0 {
            fields.append(
                DetailField(label: String(localized: "Size"),
                    value: "\(InspectorFormat.memoryBytes(module.size)) (\(module.size) bytes)"
                )
            )
        }
        fields.append(DetailField(label: String(localized: "References"), value: "\(module.referenceCount)"))
        if !module.identifier.isEmpty {
            fields.append(DetailField(label: String(localized: "Identifier"), value: module.identifier))
        }
        if !module.path.isEmpty {
            fields.append(DetailField(label: String(localized: "Path"), value: module.path, isMonospaced: true))
        }
        self.fields = fields
    }
}

enum DetailTableMetrics {
    static let columnSpacing: CGFloat = 8
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 5

    // One frame per column, in column order. Mirrored for right-to-left
    // languages, where the first column belongs on the right.
    static func frames(
        for columns: [DetailColumn],
        in bounds: CGRect,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> [CGRect] {
        let available = bounds.width - horizontalInset * 2
            - columnSpacing * CGFloat(max(columns.count - 1, 0))
        let fixed = columns.reduce(0) { $0 + ($1.width ?? 0) }
        let flexible = max(available - fixed, 0)
        var x = bounds.minX + horizontalInset
        return columns.map { column in
            let width = column.width ?? flexible
            defer { x += width + columnSpacing }
            let origin = layoutDirection == .rightToLeft ? bounds.maxX - x - width + bounds.minX : x
            return CGRect(x: origin, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    static func textAlignment(
        for column: DetailColumn,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> NSTextAlignment {
        switch (column.alignment, layoutDirection) {
        case (.leading, .rightToLeft), (.trailing, .leftToRight): .right
        default: .left
        }
    }
}

final class DetailTableHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "detailHeader"

    var selectOrder: (ProcessDetailSortOrder) -> Void = { _ in }

    private var columns: [DetailColumn] = []
    private var buttons: [UIButton] = []

    func configure(columns: [DetailColumn], sort: ProcessDetailSort) {
        if columns.map(\.order) != self.columns.map(\.order) {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = columns.indices.map { index in
                let button = UIButton(type: .system)
                button.tag = index
                button.titleLabel?.font = .inspector(.caption1, weight: .semibold)
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.titleLabel?.lineBreakMode = .byTruncatingTail
                button.addTarget(self, action: #selector(columnTapped(_:)), for: .touchUpInside)
                contentView.addSubview(button)
                return button
            }
        }
        self.columns = columns
        // Only the sorted column carries an arrow, the way a Finder column
        // header does.
        let arrowConfiguration = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        for (button, column) in zip(buttons, columns) {
            let isSorted = sort.order == column.order
            button.setTitle(column.title, for: .normal)
            button.setImage(
                isSorted
                    ? UIImage(
                        systemName: sort.ascending ? "chevron.up" : "chevron.down",
                        withConfiguration: arrowConfiguration
                    )
                    : nil,
                for: .normal
            )
            button.tintColor = isSorted ? tintColor : .secondaryLabel
            // The arrow trails the title.
            button.semanticContentAttribute = effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .forceLeftToRight
                : .forceRightToLeft
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let direction = effectiveUserInterfaceLayoutDirection
        let frames = DetailTableMetrics.frames(
            for: columns,
            in: contentView.bounds,
            layoutDirection: direction
        )
        for (index, button) in buttons.enumerated() where index < frames.count {
            button.frame = frames[index]
            let alignment = DetailTableMetrics.textAlignment(
                for: columns[index],
                layoutDirection: direction
            )
            button.contentHorizontalAlignment = alignment == .right ? .right : .left
        }
    }

    @objc private func columnTapped(_ sender: UIButton) {
        guard columns.indices.contains(sender.tag) else { return }
        selectOrder(columns[sender.tag].order)
    }
}

final class DetailTableCell: UITableViewCell {
    static let reuseIdentifier = "detailRow"

    private var columns: [DetailColumn] = []
    private var labels: [UILabel] = []

    func configure(columns: [DetailColumn], cells: [String]) {
        if columns.map(\.order) != self.columns.map(\.order) {
            labels.forEach { $0.removeFromSuperview() }
            labels = columns.enumerated().map { index, column in
                let label = UILabel()
                label.font = column.style.font
                label.adjustsFontForContentSizeCategory = true
                label.textColor = index == 0 ? .label : .secondaryLabel
                label.lineBreakMode = column.lineBreakMode
                contentView.addSubview(label)
                return label
            }
            self.columns = columns
            setNeedsLayout()
        }
        for (index, label) in labels.enumerated() {
            label.text = index < cells.count ? cells[index] : ""
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let direction = effectiveUserInterfaceLayoutDirection
        let frames = DetailTableMetrics.frames(
            for: columns,
            in: contentView.bounds,
            layoutDirection: direction
        )
        for (index, label) in labels.enumerated() where index < frames.count {
            label.frame = frames[index]
            label.textAlignment = DetailTableMetrics.textAlignment(
                for: columns[index],
                layoutDirection: direction
            )
        }
    }
}
