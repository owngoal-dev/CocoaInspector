import Foundation

@main
enum DataLayerHarness {
    static func main() throws {
        try testSnapshotRoundTrip()
        try testDetailRoundTrip()
        try testMalformedSnapshotRejection()
        try testMessageSizeLimit()
        testSnapshotReduction()
        print("Inspector data-layer harness passed")
    }

    private static func testSnapshotRoundTrip() throws {
        var process = ProcessRecord(pid: 42)
        process.parentPID = 1
        process.userID = 501
        process.groupID = 501
        process.status = 2
        process.flags = 0x10
        process.nice = -4
        process.threadCount = 7
        process.runningThreadCount = 2
        process.priority = 31
        process.basePriority = 27
        process.terminalDevice = 3
        process.taskRole = 1
        process.fileDescriptorCount = 12
        process.socketCount = 4
        process.portCount = 18
        process.availability = [
            .bsd,
            .task,
            .resourceUsage,
            .fileDescriptors,
            .executablePath,
            .commandLine,
            .ports,
            .sandbox,
            .network,
            .taskMetadata,
        ]
        process.sandboxStatus = .sandboxed
        process.startTime = 1_000
        process.userTime = 2_000
        process.systemTime = 3_000
        process.packageIdleWakeups = 4
        process.interruptWakeups = 5
        process.timerWakeups = 6
        process.pageIns = 7
        process.wiredSize = 8
        process.residentSize = 9
        process.physicalFootprint = 10
        process.maximumResidentSize = 11
        process.virtualSize = 12
        process.diskBytesRead = 13
        process.diskBytesWritten = 14
        process.faults = 15
        process.copyOnWriteFaults = 16
        process.messagesSent = 17
        process.messagesReceived = 18
        process.machSystemCalls = 19
        process.unixSystemCalls = 20
        process.contextSwitches = 21
        process.networkBytesReceived = 22
        process.networkBytesSent = 23
        process.networkPacketsReceived = 24
        process.networkPacketsSent = 25
        process.name = "测试进程"
        process.executablePath = "/Applications/Inspector.app/Inspector"
        process.arguments = ["Inspector", "--example"]

        let snapshot = ProcessSnapshot(
            generation: 9,
            sampleUptimeNanoseconds: 100,
            machTimebaseNumerator: 125,
            machTimebaseDenominator: 3,
            processes: [process],
            system: SystemRecord(
                physicalMemory: 100,
                freeMemory: 20,
                activeProcessorCount: 6,
                totalThreadCount: 7,
                totalUserTime: 8,
                totalSystemTime: 9,
                networkStatus: .available,
                networkErrorCode: 0
            )
        )
        let encoded = try SnapshotWireCodec.encode(snapshot)
        let decoded = try SnapshotWireCodec.decode(encoded)
        expect(decoded == snapshot, "snapshot codec must preserve every field")
    }

    private static func testDetailRoundTrip() throws {
        let identity = ProcessIdentity(pid: 42, startTime: 1_000)
        let detail = ProcessDetailSnapshot(
            identity: identity,
            kind: .modules,
            status: .partial,
            errorCode: 5,
            process: ProcessRecord(pid: identity.pid),
            threads: [ThreadRecord(
                id: 1,
                userTime: 2,
                systemTime: 3,
                cpuUsage: 4,
                policy: 5,
                runState: 6,
                flags: 7,
                sleepTime: 8,
                currentPriority: 9,
                basePriority: 10,
                maximumPriority: 11,
                name: "worker"
            )],
            files: [FileDescriptorRecord(
                descriptor: 3,
                kind: .socket,
                openFlags: 4,
                status: 5,
                object: 6,
                peer: 7,
                path: "/tmp/socket",
                localAddress: "127.0.0.1:1",
                remoteAddress: "127.0.0.1:2",
                detail: "TCP"
            )],
            ports: [MachPortRecord(
                name: 1,
                rights: 2,
                userReferences: 3,
                object: 4,
                objectType: 5,
                setMembers: [6]
            )],
            modules: [ModuleRecord(
                path: "/usr/lib/libSystem.B.dylib",
                identifier: "libSystem",
                address: 7,
                size: 8,
                referenceCount: 9
            )],
            bundle: BundleMetadata(
                identifier: "wiki.qaq.Inspector",
                name: "Inspector",
                displayName: "CCPI",
                version: "1",
                minimumOSVersion: "17.0",
                SDKName: "iphoneos",
                platformVersion: "17.0",
                compiler: "com.apple.compilers.llvm.clang.1_0"
            )
        )
        let encoded = try SnapshotWireCodec.encode(detail)
        let decoded = try SnapshotWireCodec.decode(encoded, as: ProcessDetailSnapshot.self)
        expect(decoded == detail, "detail codec must preserve every endpoint field")
    }

