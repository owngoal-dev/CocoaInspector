import ArgumentParser
import Darwin
import Foundation

@_silgen_name("proc_pidpath")
private func inspectorCLIProcessPath(
    _ pid: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32
) -> Int32

@main
struct CocoaInspectorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cocoainspector",
        abstract: "Inspect processes through cocoainspectord.",
        subcommands: [
            SelfTestCommand.self,
            ListProcesses.self,
            InspectProcess.self,
            ProcessDetails.self,
            WatchProcesses.self,
            SignalProcess.self,
            SignalTestChild.self,
        ]
    )
}

struct SelfTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-test",
        abstract: "Validate the XPC process data path."
    )

    @Flag(name: .customLong("signal"), help: "Also SIGTERM an owned test child.")
    var testsSignal = false

    mutating func run() async throws {
        try await CocoaInspectorOperations.withSession {
            try await CocoaInspectorOperations.selfTest($0, testSignal: testsSignal)
        }
    }
}

struct ListProcesses: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List sampled processes."
    )

    mutating func run() async throws {
        try await CocoaInspectorOperations.withSession {
            CocoaInspectorOperations.printList(try await $0.sample().snapshot.processes)
        }
    }
}

struct InspectProcess: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Print every process-list field as JSON."
    )

    @Argument(help: "Nonnegative process identifier.")
    var pid: Int32

    mutating func run() async throws {
        guard pid >= 0 else { throw ValidationError("PID must be nonnegative.") }
        try await CocoaInspectorOperations.withSession {
            let processes = try await $0.sample(collectors: .all).snapshot.processes
            guard let process = processes.first(where: { $0.pid == pid }) else {
                throw CommandFailure("process \(pid) was not found")
            }
            try CocoaInspectorOperations.printJSON(process)
        }
    }
}

struct ProcessDetails: AsyncParsableCommand {
    enum Kind: String, ExpressibleByArgument {
        case all
        case summary
        case threads
        case files
        case ports
        case modules

        var values: [ProcessDetailKind] {
            switch self {
            case .all: ProcessDetailKind.allCases
            case .summary: [.summary]
            case .threads: [.threads]
            case .files: [.files]
            case .ports: [.ports]
            case .modules: [.modules]
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "details",
        abstract: "Print Summary, Threads, Files, Ports, or Modules as JSON."
    )

    @Argument(help: "Nonnegative process identifier.")
    var pid: Int32

    @Argument(help: "Detail kind: all, summary, threads, files, ports, or modules.")
    var kind: Kind = .all

    mutating func run() async throws {
        guard pid >= 0 else { throw ValidationError("PID must be nonnegative.") }
        try await CocoaInspectorOperations.withSession {
            let identity = try await CocoaInspectorOperations.identity(pid, session: $0)
            var results = [ProcessDetailSnapshot]()
            for value in kind.values {
                results.append(try await $0.details(value, for: identity))
            }
            try CocoaInspectorOperations.printJSON(DetailOutput(results: results))
        }
    }
}

private struct DetailOutput: Encodable {
    let results: [ProcessDetailSnapshot]
}

struct WatchProcesses: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Print the top 15 processes by interval CPU."
    )

    @Option(help: "Number of samples (1...3600).")
    var count = 10

    @Option(name: .customLong("interval-ms"), help: "Interval in milliseconds (100...30000).")
    var intervalMilliseconds = 1_000

    mutating func run() async throws {
        guard (1...3_600).contains(count) else {
            throw ValidationError("Count must be between 1 and 3600.")
        }
        guard (100...30_000).contains(intervalMilliseconds) else {
            throw ValidationError("Interval must be between 100 and 30000 milliseconds.")
        }
        try await CocoaInspectorOperations.withSession {
            try await CocoaInspectorOperations.watch(
                $0,
                count: count,
                interval: UInt64(intervalMilliseconds) * 1_000_000
            )
        }
    }
}

struct SignalProcess: AsyncParsableCommand {
    enum Name: String, ExpressibleByArgument {
        case term
        case kill

        var value: InspectorSignal { self == .term ? .terminate : .forceKill }
    }

    static let configuration = CommandConfiguration(
        commandName: "signal",
        abstract: "Send a two-phase confirmed signal."
    )

    @Argument(help: "Process identifier greater than 1.")
    var pid: Int32

    @Argument(help: "Signal name: term or kill.")
    var signal: Name

