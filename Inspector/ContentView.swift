//
//  ContentView.swift
//  Inspector
//
//  Created by qaq on 3/8/2026.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ProcessListModel()
    @State private var signalTarget: ProcessRow?
    @State private var signalFailure: String?
    @State private var isShowingSignalFailure = false
    @State private var selection: ProcessIdentity?
    // Snapshot of the selected row, kept so the detail column can survive the
    // process exiting (the live lookup goes nil, the snapshot does not).
    @State private var openedRow: ProcessRow?
    // Start with both columns visible so an iPad launch doesn't open on an
    // empty detail pane with the process list hidden behind a toolbar button.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                processSection
                creditsSection
            }
            .navigationTitle("Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, prompt: "Search by name or PID")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    SystemStatsMenuButton(stats: systemStats)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProcessListActionsMenu(
                        model: model,
                        isPaused: model.isPaused,
                        sortOrder: model.sortOrder,
                        scopeFilter: model.scopeFilter
                    )
                    .equatable()
                }
            }
            .overlay { overlayContent }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            // The stack hosts the drill-downs (threads, files, ports, modules)
            // pushed from the detail screen.
            NavigationStack {
                detailColumn
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { newValue in
            guard let newValue else { return }
            if let row = model.row(for: newValue) {
                openedRow = row
            }
        }
        .environmentObject(model)
        // Guarded on the scene being active: a locked-screen launch (uiopen,
        // prewarming) lands here with scenePhase already .background, so the
        // .background case below never fires and an unconditional start would
        // keep an unnecessary client connection and sampling loop alive.
        .onAppear {
            if scenePhase == .active { model.start() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.start()
            case .background: model.stop()
            default: break
            }
        }
        .confirmationDialog(
            signalTarget.map { String(localized: "Stop \($0.displayName)?") }
                ?? String(localized: "Stop This Process?"),
            isPresented: Binding(
                get: { signalTarget != nil },
                set: { if !$0 { signalTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: signalTarget
        ) { target in
            Button("Ask It to Quit (SIGTERM)", role: .destructive) {
                send(.terminate, to: target)
            }
            Button("Force Quit (SIGKILL)", role: .destructive) {
                send(.forceKill, to: target)
            }
        } message: { _ in
            Text("“Ask It to Quit” lets the process shut down on its own. “Force Quit” ends it right away, so unsaved work can be lost.")
        }
        .alert("Couldn’t Send the Signal", isPresented: $isShowingSignalFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signalFailure ?? String(localized: "Something unexpected went wrong."))
        }
    }

    private var systemStats: SystemStatsSnapshot {
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
        return SystemStatsSnapshot(
            cpu: cpu,
            memory: memory,
            processes: processes,
            uptime: InspectorFormat.duration(model.uptimeNanoseconds),
            isDisabled: model.rows.isEmpty
        )
    }

    @ViewBuilder private var processSection: some View {
        if !model.rows.isEmpty {
            let visible = model.visibleRows
            Section {
                ForEach(visible) { row in
                    NavigationLink(value: row.id) {
                        ProcessRowView(row: row)
                    }
                    .swipeActions(edge: .trailing) {
                        if row.record.pid > 1 {
                            Button("Stop", role: .destructive) {
                                signalTarget = row
                            }
                        }
                    }
                }
            } header: {
                Text(processHeader(visibleCount: visible.count))
            }
        }
    }

    // A rowless section renders just its footer, so the credit line sits at
    // the very bottom of the list without a card behind it. Hidden while an
    // overlay (connecting/failed/empty) owns the screen.
    @ViewBuilder private var creditsSection: some View {
        if !model.rows.isEmpty {
            Section {
            } footer: {
                VStack(spacing: 2) {
                    Link(destination: URL(string: "https://owngoal.dev")!) {
                        Text("Made with ❤️ by OwnGoal Studio")
                            .font(.footnote)
                    }
                    .foregroundStyle(.primary)
                    Text(InspectorFormat.appVersion)
                        .font(.footnote.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                .opacity(0.5)
            }
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

    // Prefers the live row so the numbers keep moving; falls back to the
    // snapshot taken at selection time once the process has exited, so the
    // detail screen can show its "no longer running" state instead of
    // vanishing. `.id` resets the detail's own state when switching processes.
    @ViewBuilder private var detailColumn: some View {
        if let selection,
           let row = model.row(for: selection)
               ?? (openedRow?.id == selection ? openedRow : nil) {
            ProcessDetailView(row: row)
                .id(selection)
        } else {
            InspectorUnavailableView {
                Label("Select a Process", systemImage: "square.stack.3d.up")
            } description: {
                Text("Choose a process on the left to see what it’s up to.")
            }
        }
    }

    @ViewBuilder private var overlayContent: some View {
        switch model.phase {
        case .connecting where model.rows.isEmpty:
            ProgressView("Connecting to the inspector service…")
        case .failed(let message):
            InspectorUnavailableView {
                Label("Can’t Connect", systemImage: "bolt.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.start() }
            }
        case .active where !model.rows.isEmpty && model.visibleRows.isEmpty:
            if model.searchText.isEmpty {
                InspectorUnavailableView {
                    Label("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(
                        "No process matches the “\(model.scopeFilter.label)” filter right now."
                    )
                }
            } else {
                InspectorUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No processes match “\(model.searchText)”.")
                }
            }
        default:
            EmptyView()
        }
    }

    private func send(_ signal: InspectorSignal, to target: ProcessRow) {
        Task {
            do {
                try await model.sendSignal(signal, to: target.id)
            } catch {
                signalFailure = InspectorErrorText.describe(error)
                isShowingSignalFailure = true
            }
        }
    }
}

private struct SystemStatsSnapshot {
    let cpu: String
    let memory: String
    let processes: String
    let uptime: String
    let isDisabled: Bool
}

// UIKit keeps this UIMenu attached to the same toolbar button while SwiftUI
// refreshes the surrounding list. Deferred elements capture one snapshot at
// presentation time, so an open menu is never rebuilt by a live sample.
private struct SystemStatsMenuButton: UIViewRepresentable {
    let stats: SystemStatsSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator(stats: stats)
    }

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        let imageName: String
        if #available(iOS 17.0, *) {
            imageName = "gauge.with.needle"
        } else {
            imageName = "gauge"
        }
        configuration.image = UIImage(systemName: imageName)
        configuration.contentInsets = .zero

        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(
            title: String(localized: "This Device"),
            children: [UIDeferredMenuElement.uncached { [weak coordinator = context.coordinator] completion in
                DispatchQueue.main.async {
                    completion(coordinator?.menuElements() ?? [])
                }
            }]
        )
        button.accessibilityLabel = String(localized: "System Stats")
        button.isEnabled = !stats.isDisabled
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.stats = stats
        button.isEnabled = !stats.isDisabled
    }

    final class Coordinator {
        var stats: SystemStatsSnapshot

        init(stats: SystemStatsSnapshot) {
            self.stats = stats
        }

        func menuElements() -> [UIMenuElement] {
            [
                stat("CPU", value: stats.cpu, icon: "cpu"),
                stat("Memory", value: stats.memory, icon: "memorychip"),
                stat("Processes", value: stats.processes, icon: "square.stack.3d.up"),
                stat("Up and Running", value: stats.uptime, icon: "clock"),
            ]
        }

        private func stat(
            _ title: LocalizedStringResource,
            value: String,
            icon: String
        ) -> UIAction {
            let localizedTitle = String(localized: title)
            let action = UIAction(title: localizedTitle, image: UIImage(systemName: icon)) { _ in
                UIPasteboard.general.string = "\(localizedTitle): \(value)"
            }
            action.subtitle = value
            return action
        }
    }
}

// This menu only depends on interactive settings. Snapshot values are stored
// separately from the model reference so Equatable can ignore live samples but
// still redraw after a pause, sort, or scope change.
private struct ProcessListActionsMenu: View, Equatable {
    let model: ProcessListModel
    let isPaused: Bool
    let sortOrder: ProcessSortOrder
    let scopeFilter: ProcessScopeFilter

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.isPaused == rhs.isPaused
            && lhs.sortOrder == rhs.sortOrder
            && lhs.scopeFilter == rhs.scopeFilter
    }

    var body: some View {
        Menu {
            Toggle(isOn: binding(for: \ProcessListModel.isPaused)) {
                Label("Pause Live Updates", systemImage: "pause.circle")
            }
            Picker(
                "Sort By",
                systemImage: "arrow.up.arrow.down",
                selection: binding(for: \ProcessListModel.sortOrder)
            ) {
                ForEach(ProcessSortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            Picker(
                "Show",
                systemImage: "line.3.horizontal.decrease.circle",
                selection: binding(for: \ProcessListModel.scopeFilter)
            ) {
                ForEach(ProcessScopeFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Image(
                systemName: isPaused || scopeFilter != .all
                    ? "ellipsis.circle.fill"
                    : "ellipsis.circle"
            )
        }
    }

    private func binding<Value>(
        for keyPath: ReferenceWritableKeyPath<ProcessListModel, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}

private struct ProcessRowView: View {
    let row: ProcessRow

    var body: some View {
        HStack(spacing: 10) {
            if row.isApp {
                ProcessApplicationIcon(executablePath: row.record.executablePath)
                    .equatable()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(InspectorFormat.percent(row.cpuFraction))
                    .monospacedDigit()
                    .foregroundStyle(row.cpuFraction > 0.005 ? .primary : .secondary)
                Text(InspectorFormat.memoryBytes(row.record.physicalFootprint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var subtitle: String {
        var parts = [
            "PID \(String(row.record.pid))",
            InspectorFormat.userName(row.record.userID),
        ]
        parts.append(String(localized: "\(Int(row.record.threadCount)) threads"))
        return parts.joined(separator: " · ")
    }
}

#Preview {
    ContentView()
}