    private static func testMalformedSnapshotRejection() throws {
        let snapshot = ProcessSnapshot(
            generation: 1,
            sampleUptimeNanoseconds: 1,
            machTimebaseNumerator: 1,
            machTimebaseDenominator: 1,
            processes: [ProcessRecord(pid: 1)]
        )
        var encoded = try SnapshotWireCodec.encode(snapshot)
        encoded.removeLast()
        do {
            _ = try SnapshotWireCodec.decode(encoded)
            expect(false, "truncated snapshots must be rejected")
        } catch {
            return
        }
    }

    private static func testMessageSizeLimit() throws {
        let oversized = Data(count: InspectorProtocol.maximumMessageDataByteCount + 1)
        do {
            _ = try SnapshotWireCodec.decode(oversized)
            expect(false, "oversized replies must be rejected before decoding")
        } catch SnapshotWireCodec.CodecError.invalidSize {
        }

        let value = String(
            repeating: "x",
            count: InspectorProtocol.maximumMessageDataByteCount
        )
        do {
            _ = try SnapshotWireCodec.encode([value])
            expect(false, "oversized replies must not be encoded")
        } catch SnapshotWireCodec.CodecError.invalidSize {
        }
    }

    private static func testSnapshotReduction() {
        var reducer = ProcessSnapshotReducer()
        var firstProcess = ProcessRecord(pid: 7)
        firstProcess.startTime = 10
        firstProcess.userTime = 100
        firstProcess.systemTime = 50
        firstProcess.diskBytesRead = 1_000
        firstProcess.timerWakeups = 10
        firstProcess.networkBytesReceived = 500

        let first = ProcessSnapshot(
            generation: 1,
            sampleUptimeNanoseconds: 1_000,
            machTimebaseNumerator: 2,
            machTimebaseDenominator: 1,
            processes: [firstProcess]
        )
        let initial = reducer.consume(first)
        expect(initial.started == [firstProcess.identity], "first frame reports existing processes as started")
        expect(initial.intervals.isEmpty, "first frame has no deltas")

        var secondProcess = firstProcess
        secondProcess.userTime = 140
        secondProcess.systemTime = 60
        secondProcess.diskBytesRead = 1_250
        secondProcess.timerWakeups = 13
        secondProcess.networkBytesReceived = 560
        var addedProcess = ProcessRecord(pid: 8)
        addedProcess.startTime = 11
        let second = ProcessSnapshot(
            generation: 2,
            sampleUptimeNanoseconds: 1_500,
            machTimebaseNumerator: 2,
            machTimebaseDenominator: 1,
            processes: [secondProcess, addedProcess]
        )
        let update = reducer.consume(second)
        expect(update.intervals.count == 1, "only stable process identities receive deltas")
        expect(update.intervals[0].cpuTimeNanoseconds == 100, "Mach timebase is applied to CPU deltas")
        expect(update.intervals[0].diskBytesRead == 250, "monotonic counters are differenced")
        expect(update.intervals[0].timerWakeups == 3, "timer wakeups are differenced")
        expect(update.intervals[0].networkBytesReceived == 60, "network counters are differenced")
        expect(update.started == [addedProcess.identity], "new identities are reported")
        expect(update.exited.isEmpty, "live identities are not reported as exited")

        var reusedPID = ProcessRecord(pid: 7)
        reusedPID.startTime = 99
        let third = ProcessSnapshot(
            generation: 3,
            sampleUptimeNanoseconds: 2_000,
            machTimebaseNumerator: 2,
            machTimebaseDenominator: 1,
            processes: [reusedPID, addedProcess]
        )
        let reuseUpdate = reducer.consume(third)
        expect(reuseUpdate.started.contains(reusedPID.identity), "PID reuse is a new process identity")
        expect(reuseUpdate.exited.contains(secondProcess.identity), "the old PID identity exits")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("DataLayerHarness failure: \(message)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
