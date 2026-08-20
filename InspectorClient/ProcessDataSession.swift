import Foundation

actor ProcessDataSession {
    private let client = InspectorDataClient()
    private var reducer = ProcessSnapshotReducer()

    func activate() async throws {
        reducer.reset()
        try await client.activate()
    }

    // One-shot operations (details, signals) must work while sampling is paused
    // and the connection has been torn down; the reducer is left untouched so an
    // in-progress sampling loop keeps its delta baselines.
    func activateIfNeeded() async throws {
        do {
            try await client.activate()
        } catch InspectorDataError.alreadyActive {}
    }

    func sample(collectors: ProcessCollectorMask = .standard) async throws -> ProcessSnapshotUpdate {
        let snapshot = try await client.snapshot(collectors: collectors)
        return reducer.consume(snapshot)
    }

    func details(
        _ kind: ProcessDetailKind,
        for identity: ProcessIdentity
    ) async throws -> ProcessDetailSnapshot {
        try await client.details(kind, for: identity)
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
