import Dispatch
import Foundation
import XPC

final class PeerSession {
    private let controlQueue: DispatchQueue
    private let samplingQueue: DispatchQueue
    private let sampler: ProcessSampler
    private let detailSampler: DetailSampler
    private let networkSampler = NetworkSampler()
    private let signalGate: SignalGate
    private let onInvalidation: () -> Void
    private var connection: xpc_connection_t?
    private var handshakeComplete = false
    private var snapshotInFlight = false
    private var snapshotGeneration: UInt64 = 0
    private var active = true

    init(
        connection: xpc_connection_t,
        clientPID: Int32,
        controlQueue: DispatchQueue,
        samplingQueue: DispatchQueue,
        sampler: ProcessSampler,
        detailSampler: DetailSampler,
        onInvalidation: @escaping () -> Void
    ) {
        self.connection = connection
        self.controlQueue = controlQueue
        self.samplingQueue = samplingQueue
        self.sampler = sampler
        self.detailSampler = detailSampler
        signalGate = SignalGate(sampler: sampler, clientPID: clientPID)
        self.onInvalidation = onInvalidation
    }

    func activate() {
        guard let connection else { return }
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool { self?.handle(event) }
        }
        xpc_connection_activate(connection)
    }

    private func handle(_ request: xpc_object_t) {
        guard active,
              xpc_get_type(request) == InspectorXPC.typeDictionary,
              let reply = xpc_dictionary_create_reply(request) else {
            invalidate()
            return
        }
        xpc_dictionary_set_uint64(reply, InspectorWireKey.version, InspectorProtocol.version)
        guard xpc_dictionary_get_uint64(request, InspectorWireKey.version) == InspectorProtocol.version,
              let operation = InspectorOperation(
                rawValue: xpc_dictionary_get_uint64(request, InspectorWireKey.operation)
              ) else {
            send(reply, .invalidRequest)
            return
        }

        if operation == .hello {
            guard !handshakeComplete else { return send(reply, .invalidRequest) }
            handshakeComplete = true
            send(reply, .success)
            return
        }
        guard handshakeComplete else { return send(reply, .invalidRequest) }
        guard !snapshotInFlight else { return send(reply, .busy) }

        switch operation {
        case .hello:
            break
        case .snapshot:
            beginSnapshot(request, reply)
        case .prepareSignal:
            prepareSignal(request, reply)
        case .commitSignal:
            commitSignal(request, reply)
        case .goodbye:
            send(reply, .success)
            controlQueue.async { [weak self] in self?.invalidate() }
        case .processDetails:
            beginDetails(request, reply)
        }
    }

    private func beginSnapshot(_ request: xpc_object_t, _ reply: xpc_object_t) {
        let collectors = ProcessCollectorMask(
            rawValue: xpc_dictionary_get_uint64(request, InspectorWireKey.collectorMask)
        )
        guard collectors.subtracting(.supported).isEmpty else { return send(reply, .invalidRequest) }

        snapshotInFlight = true
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        samplingQueue.async { [weak self] in
            guard let self else { return }
            let payload = autoreleasepool { () -> Data? in
                let network = collectors.contains(.network)
                    ? self.networkSampler.sample()
                    : nil
                guard var snapshot = try? self.sampler.snapshot(
                    collectors: collectors,
                    generation: generation,
                    network: network
                ) else { return nil }
                if collectors.contains(.network) {
                    let error = self.networkSampler.errorCode
                    snapshot.system.networkErrorCode = error
                    snapshot.system.networkStatus = network == nil
                        ? (error == EPERM || error == EACCES ? .permissionDenied : .failed)
                        : .available
                }
                return try? SnapshotWireCodec.encode(snapshot)
            }
            self.controlQueue.async { [weak self] in self?.finishSnapshot(payload, reply) }
        }
    }

    private func finishSnapshot(_ payload: Data?, _ reply: xpc_object_t) {
        guard active else { return }
        snapshotInFlight = false
        guard let payload else { return send(reply, .operationFailed) }
        setData(payload, key: InspectorWireKey.payload, dictionary: reply)
        send(reply, .success)
    }

    private func beginDetails(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let kind = ProcessDetailKind(
                rawValue: xpc_dictionary_get_uint64(request, InspectorWireKey.detailKind)
              ) else { return send(reply, .invalidRequest) }
        let pid = xpc_dictionary_get_int64(request, InspectorWireKey.pid)
        guard pid >= 0, pid <= Int64(Int32.max) else { return send(reply, .invalidRequest) }
        let identity = ProcessIdentity(
            pid: Int32(pid),
            startTime: xpc_dictionary_get_uint64(request, InspectorWireKey.processStartTime)
        )

        snapshotInFlight = true
        samplingQueue.async { [weak self] in
            guard let self else { return }
            let payload = autoreleasepool {
                try? SnapshotWireCodec.encode(
                    self.detailSampler.snapshot(kind: kind, identity: identity)
                )
            }
            self.controlQueue.async { [weak self] in self?.finishSnapshot(payload, reply) }
        }
    }

    private func prepareSignal(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let signal = InspectorSignal(
                rawValue: xpc_dictionary_get_uint64(request, InspectorWireKey.signal)
              ) else { return send(reply, .invalidRequest) }
        let pid = xpc_dictionary_get_int64(request, InspectorWireKey.pid)
        guard pid >= Int64(Int32.min), pid <= Int64(Int32.max) else {
            return send(reply, .invalidRequest)
        }
        let identity = ProcessIdentity(
            pid: Int32(pid),
            startTime: xpc_dictionary_get_uint64(request, InspectorWireKey.processStartTime)
        )
        do {
            let ticket = try signalGate.prepare(signal: signal, target: identity)
            setData(ticket, key: InspectorWireKey.signalTicket, dictionary: reply)
            send(reply, .success)
        } catch SignalGateError.targetChanged {
            send(reply, .targetChanged)
        } catch {
            send(reply, .operationFailed)
        }
    }

    private func commitSignal(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let ticket = data(
                InspectorWireKey.signalTicket,
                in: request,
                count: InspectorProtocol.signalTicketByteCount
              ) else { return send(reply, .invalidRequest) }
        do {
            try signalGate.commit(ticket: ticket)
            send(reply, .success)
        } catch SignalGateError.ticketExpired {
            send(reply, .ticketExpired)
        } catch SignalGateError.targetChanged {
            send(reply, .targetChanged)
        } catch {
            send(reply, .operationFailed)
        }
    }

    private func send(_ reply: xpc_object_t, _ code: InspectorReplyCode) {
        guard let connection, active else { return }
        xpc_dictionary_set_int64(reply, InspectorWireKey.code, code.rawValue)
        xpc_connection_send_message(connection, reply)
    }

    private func invalidate() {
        guard active else { return }
        active = false
        handshakeComplete = false
        signalGate.reset()
        samplingQueue.async { [networkSampler] in networkSampler.close() }
        if let connection { xpc_connection_cancel(connection) }
        connection = nil
        onInvalidation()
    }

    private func data(_ key: String, in dictionary: xpc_object_t, count: Int) -> Data? {
        var actualCount = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &actualCount),
              actualCount == count else { return nil }
        return Data(bytes: bytes, count: actualCount)
    }

    private func setData(_ data: Data, key: String, dictionary: xpc_object_t) {
        data.withUnsafeBytes {
            if let bytes = $0.baseAddress {
                xpc_dictionary_set_data(dictionary, key, bytes, $0.count)
            }
        }
    }
}
