import SwiftUI

struct ProcessRow: Identifiable, Equatable {
    let record: ProcessRecord
    let cpuFraction: Double

    var id: ProcessIdentity { record.identity }
    var displayName: String { record.name.isEmpty ? "pid \(record.pid)" : record.name }
    // App executables run from an .app bundle in one of two install locations:
    // user apps in a bundle container (/var/containers/Bundle/Application/<UUID>/,
    // or /var/mobile/Containers/Bundle/Application/ before iOS 9.3) and system
    // apps in an /Applications directory. That directory is only at the volume
    // root on stock and roothide installs; on rootless it sits under the
    // jailbreak prefix, so match it anywhere in the path. The ".app/"
    // requirement keeps jbroot daemons (installed under a .jbroot-* bundle
    // container) out.
    var isApp: Bool {
        record.executablePath.contains(".app/")
            && (record.executablePath.contains("/Bundle/Application/")
                || record.executablePath.contains("/Applications/"))
    }
}

enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case pid = "PID"
    case name = "Name"

    var id: Self { self }

    // rawValue is the @AppStorage key, so it stays fixed; the label is what
    // the menu shows and is translated.
    var label: String {
        switch self {
        case .cpu: String(localized: "CPU Usage")
        case .memory: String(localized: "Memory Used")
        case .pid: String(localized: "PID")
        case .name: String(localized: "Name")
        }
    }

    // Total order with pid as the final tiebreaker: Swift's sort is not
    // stable, so without it equal-keyed rows (idle processes, same-named
    // helpers) shuffle randomly on every one-second resort.
    func areInOrder(_ lhs: ProcessRow, _ rhs: ProcessRow) -> Bool {
        switch self {
        case .cpu:
            if lhs.cpuFraction != rhs.cpuFraction {
                return lhs.cpuFraction > rhs.cpuFraction
            }
            if lhs.record.physicalFootprint != rhs.record.physicalFootprint {
                return lhs.record.physicalFootprint > rhs.record.physicalFootprint
            }
            return lhs.record.pid < rhs.record.pid
        case .memory:
            if lhs.record.physicalFootprint != rhs.record.physicalFootprint {
                return lhs.record.physicalFootprint > rhs.record.physicalFootprint
            }
            return lhs.record.pid < rhs.record.pid
        case .pid:
            return lhs.record.pid < rhs.record.pid
        case .name:
            switch lhs.record.name.localizedCaseInsensitiveCompare(rhs.record.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.record.pid < rhs.record.pid
            }
        }
    }
}

enum ProcessScopeFilter: String, CaseIterable, Identifiable {
    case all
    case root
    case mobile
    case apps

    var id: Self { self }

    var label: String {
        switch self {
        case .all: String(localized: "Everything")
        case .root: String(localized: "System (root)")
        case .mobile: String(localized: "User (mobile)")
        case .apps: String(localized: "Apps")
        }
    }

    func matches(_ row: ProcessRow) -> Bool {
        switch self {
        case .all: true
        case .root: row.record.userID == 0
        case .mobile: row.record.userID == 501
        case .apps: row.isApp
        }
    }
}

// Everything derived from a sample is computed off the main actor (in the
// serial operation chain) so the main thread only assigns stored properties.
struct PreparedSample: Sendable {
    let rows: [ProcessRow]
    let rowsByIdentity: [ProcessIdentity: ProcessRow]
    let visibleRows: [ProcessRow]
    let totalCPUFraction: Double
    let system: SystemRecord
    let uptimeNanoseconds: UInt64
    let machTimebaseNumerator: UInt32
    let machTimebaseDenominator: UInt32

    init(
        update: ProcessSnapshotUpdate,
        scope: ProcessScopeFilter,
        order: ProcessSortOrder,
        query: String
    ) {
        let cpuByIdentity = Dictionary(
            update.intervals.map { ($0.process.identity, $0.cpuCoreFraction) },
            uniquingKeysWith: { first, _ in first }
        )
        rows = update.snapshot.processes.map {
            ProcessRow(record: $0, cpuFraction: cpuByIdentity[$0.identity] ?? 0)
        }
        rowsByIdentity = Dictionary(
            rows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        visibleRows = ProcessListModel.visibleRows(in: rows, scope: scope, order: order, query: query)
        totalCPUFraction = update.intervals.reduce(0) { $0 + $1.cpuCoreFraction }
        system = update.snapshot.system
        uptimeNanoseconds = update.snapshot.sampleUptimeNanoseconds
        machTimebaseNumerator = update.snapshot.machTimebaseNumerator
        machTimebaseDenominator = update.snapshot.machTimebaseDenominator
    }
}

@MainActor
@Observable
final class ProcessListModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case active
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var rows: [ProcessRow] = []
    // Filtering and sorting happen once per sample or query change, never in a
    // view body — bodies re-run every second and must stay O(visible rows).
    private(set) var visibleRows: [ProcessRow] = []
    private(set) var system = SystemRecord()
    private(set) var totalCPUFraction: Double = 0
    private(set) var uptimeNanoseconds: UInt64 = 0
    private(set) var machTimebaseNumerator: UInt32 = 1
    private(set) var machTimebaseDenominator: UInt32 = 1

