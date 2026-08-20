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
                ToolbarItem(placement: .navigationBarLeading) { systemMenu }
                ToolbarItem(placement: .navigationBarTrailing) { actionsMenu }
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
        // sample forever in the background — monopolizing the daemon's single
        // session and locking out the CLI.
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

    private var systemMenu: some View {
        Menu {
            Section("This Device") {
                copyableStat("CPU", cpuSummary, icon: "cpu")
                copyableStat("Memory", memorySummary, icon: "memorychip")
                copyableStat("Processes", processesSummary, icon: "square.stack.3d.up")
                copyableStat(
                    "Up and Running",
                    InspectorFormat.duration(model.uptimeNanoseconds),
                    icon: "clock"
                )
            }
        } label: {
            Image(systemName: "gauge.with.needle")
        }
        .disabled(model.rows.isEmpty)
    }

    // Title + value render as a two-line menu item; tapping copies the stat.
    private func copyableStat(
        _ title: LocalizedStringResource,
        _ value: String,
        icon: String
    ) -> some View {
        Button {
            UIPasteboard.general.string = "\(String(localized: title)): \(value)"
        } label: {
            Text(title)
            Text(value)
            Image(systemName: icon)
        }
    }

    private var actionsMenu: some View {
        Menu {
            Toggle(isOn: $model.isPaused) {
                Label("Pause Live Updates", systemImage: "pause.circle")
            }
            Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: $model.sortOrder) {
                ForEach(ProcessSortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            Picker(
                "Show",
                systemImage: "line.3.horizontal.decrease.circle",
                selection: $model.scopeFilter
            ) {
                ForEach(ProcessScopeFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Image(
                systemName: model.isPaused || model.scopeFilter != .all
                    ? "ellipsis.circle.fill"
                    : "ellipsis.circle"
            )
        }
    }

    private var cpuSummary: String {
        let usage = InspectorFormat.percent(model.totalCPUFraction)
        let cores = Int(model.system.activeProcessorCount)
        guard cores > 0 else { return usage }
        return "\(usage) · \(String(localized: "\(cores) cores"))"
    }

    private var memorySummary: String {
        let total = model.system.physicalMemory
        let free = model.system.freeMemory
        let used = total > free ? total - free : 0
        return String(
            localized: "\(InspectorFormat.bytes(used)) of \(InspectorFormat.bytes(total)) in use"
        )
    }

    private var processesSummary: String {
        let processes = model.rows.count
        let threads = Int(model.system.totalThreadCount)
        return String(localized: "\(processes) processes · \(threads) threads")
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

private struct ProcessRowView: View {
    let row: ProcessRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(InspectorFormat.percent(row.cpuFraction))
                    .monospacedDigit()
                    .foregroundStyle(row.cpuFraction > 0.005 ? .primary : .secondary)
                Text(InspectorFormat.bytes(row.record.physicalFootprint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var subtitle: String {
        var parts = [
            "PID \(String(row.record.pid))",
            InspectorFormat.user(row.record.userID),
        ]
        if row.isApp { parts.append(String(localized: "App")) }
        parts.append(String(localized: "\(Int(row.record.threadCount)) threads"))
        return parts.joined(separator: " · ")
    }
}

#Preview {
    ContentView()
}
