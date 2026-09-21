import Darwin
import Dispatch
import Foundation

struct NetworkUsage {
    var bytesReceived: UInt64 = 0
    var bytesSent: UInt64 = 0
    var packetsReceived: UInt64 = 0
    var packetsSent: UInt64 = 0

    mutating func add(_ other: NetworkUsage) {
        bytesReceived = saturatedAdd(bytesReceived, other.bytesReceived)
        bytesSent = saturatedAdd(bytesSent, other.bytesSent)
        packetsReceived = saturatedAdd(packetsReceived, other.packetsReceived)
        packetsSent = saturatedAdd(packetsSent, other.packetsSent)
    }

    private func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}

final class NetworkSampler {
    private struct Source {
        var pid: Int32?
        var usage = NetworkUsage()
    }

    private static let controlName = "com.apple.network.statistics"
    private static let controlInfoRequest = UInt(0xC0644E03)
    private static let protocolControl: Int32 = 2
    private static let systemControlAddress: UInt16 = 2
    private static let providers: [UInt32] = [2, 3, 4, 5]
    private static let tcpProviders: Set<UInt32> = [2, 3]
    private static let udpProviders: Set<UInt32> = [4, 5]
    private static let addAllSources: UInt32 = 1_002
    private static let getUpdate: UInt32 = 1_007
    private static let successResponse: UInt32 = 0
    private static let errorResponse: UInt32 = 1
    private static let sourceRemoved: UInt32 = 10_002
    private static let sourceUpdate: UInt32 = 10_006
    private static let extendedSourceUpdate: UInt32 = 10_007
    private static let updateContext: UInt64 = 0x4343_5049
    private static let allSources = UInt64.max
    private static let continuationFlag: UInt16 = 1 << 1
    private static let acceptAllNonzeroSources: UInt64 = 0x0051_FFFF
    private static let maximumSources = 4_096
    private static let maximumCachedProcesses = 2_048
    private static let maximumMessageSize = 4_096
    private static let receiveBufferSize: Int32 = 256 * 1_024
    private static let responseWindowNanoseconds: UInt64 = 100_000_000

    private var descriptor: Int32 = -1
    private var sources = [UInt64: Source]()
    private var closedUsage = [Int32: NetworkUsage]()
    private var updatePending = false
    private(set) var errorCode: Int32 = 0

    func sample() -> [Int32: NetworkUsage]? {
        errorCode = 0
        if descriptor < 0, !open() { return nil }
        updatePending = true
        guard sendUpdate(), drainResponses() else {
            if errorCode == 0 { errorCode = errno == 0 ? EIO : errno }
            close()
            return nil
        }

        var totals = closedUsage
        for source in sources.values {
            guard let pid = source.pid else { continue }
            totals[pid, default: NetworkUsage()].add(source.usage)
        }
        return totals
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        sources.removeAll(keepingCapacity: false)
        closedUsage.removeAll(keepingCapacity: false)
        updatePending = false
    }