    @Flag(help: "Confirm the signal operation.")
    var yes = false

    mutating func run() async throws {
        guard pid > 1 else { throw ValidationError("PID must be greater than 1.") }
        guard yes else { throw ValidationError("Pass --yes to confirm the signal operation.") }
        try await CocoaInspectorOperations.withSession {
            try await CocoaInspectorOperations.send(signal.value, to: pid, session: $0)
        }
    }
}

struct SignalTestChild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_signal-test-child",
        shouldDisplay: false
    )

    mutating func run() throws {
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGTERM)
        pthread_sigmask(SIG_UNBLOCK, &signals, nil)
        signal(SIGTERM) { _ in _exit(EXIT_SUCCESS) }
        while true { pause() }
    }
}

enum CocoaInspectorOperations {
    static func withSession(
        _ body: (ProcessDataSession) async throws -> Void
    ) async throws {
        let session = ProcessDataSession()
        try await session.activate()
        do {
            try await body(session)
            await session.deactivate()
        } catch {
            await session.deactivate()
            throw error
        }
    }

    static func selfTest(_ session: ProcessDataSession, testSignal: Bool) async throws {
        let first = try await session.sample(collectors: .all)
        let ownPID = getpid()
        guard first.started.count == first.snapshot.processes.count,
              let own = first.snapshot.processes.first(where: { $0.pid == ownPID }) else {
            throw CommandFailure("first snapshot")
        }
        let requiredAvailability: ProcessAvailability = [
            .bsd,
            .task,
            .fileDescriptors,
            .executablePath,
            .commandLine,
            .ports,
            .sandbox,
            .network,
            .taskMetadata,
        ]
        guard own.availability.contains(requiredAvailability) else {
            throw CommandFailure(
                "collector availability 0x\(String(own.availability.rawValue, radix: 16)); "
                    + "network \(first.snapshot.system.networkStatus.rawValue) "
                    + "(\(first.snapshot.system.networkErrorCode))"
            )
        }
        guard
              own.startTime > 0,
              !own.name.isEmpty,
              !own.executablePath.isEmpty else { throw CommandFailure("own process fields") }

        try await Task.sleep(nanoseconds: 200_000_000)
        let second = try await session.sample(collectors: .all)
        guard second.snapshot.generation > first.snapshot.generation,
              second.intervals.contains(where: {
                  $0.process.identity == own.identity && $0.elapsedNanoseconds > 0
              }),
              second.snapshot.processes.contains(where: {
                  $0.networkBytesReceived > 0 || $0.networkBytesSent > 0
              }) else { throw CommandFailure("snapshot delta or network counters") }

        let details = try await detailSelfTest(session, identity: own.identity)
        if testSignal {
            try await signalSelfTest(session, signal: .terminate)
            try await signalSelfTest(session, signal: .forceKill)
        }
        print("PASS xpc authentication and connection lifecycle")
        print("PASS \(second.snapshot.processes.count) process records and interval deltas")
        print("PASS system, process, command line, task, FD, port, sandbox, and network fields")
        for detail in details {
            print("PASS \(detail.kind) endpoint: \(detail.status.rawValue), \(detailCount(detail)) records")
        }
        if testSignal { print("PASS two-phase SIGTERM and SIGKILL against owned test children") }
    }

    static func detailSelfTest(
        _ session: ProcessDataSession,
        identity: ProcessIdentity
    ) async throws -> [ProcessDetailSnapshot] {
        var results = [ProcessDetailSnapshot]()
        for kind in ProcessDetailKind.allCases {
            let result = try await session.details(kind, for: identity)
            let usable = result.status == .available || result.status == .partial
            guard usable else {
                throw CommandFailure("\(kind) endpoint: \(result.status.rawValue) (\(result.errorCode))")
            }
            switch kind {
            case .summary:
                guard result.process?.identity == identity else {
                    throw CommandFailure("summary identity")
                }
            case .threads:
                guard !result.threads.isEmpty else { throw CommandFailure("thread records") }
            case .files:
                guard !result.files.isEmpty else { throw CommandFailure("file records") }
            case .ports:
                guard !result.ports.isEmpty else { throw CommandFailure("port records") }
            case .modules:
                guard !result.modules.isEmpty else { throw CommandFailure("module records") }
            }
            results.append(result)
        }
        return results
    }

