import SwiftUI
import UIKit

struct ProcessDetailListView: View {
    let kind: ProcessDetailKind
    let identity: ProcessIdentity

    @EnvironmentObject private var model: ProcessListModel
    @State private var detail: ProcessDetailSnapshot?
    // Filtering and sorting run once per load, query, or order change — never
    // in a view body, which re-runs far more often than the data changes.
    @State private var visible = ProcessDetailRecords()
    @State private var failure: String?
    @State private var searchText = ""
    @State private var inspected: DetailRowInspection?
    @AppStorage private var sortOrder: ProcessDetailSortOrder
    @AppStorage private var sortAscending: Bool

    private let columns: [DetailColumn]

    init(kind: ProcessDetailKind, identity: ProcessIdentity) {
        self.kind = kind
        self.identity = identity
        columns = ProcessDetailTable.columns(for: kind)
        // One stored order per kind: "sort by size" means nothing to threads.
        let fallback = ProcessDetailSort.default(for: kind)
        _sortOrder = AppStorage(
            wrappedValue: fallback.order,
            "processDetail.sortOrder.\(kind.rawValue)"
        )
        _sortAscending = AppStorage(
            wrappedValue: fallback.ascending,
            "processDetail.sortAscending.\(kind.rawValue)"
        )
    }

    private var sort: ProcessDetailSort {
        ProcessDetailSort(order: sortOrder, ascending: sortAscending)
    }

    private var sortBinding: Binding<ProcessDetailSort> {
        Binding(
            get: { sort },
            set: { sortOrder = $0.order; sortAscending = $0.ascending }
        )
    }

    private var title: String {
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

    private var processName: String {
        model.row(for: identity)?.displayName ?? "pid \(identity.pid)"
    }

    var body: some View {
        List {
            if let detail {
                content(for: detail)
            }
        }
        // Plain rows keep the header pinned to the top of the list while it
        // scrolls, which is what makes this read as a table.
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { optionsMenu }
        }
        .overlay { overlayContent }
        .sheet(item: $inspected) { RowInspectionSheet(inspection: $0) }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: searchText) { _ in rebuildVisible() }
        .onChange(of: sort) { _ in rebuildVisible() }
    }

    @ViewBuilder private var optionsMenu: some View {
        Menu {
            if detail != nil {
                ShareLink(
                    item: ProcessDetailExport.text(
                        title: title,
                        process: processName,
                        records: visible
                    ),
                    subject: Text("\(title) — \(processName)")
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(visible.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(detail == nil)
    }

    @ViewBuilder private func content(for detail: ProcessDetailSnapshot) -> some View {
        Section {
            switch kind {
            case .summary:
                EmptyView()
            case .threads:
                ForEach(visible.threads, id: \.id) { thread in
                    row(
                        cells: ProcessDetailTable.cells(thread: thread),
                        inspection: DetailRowInspection(thread: thread)
                    )
                }
            case .files:
                ForEach(visible.files, id: \.descriptor) { file in
                    row(
                        cells: ProcessDetailTable.cells(file: file),
                        inspection: DetailRowInspection(file: file)
                    )
                }
            case .ports:
                ForEach(visible.ports, id: \.name) { port in
                    row(
                        cells: ProcessDetailTable.cells(port: port),
                        inspection: DetailRowInspection(port: port)
                    )
                }
            case .modules:
                ForEach(visible.modules, id: \.address) { module in
                    row(
                        cells: ProcessDetailTable.cells(module: module),
                        inspection: DetailRowInspection(module: module)
                    )
                }
            }
        } header: {
            if !columns.isEmpty {
                DetailTableHeader(columns: columns, sort: sortBinding)
            }
        } footer: {
            footer(for: detail)
        }
    }

    // A row shows only what fits on one line; tapping it opens everything the
    // record carries, including the full path.
    private func row(cells: [String], inspection: DetailRowInspection) -> some View {
        Button {
            inspected = inspection
        } label: {
            DetailTableRow(columns: columns, cells: cells)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func footer(for detail: ProcessDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let count = countSummary(for: detail) {
                Text(count)
            }
            if detail.status == .partial {
                Text("Some of this couldn’t be read (error \(detail.errorCode)).")
            }
        }
        .padding(.top, 4)
    }

    private func countSummary(for detail: ProcessDetailSnapshot) -> String? {
        let total = ProcessDetailRecords.total(in: detail, kind: kind)
        guard total > 0 else { return nil }
        return visible.count == total
            ? String(localized: "\(total) in total")
            : String(localized: "\(visible.count) of \(total) shown")
    }

    @ViewBuilder private var overlayContent: some View {
        if let failure {
            InspectorUnavailableView {
                Label("Couldn’t Load This", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if let detail {
            if ProcessDetailRecords.total(in: detail, kind: kind) == 0 {
                InspectorUnavailableView {
                    Label("Nothing Here Yet", systemImage: "tray")
                }
            } else if visible.isEmpty {
                InspectorUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing matches “\(searchText)”.")
                }
            }
        } else {
            ProgressView()
        }
    }

    private func rebuildVisible() {
        guard let detail else {
            visible = ProcessDetailRecords()
            return
        }
        visible = ProcessDetailRecords.visible(
            in: detail,
            kind: kind,
            sort: sort,
            query: searchText
        )
    }

    private func load() async {
        failure = nil
        do {
            let result = try await model.details(kind, for: identity)
            switch result.status {
            case .available, .partial:
                detail = result
                rebuildVisible()
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
    }
}

private struct RowInspectionSheet: View {
    let inspection: DetailRowInspection

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(inspection.fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(field.value)
                            .font(field.isMonospaced ? .callout.monospaced() : .callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(inspection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = inspection.text
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
