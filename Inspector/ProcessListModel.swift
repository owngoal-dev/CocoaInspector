import Combine
import Foundation

struct ProcessRow: Identifiable, Equatable {
    let record: ProcessRecord
    let cpuFraction: Double

    var id: ProcessIdentity { record.identity }
    var displayName: String { record.name.isEmpty ? "pid \(record.pid)" : record.name }
    var isApp: Bool {
        ApplicationBundleLocator.hostApplicationPath(for: record.executablePath) != nil
    }
}

enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case threads = "Threads"
    case pid = "PID"
    case name = "Name"

    var id: Self { self }

    // rawValue is the @AppStorage key, so it stays fixed; the label is what
    // the menu shows and is translated.
    var label: String {
        switch self {
        case .cpu: String(localized: "CPU Usage")
        case .memory: String(localized: "Memory Used")
        case .threads: String(localized: "Threads")
        case .pid: String(localized: "PID")
        case .name: String(localized: "Name")
        }
    }

    // Total order with pid as the final tiebreaker: Swift's sort is not
    // stable, so without it equal-keyed rows (idle processes, same-named
    // helpers) shuffle randomly on every resort.
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
        case .threads:
            if lhs.record.threadCount != rhs.record.threadCount {
                return lhs.record.threadCount > rhs.record.threadCount
            }
            return lhs.record.pid < rhs.record.pid
        }
    }
}

enum ProcessScopeFilter: String, CaseIterable, Identifiable {
    case all
    case root
    case mobile
    case apps

    var id: Self { self }

    private static let rootUserID = UserAccountResolver.shared.id(for: "root")
    private static let mobileUserID = UserAccountResolver.shared.id(for: "mobile")

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
        case .root:
            Self.rootUserID.map { row.record.userID == $0 } ?? false
        case .mobile:
            Self.mobileUserID.map { row.record.userID == $0 } ?? false
        case .apps: row.isApp
        }
    }
}

