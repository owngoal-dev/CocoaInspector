import Dispatch
import Foundation
import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func inspectorCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64
) -> xpc_connection_t?

actor InspectorDataClient {
    private enum State {
        case disconnected
        case connected
        case active
    }

    private struct Reply: Sendable {
        let code: InspectorReplyCode
        let payload: Data?
        let ticket: Data?
    }

    private let queue = DispatchQueue(
        label: "wiki.qaq.inspector.client.xpc",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private var connection: xpc_connection_t?
    private var state: State = .disconnected
    private var generation: UInt64 = 0
    private var requestInFlight = false

    func activate() async throws {
        guard case .disconnected = state else { throw InspectorDataError.alreadyActive }
        guard let connection = InspectorProtocol.serviceName.withCString({
            inspectorCreateMachServiceConnection($0, queue, 0)
        }) else { throw InspectorDataError.transportFailure }

        generation &+= 1
        let currentGeneration = generation
        self.connection = connection
        state = .connected
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            Task { await self?.disconnect(generation: currentGeneration) }
        }
        xpc_connection_activate(connection)

        do {
            let reply = try await send(.hello)
            try requireSuccess(reply)
            state = .active
        } catch {
            disconnect(generation: currentGeneration)
            throw error
        }
    }

    func snapshot(collectors: ProcessCollectorMask = .standard) async throws -> ProcessSnapshot {
        guard collectors.subtracting(.supported).isEmpty else {
            throw InspectorDataError.invalidReply
        }
        let reply = try await send(.snapshot) {
            xpc_dictionary_set_uint64($0, InspectorWireKey.collectorMask, collectors.rawValue)
        }
        try requireSuccess(reply)
        guard let payload = reply.payload else { throw InspectorDataError.invalidReply }
        do {
            return try autoreleasepool { try SnapshotWireCodec.decode(payload) }
        } catch {
            throw InspectorDataError.malformedSnapshot
        }
    }

    func details(
        _ kind: ProcessDetailKind,
        for identity: ProcessIdentity
    ) async throws -> ProcessDetailSnapshot {
        let reply = try await send(.processDetails) {
            xpc_dictionary_set_int64($0, InspectorWireKey.pid, Int64(identity.pid))
            xpc_dictionary_set_uint64($0, InspectorWireKey.processStartTime, identity.startTime)
            xpc_dictionary_set_uint64($0, InspectorWireKey.detailKind, kind.rawValue)
        }
        try requireSuccess(reply)
        guard let payload = reply.payload else { throw InspectorDataError.invalidReply }
        do {
            let details = try autoreleasepool {
                try SnapshotWireCodec.decode(payload, as: ProcessDetailSnapshot.self)
            }
            guard details.identity == identity, details.kind == kind else {
                throw InspectorDataError.invalidReply
            }
            return details
        } catch let error as InspectorDataError {
            throw error
        } catch {
            throw InspectorDataError.malformedSnapshot
        }
    }

    func prepareSignal(_ signal: InspectorSignal, for identity: ProcessIdentity) async throws -> Data {
        let reply = try await send(.prepareSignal) {
            xpc_dictionary_set_int64($0, InspectorWireKey.pid, Int64(identity.pid))
            xpc_dictionary_set_uint64($0, InspectorWireKey.processStartTime, identity.startTime)
            xpc_dictionary_set_uint64($0, InspectorWireKey.signal, signal.rawValue)
        }
        try requireSuccess(reply)
        guard let ticket = reply.ticket,
              ticket.count == InspectorProtocol.signalTicketByteCount else {
            throw InspectorDataError.invalidReply
        }
        return ticket
    }

    func commitSignal(ticket: Data) async throws {
        guard ticket.count == InspectorProtocol.signalTicketByteCount else {
            throw InspectorDataError.invalidReply
        }
        let reply = try await send(.commitSignal) {
            setData(ticket, key: InspectorWireKey.signalTicket, dictionary: $0)
        }
        try requireSuccess(reply)
    }

    func deactivate() async {
        if !requestInFlight, case .active = state {
            _ = try? await send(.goodbye)
        }
        disconnect(generation: generation)
    }

    private func send(
        _ operation: InspectorOperation,
        payload: ((xpc_object_t) -> Void)? = nil
    ) async throws -> Reply {
        guard !requestInFlight else { throw InspectorDataError.busy }
        guard let connection else { throw InspectorDataError.disconnected }
        switch state {
        case .disconnected:
            throw InspectorDataError.disconnected
        case .connected where operation != .hello:
            throw InspectorDataError.disconnected
        case .active where operation == .hello:
            throw InspectorDataError.invalidReply
        default:
            break
        }

        requestInFlight = true
        let requestGeneration = generation
        return try await withCheckedThrowingContinuation { continuation in
            autoreleasepool {
                let message = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_uint64(message, InspectorWireKey.version, InspectorProtocol.version)
                xpc_dictionary_set_uint64(message, InspectorWireKey.operation, operation.rawValue)
                payload?(message)
                xpc_connection_send_message_with_reply(connection, message, queue) { object in
                    let result = autoreleasepool { Self.parseReply(object) }
                    Task {
                        await self.finish(
                            result,
                            generation: requestGeneration,
                            continuation: continuation
                        )
                    }
                }
            }
        }
    }

    private func finish(
        _ result: Result<Reply, Error>,
        generation requestGeneration: UInt64,
        continuation: CheckedContinuation<Reply, Error>
    ) {
        guard requestGeneration == generation else {
            continuation.resume(throwing: InspectorDataError.disconnected)
            return
        }
        requestInFlight = false
        continuation.resume(with: result)
    }

    private func disconnect(generation expected: UInt64) {
        guard expected == generation else { return }
        if let connection { xpc_connection_cancel(connection) }
        connection = nil
        state = .disconnected
        requestInFlight = false
        generation &+= 1
    }

    private func requireSuccess(_ reply: Reply) throws {
        guard reply.code == .success else { throw InspectorDataError.rejected(reply.code) }
    }

    private static func parseReply(_ object: xpc_object_t) -> Result<Reply, Error> {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_uint64(object, InspectorWireKey.version) == InspectorProtocol.version,
              let code = InspectorReplyCode(rawValue: xpc_dictionary_get_int64(object, InspectorWireKey.code)) else {
            return .failure(InspectorDataError.transportFailure)
        }
        return .success(Reply(
            code: code,
            payload: data(InspectorWireKey.payload, in: object),
            ticket: data(InspectorWireKey.signalTicket, in: object)
        ))
    }

    private static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count),
              count <= InspectorProtocol.maximumMessageDataByteCount else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

private func setData(_ data: Data, key: String, dictionary: xpc_object_t) {
    data.withUnsafeBytes {
        if let bytes = $0.baseAddress {
            xpc_dictionary_set_data(dictionary, key, bytes, $0.count)
        }
    }
}