    static func signalSelfTest(
        _ session: ProcessDataSession,
        signal: InspectorSignal
    ) async throws {
        let child = try spawnTestChild()
        var needsCleanup = true
        defer {
            if needsCleanup {
                kill(child, SIGKILL)
                var status: Int32 = 0
                waitpid(child, &status, 0)
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let snapshot = try await session.sample(collectors: .all).snapshot
        guard let process = snapshot.processes.first(where: { $0.pid == child }) else {
            throw CommandFailure("test child sampling")
        }
        let ticket = try await session.prepareSignal(signal, for: process.identity)
        try await session.commitSignal(ticket: ticket)

        var reaped = false
        for _ in 0..<40 {
            if !reaped {
                var status: Int32 = 0
                if waitpid(child, &status, WNOHANG) == child {
                    reaped = true
                    needsCleanup = false
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            let liveProcesses = try await session.sample().snapshot.processes
            if reaped, !liveProcesses.contains(where: { $0.identity == process.identity }) {
                return
            }
        }
        throw CommandFailure("test child termination")
    }

    static func identity(
        _ pid: Int32,
        session: ProcessDataSession
    ) async throws -> ProcessIdentity {
        let snapshot = try await session.sample().snapshot
        guard let process = snapshot.processes.first(where: { $0.pid == pid }) else {
            throw CommandFailure("process \(pid) was not found")
        }
        return process.identity
    }

    static func spawnTestChild() throws -> pid_t {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathCount = pathBuffer.withUnsafeMutableBytes {
            inspectorCLIProcessPath(getpid(), $0.baseAddress!, UInt32($0.count))
        }
        guard pathCount > 0 else { throw CommandFailure("proc_pidpath") }
        let path = String(cString: pathBuffer)
        var arguments = [strdup(path), strdup("_signal-test-child"), nil]
        defer {
            for case let argument? in arguments {
                free(UnsafeMutableRawPointer(argument))
            }
        }

        var child: pid_t = 0
        let result = path.withCString { path in
            arguments.withUnsafeMutableBufferPointer {
                posix_spawn(&child, path, nil, nil, $0.baseAddress!, environ)
            }
        }
        guard result == 0, child > 1 else { throw CommandFailure("posix_spawn") }
        return child
    }

    static func printList(_ processes: [ProcessRecord]) {
        print("PID\tPPID\tUID\tTHREADS\tRSS\tNAME")
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            print("\(process.pid)\t\(process.parentPID)\t\(process.userID)\t\(process.threadCount)\t\(process.residentSize)\t\(process.name)")
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func detailCount(_ detail: ProcessDetailSnapshot) -> Int {
        switch detail.kind {
        case .summary: detail.process == nil ? 0 : 1
        case .threads: detail.threads.count
        case .files: detail.files.count
        case .ports: detail.ports.count
        case .modules: detail.modules.count
        }
    }

    static func watch(
        _ session: ProcessDataSession,
        count: Int,
        interval: UInt64
    ) async throws {
        _ = try await session.sample()
        for sample in 1...count {
            try await Task.sleep(nanoseconds: interval)
            let update = try await session.sample()
            print("sample \(sample): \(update.snapshot.processes.count) processes, +\(update.started.count)/-\(update.exited.count)")
            print("   PID     CPU%          RSS    FOOTPRINT NAME")
            for item in update.intervals.sorted(by: { $0.cpuCoreFraction > $1.cpuCoreFraction }).prefix(15) {
                print(String(
                    format: "%6d %7.2f%% %12llu %12llu %@",
                    item.process.pid,
                    item.cpuCoreFraction * 100,
                    item.process.residentSize,
                    item.process.physicalFootprint,
                    item.process.name
                ))
            }
        }
    }

    static func send(
        _ signal: InspectorSignal,
        to pid: Int32,
        session: ProcessDataSession
    ) async throws {
        let snapshot = try await session.sample(collectors: .all).snapshot
        guard let process = snapshot.processes.first(where: { $0.pid == pid }) else {
            throw CommandFailure("process \(pid) was not found")
        }
        let ticket = try await session.prepareSignal(signal, for: process.identity)
        try await session.commitSignal(ticket: ticket)
        print("sent \(signal == .terminate ? "SIGTERM" : "SIGKILL") to \(pid) (\(process.name))")
    }
}

struct CommandFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