// Every sample walks the whole process table in the daemon and redraws the
// list here. The default of five seconds keeps both quiet enough to leave
// running; the shorter paces are for watching something change. CPU use is
// measured over the time that actually passed between two samples, so every
// pace reads correctly.
enum ProcessRefreshInterval: Int, CaseIterable, Identifiable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Self { self }

    // rawValue, in whole seconds, is what the preference stores.
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String { String(localized: "\(rawValue) seconds") }
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
final class ProcessListModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case active
        case failed(String)
    }

    // One aggregate value keeps a sample atomic for the screens observing it:
    // every field of a sample lands in a single `changes` event, so the
    // 400-row list redraws once per sample, not once per field.
    private struct ViewState {
        var phase: Phase = .idle
        var rows: [ProcessRow] = []
        var rowsByIdentity: [ProcessIdentity: ProcessRow] = [:]
        var visibleRows: [ProcessRow] = []
        var system = SystemRecord()
        var totalCPUFraction: Double = 0
        var uptimeNanoseconds: UInt64 = 0
        var machTimebaseNumerator: UInt32 = 1
        var machTimebaseDenominator: UInt32 = 1
        var sortOrder: ProcessSortOrder
        var scopeFilter: ProcessScopeFilter
        var refreshInterval: ProcessRefreshInterval
        var searchText = ""
        var isPaused = false
    }

    private static let firstSampleDelay: TimeInterval = 1

    private static let sortOrderKey = "processList.sortOrder"
    private static let scopeFilterKey = "processList.scopeFilter"
    private static let refreshIntervalKey = "processList.refreshInterval"

    private var viewState: ViewState {
        didSet { changes.send() }
    }
    private let defaults: UserDefaults

    /// Fires on the main actor after every state change.
    let changes = PassthroughSubject<Void, Never>()

    private(set) var phase: Phase {
        get { viewState.phase }
        set { viewState.phase = newValue }
    }
    var rows: [ProcessRow] { viewState.rows }
    // Filtering and sorting happen once per sample or query change, never in a
    // cell — rows are redrawn on every sample and must stay O(visible rows).
    var visibleRows: [ProcessRow] { viewState.visibleRows }
    var system: SystemRecord { viewState.system }
    var totalCPUFraction: Double { viewState.totalCPUFraction }
    var uptimeNanoseconds: UInt64 { viewState.uptimeNanoseconds }
    var machTimebaseNumerator: UInt32 { viewState.machTimebaseNumerator }
    var machTimebaseDenominator: UInt32 { viewState.machTimebaseDenominator }

    var sortOrder: ProcessSortOrder {
        get { viewState.sortOrder }
        set {
            guard newValue != viewState.sortOrder else { return }
            defaults.set(newValue.rawValue, forKey: Self.sortOrderKey)
            rebuildVisibleRows { $0.sortOrder = newValue }
        }
    }
    var scopeFilter: ProcessScopeFilter {
        get { viewState.scopeFilter }
        set {
            guard newValue != viewState.scopeFilter else { return }
            defaults.set(newValue.rawValue, forKey: Self.scopeFilterKey)
            rebuildVisibleRows { $0.scopeFilter = newValue }
        }
    }
    // A new pace ends the wait under way, so the next sample comes at once
    // and the new pace counts from there instead of from the old deadline.
    var refreshInterval: ProcessRefreshInterval {
        get { viewState.refreshInterval }
        set {
            guard newValue != viewState.refreshInterval else { return }
            defaults.set(newValue.rawValue, forKey: Self.refreshIntervalKey)
            viewState.refreshInterval = newValue
            pendingWait?.finish()
        }
    }
    var searchText: String {
        get { viewState.searchText }
        set {
            guard newValue != viewState.searchText else { return }
            rebuildVisibleRows { $0.searchText = newValue }
        }
    }
    // Pausing keeps the last snapshot on screen and closes this client's XPC
    // session. Returning to live mode creates a fresh foreground session.
    var isPaused: Bool {
        get { viewState.isPaused }
        set {
            guard newValue != viewState.isPaused else { return }
            var next = viewState
            next.isPaused = newValue
            viewState = next
            if newValue {
                samplingTask?.cancel()
            } else {
                ensureSampling()
            }
        }
    }

    private let session = ProcessDataSession()
    private var shouldRun = false
    private var samplingTask: Task<Void, Never>?
    private var pendingWait: SampleWait?
    private var operationChain: Task<Void, Never> = Task {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let sortOrder = defaults.string(forKey: Self.sortOrderKey)
            .flatMap(ProcessSortOrder.init(rawValue:)) ?? .cpu
        let scopeFilter = defaults.string(forKey: Self.scopeFilterKey)
            .flatMap(ProcessScopeFilter.init(rawValue:)) ?? .all
        // A missing preference reads as 0, which is no interval.
        let refreshInterval = ProcessRefreshInterval(
            rawValue: defaults.integer(forKey: Self.refreshIntervalKey)
        ) ?? .fiveSeconds
        viewState = ViewState(
            sortOrder: sortOrder,
            scopeFilter: scopeFilter,
            refreshInterval: refreshInterval
        )
    }

    func row(for identity: ProcessIdentity) -> ProcessRow? {
        viewState.rowsByIdentity[identity]
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
        let closesAfterOperation = !shouldRun || isPaused
        return try await enqueue { [session] in
            try await session.activateIfNeeded()
            do {
                let details = try await session.details(kind, for: identity)
                if closesAfterOperation { await session.deactivate() }
                return details
            } catch {
                if closesAfterOperation { await session.deactivate() }
                throw error
            }
        }
    }

    func sendSignal(_ signal: InspectorSignal, to identity: ProcessIdentity) async throws {
        let closesAfterOperation = !shouldRun || isPaused
        let scope = scopeFilter
        let order = sortOrder
        let query = searchText
        let prepared = try await enqueue { [session] in
            try await session.activateIfNeeded()
            do {
                let ticket = try await session.prepareSignal(signal, for: identity)
                try await session.commitSignal(ticket: ticket)
                // The daemon has acknowledged the signal. Refresh once even
                // when live updates are paused, before closing the connection.
                // A failed refresh must not report an already-sent signal as failed.
                let update = try? await session.sample(collectors: [.taskCounters, .executablePaths])
                let prepared = update.map {
                    PreparedSample(update: $0, scope: scope, order: order, query: query)
                }
                if closesAfterOperation { await session.deactivate() }
                return prepared
            } catch {
                if closesAfterOperation { await session.deactivate() }
                throw error
            }
        }
        if let prepared { apply(prepared) }
    }

    private func ensureSampling() {
        guard shouldRun, !isPaused, samplingTask == nil else { return }
        // Sampling is background UI work. Keeping it below user-initiated
        // scrolling lets the main actor service gestures and layout first.
        samplingTask = Task(priority: .utility) { await runSampling() }
    }

    private func runSampling() async {
        phase = .connecting
        do {
            try await enqueue { [session] in try await session.activate() }
            phase = .active
            var isFirstSample = true
            while !Task.isCancelled {
                let scope = scopeFilter
                let order = sortOrder
                let query = searchText
                let prepared = try await enqueue { [session] in
                    // Executable paths ride along with every sample: the Apps
                    // filter and row subtitles need them, and .standard omits them.
                    let update = try await session.sample(
                        collectors: [.taskCounters, .executablePaths]
                    )
                    return PreparedSample(update: update, scope: scope, order: order, query: query)
                }
                guard !Task.isCancelled else { break }
                apply(prepared)
                // CPU use is the growth between two samples, so the first
                // one has none to show; the second follows quickly to fill
                // it in, and the steady pace starts from there.
                await wait(seconds: isFirstSample ? Self.firstSampleDelay : refreshInterval.seconds)
                isFirstSample = false
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

    // Task.sleep resumes independently of the main RunLoop mode, which lets a
    // sample redraw every visible row while UIScrollView is tracking a
    // gesture. A default-mode timer is deferred during UI tracking and resumes
    // sampling after scrolling yields the RunLoop back to normal UI work.
    // Cancelling ends the wait at once, so pausing and resuming doesn't sit
    // out the rest of the gap.
    private func wait(seconds: TimeInterval) async {
        let wait = SampleWait()
        pendingWait = wait
        defer { if pendingWait === wait { pendingWait = nil } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait.start(seconds: seconds, continuation: $0) }
        } onCancel: {
            Task { @MainActor in wait.finish() }
        }
    }

    private func apply(_ prepared: PreparedSample) {
        var next = viewState
        next.rows = prepared.rows
        next.rowsByIdentity = prepared.rowsByIdentity
        next.visibleRows = prepared.visibleRows
        next.totalCPUFraction = prepared.totalCPUFraction
        next.system = prepared.system
        next.uptimeNanoseconds = prepared.uptimeNanoseconds
        next.machTimebaseNumerator = prepared.machTimebaseNumerator
        next.machTimebaseDenominator = prepared.machTimebaseDenominator
        viewState = next
    }

    private func clearRows() {
        var next = viewState
        next.rows = []
        next.rowsByIdentity = [:]
        next.visibleRows = []
        next.totalCPUFraction = 0
        viewState = next
    }

    // Interactive changes (search, sort, filter) rebuild on the main actor from
    // the current rows, without waiting for the next sample.
    private func rebuildVisibleRows(_ update: (inout ViewState) -> Void) {
        var next = viewState
        update(&next)
        next.visibleRows = Self.visibleRows(
            in: next.rows,
            scope: next.scopeFilter,
            order: next.sortOrder,
            query: next.searchText
        )
        viewState = next
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

// One wait between samples: a default-mode timer that a cancelled task can cut
// short. Whichever of the timer and the cancellation comes first resumes the
// continuation; the other finds nothing left to do.
@MainActor
private final class SampleWait {
    private var timer: Timer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func start(seconds: TimeInterval, continuation: CheckedContinuation<Void, Never>) {
        guard !isFinished else {
            continuation.resume()
            return
        }
        self.continuation = continuation
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let wait = self else { return }
            Task { @MainActor in wait.finish() }
        }
        timer.tolerance = seconds / 10
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    func finish() {
        isFinished = true
        timer?.invalidate()
        timer = nil
        continuation?.resume()
        continuation = nil
    }
}
