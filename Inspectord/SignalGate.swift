import Darwin
import Dispatch
import Foundation

enum SignalGateError: Error {
    case failed
    case targetChanged
    case ticketExpired
}

final class SignalGate {
    private struct PendingSignal {
        let ticket: Data
        let target: ProcessIdentity
        let signal: InspectorSignal
        let deadline: UInt64
    }

    private static let ticketLifetimeNanoseconds: UInt64 = 5_000_000_000

    private let sampler: ProcessSampler
    private let clientPID: Int32
    private var pending: PendingSignal?

    init(sampler: ProcessSampler, clientPID: Int32) {
        self.sampler = sampler
        self.clientPID = clientPID
    }

    func prepare(
        signal: InspectorSignal,
        target: ProcessIdentity
    ) throws -> Data {
        guard target.pid > 1,
              target.pid != getpid(),
              target.pid != clientPID,
              target.startTime != 0 else {
            throw SignalGateError.failed
        }
        guard sampler.startTime(for: target.pid) == target.startTime else {
            throw SignalGateError.targetChanged
        }

        let ticket = randomTicket()
        pending = PendingSignal(
            ticket: ticket,
            target: target,
            signal: signal,
            deadline: DispatchTime.now().uptimeNanoseconds + Self.ticketLifetimeNanoseconds
        )
        return ticket
    }

    func commit(ticket: Data) throws {
        guard let action = pending else {
            throw SignalGateError.failed
        }
        pending = nil

        guard constantTimeEqual(ticket, action.ticket) else {
            throw SignalGateError.failed
        }
        guard DispatchTime.now().uptimeNanoseconds <= action.deadline else {
            throw SignalGateError.ticketExpired
        }
        guard sampler.startTime(for: action.target.pid) == action.target.startTime else {
            throw SignalGateError.targetChanged
        }
        guard kill(action.target.pid, Int32(action.signal.rawValue)) == 0 else {
            throw SignalGateError.failed
        }
    }

    func reset() {
        pending = nil
    }

    private func randomTicket() -> Data {
        var data = Data(count: InspectorProtocol.signalTicketByteCount)
        data.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                arc4random_buf(baseAddress, bytes.count)
            }
        }
        return data
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
