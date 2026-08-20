import SwiftUI

// A Mac-style table for the detail screens: a sticky row of tappable column
// headers over one line per record. SwiftUI's own Table keeps only its first
// column in a compact size class, so the columns are laid out by hand — header
// cells and body cells share these specs, which is what keeps them aligned.
struct DetailColumn: Identifiable {
    // Every column is a sort key, so the key doubles as the column's identity.
    let order: ProcessDetailSortOrder
    let title: LocalizedStringKey
    // nil takes whatever width the fixed columns leave over. Exactly one
    // column per table is flexible; the rest are sized for their content.
    let width: CGFloat?
    var alignment: HorizontalAlignment = .leading
    var style: Style = .plain
    var truncation: Text.TruncationMode = .tail

    var id: ProcessDetailSortOrder { order }

    enum Style {
        case plain
        case monospaced
        case number
    }
}

enum ProcessDetailTable {
    static func columns(for kind: ProcessDetailKind) -> [DetailColumn] {
        switch kind {
        case .summary:
            []
        case .threads:
            [
                DetailColumn(order: .name, title: "Thread", width: nil),
                DetailColumn(order: .state, title: "State", width: 74),
                DetailColumn(
                    order: .priority,
                    title: "Pri",
                    // Fits localized titles such as “优先级” together with
                    // the sort chevron without breaking row/header alignment.
                    width: 60,
                    alignment: .trailing,
                    style: .number
                ),
                DetailColumn(
                    order: .cpu,
                    title: "CPU",
                    width: 48,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        case .files:
            [
                // Paths are read from the right: the file name matters more
                // than the directory it sits in.
                DetailColumn(order: .name, title: "File", width: nil, truncation: .head),
                DetailColumn(order: .fileKind, title: "Kind", width: 56),
                DetailColumn(
                    order: .descriptor,
                    title: "FD",
                    width: 34,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        case .ports:
            [
                DetailColumn(order: .port, title: "Port", width: 66, style: .monospaced),
                DetailColumn(order: .rights, title: "Rights", width: nil),
                DetailColumn(
                    order: .references,
                    title: "Refs",
                    width: 38,
                    alignment: .trailing,
                    style: .number
                ),
            ]
        case .modules:
            [
                DetailColumn(order: .name, title: "Module", width: nil),
                DetailColumn(order: .address, title: "Address", width: 92, style: .monospaced),
                DetailColumn(
                    order: .size,
                    title: "Size",
                    width: 58,
                    alignment: .trailing,
                    style: .number
                ),
                DetailColumn(
                    order: .references,
                    title: "Ref",
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
            module.size > 0 ? InspectorFormat.bytes(module.size) : "—",
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
                    value: "\(InspectorFormat.bytes(module.size)) (\(module.size) bytes)"
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

struct DetailTableHeader: View {
    let columns: [DetailColumn]
    @Binding var sort: ProcessDetailSort

    var body: some View {
        HStack(spacing: DetailTableMetrics.columnSpacing) {
            ForEach(columns) { column in
                Button {
                    sort.select(column.order)
                } label: {
                    HStack(spacing: 2) {
                        Text(column.title)
                            .lineLimit(1)
                        // Only the sorted column carries an arrow, the way a
                        // Finder column header does.
                        if sort.order == column.order {
                            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        alignment: Alignment(horizontal: column.alignment, vertical: .center)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(sort.order == column.order ? Color.accentColor : .secondary)
                .detailColumnWidth(column)
            }
        }
        .font(.caption.weight(.semibold))
        .textCase(nil)
        .listRowInsets(DetailTableMetrics.rowInsets)
    }
}

struct DetailTableRow: View {
    let columns: [DetailColumn]
    let cells: [String]

    var body: some View {
        HStack(spacing: DetailTableMetrics.columnSpacing) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                Text(index < cells.count ? cells[index] : "")
                    .font(font(for: column))
                    .foregroundStyle(index == 0 ? Color.primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(column.truncation)
                    .frame(
                        maxWidth: .infinity,
                        alignment: Alignment(horizontal: column.alignment, vertical: .center)
                    )
                    .detailColumnWidth(column)
            }
        }
        .listRowInsets(DetailTableMetrics.rowInsets)
    }

    private func font(for column: DetailColumn) -> Font {
        switch column.style {
        case .plain: .footnote
        case .monospaced: .footnote.monospaced()
        case .number: .footnote.monospacedDigit()
        }
    }
}

enum DetailTableMetrics {
    static let columnSpacing: CGFloat = 8
    static let rowInsets = EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
}

private extension View {
    // A fixed column pins its width; the flexible one keeps the maxWidth the
    // cell already asked for and takes the remainder.
    @ViewBuilder func detailColumnWidth(_ column: DetailColumn) -> some View {
        if let width = column.width {
            frame(width: width)
        } else {
            self
        }
    }
}
