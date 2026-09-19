#if targetEnvironment(simulator)
import Foundation

// The simulator has no inspector daemon to talk to. This stands in for it with
// made-up processes whose numbers move, so every screen can be exercised from
// Xcode. The whole file compiles to nothing in a device build.
struct SimulatorProcessSource {
    private var generation: UInt64 = 0
    // CPU time only ever accumulates; the reducer turns the growth between
    // two samples into a percentage.
    private var userTimes: [Int32: UInt64] = [:]
    private var lastUptime = DispatchTime.now().uptimeNanoseconds

    private static let names = [
        "launchd", "SpringBoard", "backboardd", "mediaserverd", "locationd", "Inspector",
        "MobileSafari", "MobileMail", "Preferences", "cfprefsd", "logd", "notifyd",
        "configd", "wifid", "bluetoothd", "apsd", "nsurlsessiond", "kbd",
    ]

    mutating func snapshot() -> ProcessSnapshot {
        generation += 1
        let tick = generation
        let uptime = DispatchTime.now().uptimeNanoseconds
        let elapsed = uptime - lastUptime
        lastUptime = uptime
        var userTimes = userTimes
        let processes = Self.names.enumerated().map { index, name -> ProcessRecord in
            let pid = Int32(index == 0 ? 1 : 100 + index * 7)
            let isApp = name.first?.isUppercase == true && name != "SpringBoard"
            var record = ProcessRecord(pid: pid)
            record.parentPID = index == 0 ? 0 : 1
            record.userID = isApp ? 501 : 0
            record.threadCount = UInt32(3 + index % 9)
            record.runningThreadCount = UInt32(index % 2)
            record.priority = 31
            record.basePriority = 31
            record.fileDescriptorCount = UInt32(12 + index * 3)
            record.socketCount = UInt32(index % 4)
            record.portCount = UInt32(80 + index * 11)
            record.availability = [.bsd, .task, .fileDescriptors, .ports, .executablePath, .network]
            record.sandboxStatus = isApp ? .sandboxed : .unrestricted
            record.startTime = UInt64(index + 1) * 1_000
            // Busy in a pattern rather than at random, so a sort by CPU keeps
            // reshuffling the way a real device does: 10–40% of a core while
            // busy, next to nothing otherwise.
            let isBusy = (tick + UInt64(index)) % UInt64(3 + index % 5) == 0
            let spent = isBusy ? elapsed / 10 * UInt64(index % 4 + 1) : elapsed / 1_000
            userTimes[pid, default: 0] += spent
            record.userTime = userTimes[pid, default: 0]
            record.residentSize = UInt64(8 + index * 6) << 20
            record.physicalFootprint = UInt64(5 + index * 4) << 20 + (tick % 7) << 16
            record.virtualSize = 400 << 30
            record.diskBytesRead = tick << 14
            record.diskBytesWritten = tick << 12
            record.networkBytesReceived = tick << 10
            record.networkBytesSent = tick << 8
            record.name = name
            record.executablePath = isApp
                ? "/Applications/\(name).app/\(name)"
                : "/usr/libexec/\(name)"
            record.arguments = [record.executablePath]
            return record
        }
        self.userTimes = userTimes
        var system = SystemRecord()
        system.physicalMemory = 8 << 30
        system.freeMemory = 3 << 30
        system.activeProcessorCount = 6
        system.totalThreadCount = processes.reduce(0) { $0 + UInt64($1.threadCount) }
        return ProcessSnapshot(
            generation: generation,
            sampleUptimeNanoseconds: uptime,
            machTimebaseNumerator: 1,
            machTimebaseDenominator: 1,
            processes: processes,
            system: system
        )
    }

    func details(_ kind: ProcessDetailKind, for identity: ProcessIdentity) -> ProcessDetailSnapshot {
        var result = ProcessDetailSnapshot(
            identity: identity,
            kind: kind,
            status: .available,
            errorCode: 0
        )
        switch kind {
        case .summary:
            var copy = self
            result.process = copy.snapshot().processes.first { $0.pid == identity.pid }
            result.bundle = BundleMetadata(
                identifier: "com.example.simulated",
                name: "Simulated",
                displayName: "Simulated",
                version: "1.0",
                minimumOSVersion: "13.0",
                SDKName: "iphoneos",
                platformVersion: "",
                compiler: ""
            )
        case .threads:
            result.threads = (0..<8).map { (index: Int) -> ThreadRecord in
                let name = index == 0 ? "com.apple.main-thread" : ""
                return ThreadRecord(
                    id: UInt64(0x1a00 + index),
                    userTime: 0,
                    systemTime: 0,
                    cpuUsage: Int32(index * 37 % 200),
                    policy: 1,
                    runState: Int32(index % 3 + 1),
                    flags: 0,
                    sleepTime: Int32(index),
                    currentPriority: Int32(31 + index),
                    basePriority: 31,
                    maximumPriority: 63,
                    name: name
                )
            }
        case .files:
            result.files = (0..<24).map { (index: Int) -> FileDescriptorRecord in
                var file = FileDescriptorRecord(
                    descriptor: Int32(index),
                    kind: index % 5 == 4 ? .socket : .vnode
                )
                file.path = index % 5 == 4
                    ? ""
                    : "/private/var/mobile/Library/Caches/com.example.simulated/store-\(index).sqlite"
                file.localAddress = index % 5 == 4 ? "127.0.0.1:\(5000 + index)" : ""
                file.detail = index % 5 == 4 ? "tcp4" : ""
                return file
            }
        case .ports:
            result.ports = (0..<40).map { (index: Int) -> MachPortRecord in
                let rights: UInt32 = index % 3 == 0 ? 0x20000 : 0x10000
                return MachPortRecord(
                    name: UInt32(0x103 + index * 0x100),
                    rights: rights,
                    userReferences: UInt32(1 + index % 5),
                    object: UInt32(0x4000 + index),
                    objectType: 0,
                    setMembers: []
                )
            }
        case .modules:
            result.modules = ["dyld", "libSystem.B.dylib", "Foundation", "UIKitCore", "CoreFoundation"]
                .enumerated().map { (index: Int, name: String) -> ModuleRecord in
                    ModuleRecord(
                        path: "/usr/lib/\(name)",
                        identifier: "",
                        address: 0x1_8000_0000 + UInt64(index) << 24,
                        size: UInt64(index + 1) << 20,
                        referenceCount: 1
                    )
                }
        }
        return result
    }
}
#endif
