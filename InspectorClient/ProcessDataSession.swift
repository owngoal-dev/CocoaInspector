import Foundation

actor ProcessDataSession {
    private let client = InspectorDataClient()
    private var reducer = ProcessSnapshotReducer()
    #if targetEnvironment(simulator)
    private var simulator = SimulatorProcessSource()
    #endif

    func activate() async throws {
        reducer.reset()
        #if !targetEnvironment(simulator)
        try await client.activate()
        #endif
    }

    // One-shot operations (details, signals) must work while sampling is paused
    // and the connection has been torn down; the reducer is left untouched so an
    // in-progress sampling loop keeps its delta baselines.
    func activateIfNeeded() async throws {
        #if !targetEnvironment(simulator)
        do {
            try await client.activate()
        } catch InspectorDataError.alreadyActive {}
        #endif
    }

    func sample(collectors: ProcessCollectorMask = .standard) async throws -> ProcessSnapshotUpdate {
        #if targetEnvironment(simulator)
        let snapshot = simulator.snapshot()
        #else
        let snapshot = try await client.snapshot(collectors: collectors)
        #endif
        return reducer.consume(snapshot)
    }

    func details(
        _ kind: ProcessDetailKind,
        for identity: ProcessIdentity
    ) async throws -> ProcessDetailSnapshot {
        #if targetEnvironment(simulator)
        simulator.details(kind, for: identity)
        #else
        try await client.details(kind, for: identity)
        #endif
    }

    func prepareSignal(
        _ signal: InspectorSignal,
        for identity: ProcessIdentity
    ) async throws -> Data {
        try await client.prepareSignal(signal, for: identity)
    }

    func commitSignal(ticket: Data) async throws {
        try await client.commitSignal(ticket: ticket)
    }

    func deactivate() async {
        await client.deactivate()
        reducer.reset()
    }
}