    // @AppStorage owns persistence; access/withMutation re-attach Observation
    // tracking that @ObservationIgnored (required for property wrappers in
    // @Observable types) would otherwise sever.
    @ObservationIgnored
    @AppStorage("processList.sortOrder") private var storedSortOrder: ProcessSortOrder = .cpu
    @ObservationIgnored
    @AppStorage("processList.scopeFilter") private var storedScopeFilter: ProcessScopeFilter = .all

    var sortOrder: ProcessSortOrder {
        get {
            access(keyPath: \.sortOrder)
            return storedSortOrder
        }
        set {
            withMutation(keyPath: \.sortOrder) { storedSortOrder = newValue }
            rebuildVisibleRows()
        }
    }
    var scopeFilter: ProcessScopeFilter {
        get {
            access(keyPath: \.scopeFilter)
            return storedScopeFilter
        }
        set {
            withMutation(keyPath: \.scopeFilter) { storedScopeFilter = newValue }
            rebuildVisibleRows()
        }
    }
    var searchText = "" {
        didSet { rebuildVisibleRows() }
    }
    // Pausing keeps the last snapshot on screen but releases the daemon (the
    // sampling loop deactivates on exit, so the foreground lease lapses).
    var isPaused = false {
        didSet {
            if isPaused {
                samplingTask?.cancel()
            } else {
                ensureSampling()
            }
        }
    }

    private let session = ProcessDataSession()
    // Observable (not @ObservationIgnored): the detail view's live lookups
    // depend on this being tracked so each sample re-renders it.
    private var rowsByIdentity: [ProcessIdentity: ProcessRow] = [:]
    @ObservationIgnored private var shouldRun = false
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var operationChain: Task<Void, Never> = Task {}

    func row(for identity: ProcessIdentity) -> ProcessRow? {
        rowsByIdentity[identity]
    }

    func start() {
        shouldRun = true
        ensureSampling()
    }

    func stop() {
        shouldRun = false
        samplingTask?.cancel()
    }

    func details(
        _ kind: ProcessDetailKind,
        for identity: ProcessIdentity
    ) async throws -> ProcessDetailSnapshot {
        try await enqueue { [session] in
            try await session.activateIfNeeded()
            try await session.renewForegroundLease()
            return try await session.details(kind, for: identity)
        }
    }

    func sendSignal(_ signal: InspectorSignal, to identity: ProcessIdentity) async throws {
        try await enqueue { [session] in
            try await session.activateIfNeeded()
            try await session.renewForegroundLease()
            let ticket = try await session.prepareSignal(signal, for: identity)
            try await session.commitSignal(ticket: ticket)
        }
    }

    private func ensureSampling() {
        guard shouldRun, !isPaused, samplingTask == nil else { return }
        samplingTask = Task { await runSampling() }
    }

    private func runSampling() async {
        phase = .connecting
        do {
            try await enqueue { [session] in try await session.activate() }
            phase = .active
            while !Task.isCancelled {
                let scope = scopeFilter
                let order = sortOrder
                let query = searchText
                let prepared = try await enqueue { [session] in
                    try await session.renewForegroundLease()
                    // Executable paths ride along with every sample: the Apps
                    // filter and row subtitles need them, and .standard omits them.
                    let update = try await session.sample(
                        collectors: [.taskCounters, .executablePaths]
                    )
                    return PreparedSample(update: update, scope: scope, order: order, query: query)
                }
                apply(prepared)
                try? await Task.sleep(for: .seconds(1))
            }
        } catch {
            if !Task.isCancelled {
                shouldRun = false
                clearRows()
                phase = .failed(InspectorErrorText.describe(error))
            }
        }
        try? await enqueue { [session] in await session.deactivate() }
        if phase == .active || phase == .connecting { phase = .idle }
        samplingTask = nil
        ensureSampling()
    }

    private func apply(_ prepared: PreparedSample) {
        rows = prepared.rows
        rowsByIdentity = prepared.rowsByIdentity
        visibleRows = prepared.visibleRows
        totalCPUFraction = prepared.totalCPUFraction
        system = prepared.system
        uptimeNanoseconds = prepared.uptimeNanoseconds
        machTimebaseNumerator = prepared.machTimebaseNumerator
        machTimebaseDenominator = prepared.machTimebaseDenominator
    }

    private func clearRows() {
        rows = []
        rowsByIdentity = [:]
        visibleRows = []
        totalCPUFraction = 0
    }

    // Interactive changes (search, sort, filter) rebuild on the main actor from
    // the current rows and animate. Per-second samples apply unanimated (in
    // apply(_:)): animating every sample kept the 400-row list in continuous
    // batch-update animations, which let taps land on rows mid-move and held
    // extra cells alive for the duration of each move.
    private func rebuildVisibleRows() {
        withAnimation(.smooth) {
            visibleRows = Self.visibleRows(in: rows, scope: scopeFilter, order: sortOrder, query: searchText)
        }
    }

    nonisolated static func visibleRows(
        in rows: [ProcessRow],
        scope: ProcessScopeFilter,
        order: ProcessSortOrder,
        query: String
    ) -> [ProcessRow] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let pidQuery = Int32(query)
        var result = rows.filter { row in
            scope.matches(row)
                && (query.isEmpty
                    || row.record.name.localizedCaseInsensitiveContains(query)
                    || row.record.pid == pidQuery)
        }
        result.sort(by: order.areInOrder)
        return result
    }

    private func enqueue<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = operationChain
        let task = Task { () throws -> T in
            await previous.value
            return try await body()
        }
        operationChain = Task { _ = try? await task.value }
        return try await task.value
    }
}
