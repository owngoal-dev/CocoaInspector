import Foundation

enum InspectorProtocol {
    static let version: UInt64 = 2
    static let serviceName = "wiki.qaq.inspector.service"
    static let clientEntitlement = "wiki.qaq.inspector.client"
    // Resolved against the install root the daemon itself runs from, so the
    // same list covers roothide's randomized bootstrap and the fixed rootless
    // /var/jb prefix. See PeerAuthenticator.resolveInstalledClientPaths().
    static let clientPaths = [
        "/Applications/Inspector.app/Inspector",
        "/usr/bin/cocoainspector",
    ]
    static let signalTicketByteCount = 32
    static let maximumMessageDataByteCount = 2 * 1_024 * 1_024
    static let foregroundLeaseNanoseconds: UInt64 = 3_000_000_000
}

enum InspectorOperation: UInt64, Sendable {
    case hello = 1
    case renewForegroundLease = 2
    case snapshot = 3
    case prepareSignal = 4
    case commitSignal = 5
    case goodbye = 6
    case processDetails = 7
}

enum InspectorReplyCode: Int64, Sendable {
    case success = 0
    case invalidRequest = 1
    case foregroundLeaseRequired = 2
    case busy = 3
    case targetChanged = 4
    case ticketExpired = 5
    case operationFailed = 6
}

enum InspectorSignal: UInt64, Sendable {
    case terminate = 15
    case forceKill = 9
}

struct ProcessCollectorMask: OptionSet, Sendable {
    let rawValue: UInt64

    static let taskCounters = ProcessCollectorMask(rawValue: 1 << 0)
    static let fileDescriptors = ProcessCollectorMask(rawValue: 1 << 1)
    static let executablePaths = ProcessCollectorMask(rawValue: 1 << 2)
    static let commandLines = ProcessCollectorMask(rawValue: 1 << 3)
    static let ports = ProcessCollectorMask(rawValue: 1 << 4)
    static let sandbox = ProcessCollectorMask(rawValue: 1 << 5)
    static let network = ProcessCollectorMask(rawValue: 1 << 6)
    static let taskMetadata = ProcessCollectorMask(rawValue: 1 << 7)

    static let standard: ProcessCollectorMask = [.taskCounters]
    static let all: ProcessCollectorMask = [
        .taskCounters,
        .fileDescriptors,
        .executablePaths,
        .commandLines,
        .ports,
        .sandbox,
        .network,
        .taskMetadata,
    ]

    static let supported = ProcessCollectorMask.all
}

enum InspectorDataError: Error, Equatable, Sendable {
    case disconnected
    case alreadyActive
    case busy
    case invalidReply
    case rejected(InspectorReplyCode)
    case transportFailure
    case malformedSnapshot
}

enum InspectorWireKey {
    static let version = "v"
    static let operation = "op"
    static let code = "code"
    static let payload = "payload"
    static let collectorMask = "mask"
    static let pid = "pid"
    static let processStartTime = "start"
    static let signal = "signal"
    static let signalTicket = "ticket"
    static let detailKind = "detail"
}