    private func open() -> Bool {
        let socketDescriptor = socket(PF_SYSTEM, SOCK_DGRAM, Self.protocolControl)
        guard socketDescriptor >= 0 else { errorCode = errno; return false }
        descriptor = socketDescriptor
        var receiveBufferSize = Self.receiveBufferSize
        let configured = withUnsafePointer(to: &receiveBufferSize) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVBUF,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        }
        guard configured,
              connectControlSocket(),
              Self.providers.allSatisfy({ sendAddAll(provider: $0) }) else {
            if errorCode == 0 { errorCode = errno == 0 ? EIO : errno }
            close()
            return false
        }
        return true
    }

    private func connectControlSocket() -> Bool {
        var control = [UInt8](repeating: 0, count: 100)
        let name = Array(Self.controlName.utf8)
        guard name.count < 96 else { return false }
        control.replaceSubrange(4..<(4 + name.count), with: name)
        let result = control.withUnsafeMutableBytes { buffer -> Int32 in
            guard let address = buffer.baseAddress else { return -1 }
            let pointer: UnsafeMutableRawPointer = address
            return Darwin.ioctl(descriptor, Self.controlInfoRequest, pointer)
        }
        guard result == 0 else {
            errorCode = errno
            return false
        }
        guard let identifier = control.withUnsafeBytes({ $0.inspectorLoad(UInt32.self, at: 0) }) else {
            errorCode = EIO
            return false
        }

        var address = [UInt8](repeating: 0, count: 32)
        address[0] = UInt8(address.count)
        address[1] = UInt8(PF_SYSTEM)
        store(Self.systemControlAddress, in: &address, at: 2)
        store(identifier, in: &address, at: 4)
        let connected = address.withUnsafeBytes {
            Darwin.connect(
                descriptor,
                $0.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                socklen_t(address.count)
            ) == 0
        }
        if !connected { errorCode = errno }
        return connected
    }

    private func sendAddAll(provider: UInt32) -> Bool {
        var message = header(type: Self.addAllSources, context: UInt64(provider), count: 56)
        store(Self.acceptAllNonzeroSources, in: &message, at: 16)
        store(provider, in: &message, at: 32)
        let result = send(message)
        if !result { errorCode = errno }
        return result
    }

    private func sendUpdate() -> Bool {
        var message = header(
            type: Self.getUpdate,
            context: Self.updateContext,
            count: 24,
            flags: Self.continuationFlag
        )
        store(Self.allSources, in: &message, at: 16)
        return send(message)
    }

    private func send(_ message: [UInt8]) -> Bool {
        message.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count) == $0.count
        }
    }

    private func drainResponses() -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.responseWindowNanoseconds
        var message = [UInt8](repeating: 0, count: Self.maximumMessageSize)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return !updatePending }
            let remaining = deadline - now
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let timeout = Int32(max(1, min(100, remaining / 1_000_000)))
            let ready = poll(&item, 1, timeout)
            if ready == 0 { return !updatePending }
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            let count = message.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else { return false }
            autoreleasepool {
                message.withUnsafeBytes {
                    handleDatagram(UnsafeRawBufferPointer(rebasing: $0[..<count]))
                }
            }
            if errorCode != 0 { return false }
            if !updatePending { return true }
        }
    }

    private func handleDatagram(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset + 16 <= bytes.count {
            guard let length = bytes.inspectorLoad(UInt16.self, at: offset + 12) else { return }
            let count = Int(length)
            guard count >= 16, count <= bytes.count - offset else { return }
            handle(UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]))
            offset += count
        }
    }

    private func handle(_ bytes: UnsafeRawBufferPointer) {
        guard let type = bytes.inspectorLoad(UInt32.self, at: 8) else { return }
        if type == Self.successResponse,
           bytes.inspectorLoad(UInt64.self, at: 0) == Self.updateContext {
            let flags = bytes.inspectorLoad(UInt16.self, at: 14) ?? 0
            if flags & Self.continuationFlag == 0 {
                updatePending = false
            } else if !sendUpdate() {
                errorCode = errno == 0 ? EIO : errno
            }
            return
        }
        if type == Self.errorResponse {
            let code = bytes.inspectorLoad(UInt32.self, at: 16) ?? UInt32(EIO)
            errorCode = Int32(code)
            return
        }
        guard let reference = bytes.inspectorLoad(UInt64.self, at: 16) else { return }
        switch type {
        case Self.sourceRemoved:
            guard let source = sources.removeValue(forKey: reference),
                  let pid = source.pid else { return }
            guard closedUsage[pid] != nil
                    || closedUsage.count < Self.maximumCachedProcesses else { return }
            closedUsage[pid, default: NetworkUsage()].add(source.usage)
        case Self.sourceUpdate, Self.extendedSourceUpdate:
            guard sources[reference] != nil || sources.count < Self.maximumSources,
                  let provider = bytes.inspectorLoad(UInt32.self, at: 144),
                  let pid = processID(provider: provider, bytes: bytes),
                  let usage = usage(bytes: bytes) else { return }
            sources[reference] = Source(pid: pid, usage: usage)
        default:
            break
        }
    }

    private func processID(
        provider: UInt32,
        bytes: UnsafeRawBufferPointer
    ) -> Int32? {
        let offsets: (effective: Int, owner: Int)
        if Self.tcpProviders.contains(provider) {
            offsets = (272, 268)
        } else if Self.udpProviders.contains(provider) {
            offsets = (348, 280)
        } else {
            return nil
        }
        let effective = bytes.inspectorLoad(Int32.self, at: offsets.effective) ?? 0
        let owner = bytes.inspectorLoad(Int32.self, at: offsets.owner) ?? 0
        let pid = effective > 0 ? effective : owner
        return pid > 0 ? pid : nil
    }

    private func usage(bytes: UnsafeRawBufferPointer) -> NetworkUsage? {
        guard let packetsReceived = bytes.inspectorLoad(UInt64.self, at: 32),
              let bytesReceived = bytes.inspectorLoad(UInt64.self, at: 40),
              let packetsSent = bytes.inspectorLoad(UInt64.self, at: 48),
              let bytesSent = bytes.inspectorLoad(UInt64.self, at: 56) else { return nil }
        return NetworkUsage(
            bytesReceived: bytesReceived,
            bytesSent: bytesSent,
            packetsReceived: packetsReceived,
            packetsSent: packetsSent
        )
    }

    private func header(
        type: UInt32,
        context: UInt64,
        count: Int,
        flags: UInt16 = 0
    ) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: count)
        store(context, in: &message, at: 0)
        store(type, in: &message, at: 8)
        store(UInt16(count), in: &message, at: 12)
        store(flags, in: &message, at: 14)
        return message
    }

    private func store<T>(_ value: T, in bytes: inout [UInt8], at offset: Int) {
        var value = value
        withUnsafeBytes(of: &value) {
            bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }
}
