import Darwin
import Dispatch
import Foundation

enum ProcessSamplerError: Error {
    case failed
}

final class ProcessSampler {
    private static let maximumProcessCount = 2_048

    func snapshot(
        collectors: ProcessCollectorMask,
        generation: UInt64,
        network: [Int32: NetworkUsage]? = nil
    ) throws -> ProcessSnapshot {
        let pids = try listAllPIDs()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        // Pass 1: CPU-bearing counters only, in a tight loop, with the sample
        // timestamp taken alongside. The reducer divides per-process CPU deltas
        // by the timestamp delta, so these reads must share one instant; the
        // slow metadata walk below would otherwise skew every fraction.
        let sampleUptime = DispatchTime.now().uptimeNanoseconds
        var usages = [(pid: Int32, usage: rusage_info_v4?)]()
        usages.reserveCapacity(pids.count)
        for pid in pids {
            usages.append((pid, resourceUsage(for: pid)))
        }

        // Pass 2: everything that is expensive or timing-insensitive.
        var processes = [ProcessRecord]()
        processes.reserveCapacity(usages.count)
        for (pid, usage) in usages {
            autoreleasepool {
                if var record = record(for: pid, usage: usage, collectors: collectors) {
                    if let network {
                        let usage = network[pid] ?? NetworkUsage()
                        record.networkBytesReceived = usage.bytesReceived
                        record.networkBytesSent = usage.bytesSent
                        record.networkPacketsReceived = usage.packetsReceived
                        record.networkPacketsSent = usage.packetsSent
                        record.availability.insert(.network)
                    }
                    processes.append(record)
                }
            }
        }

        return ProcessSnapshot(
            generation: generation,
            sampleUptimeNanoseconds: sampleUptime,
            machTimebaseNumerator: timebase.numer,
            machTimebaseDenominator: timebase.denom,
            processes: processes,
            system: systemRecord(processes: processes)
        )
    }

    func record(
        for identity: ProcessIdentity,
        collectors: ProcessCollectorMask
    ) -> ProcessRecord? {
        guard isCurrent(identity) else { return nil }
        return record(for: identity.pid, collectors: collectors)
    }

    func isCurrent(_ identity: ProcessIdentity) -> Bool {
        if let startTime = startTime(for: identity.pid) {
            return startTime == identity.startTime
        }
        return identity.pid == 0 && identity.startTime == 0
    }

    func startTime(for pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            inspectorProcPIDResourceUsage(
                pid,
                PrivateSystemConstant.resourceUsageV4,
                UnsafeMutableRawPointer($0)
            )
        }
        guard result == 0, usage.ri_proc_start_abstime != 0 else { return nil }
        return usage.ri_proc_start_abstime
    }

    private func listAllPIDs() throws -> [Int32] {
        let reportedCount = Int(inspectorProcListAllPIDs(nil, 0))
        guard reportedCount > 0 else {
            throw ProcessSamplerError.failed
        }
        guard reportedCount <= Self.maximumProcessCount else {
            throw ProcessSamplerError.failed
        }

        let capacity = min(reportedCount + 64, Self.maximumProcessCount)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress,
                  bytes.count <= Int(Int32.max) else { return -1 }
            return Int(inspectorProcListAllPIDs(baseAddress, Int32(bytes.count)))
        }
        guard count >= 0, count <= capacity else {
            throw ProcessSamplerError.failed
        }
        pids.removeSubrange(count..<pids.count)
        if !pids.contains(0) {
            guard pids.count < Self.maximumProcessCount else { throw ProcessSamplerError.failed }
            pids.insert(0, at: 0)
        }
        return pids
    }

    private func record(
        for pid: Int32,
        collectors: ProcessCollectorMask
    ) -> ProcessRecord? {
        record(for: pid, usage: resourceUsage(for: pid), collectors: collectors)
    }

    private func record(
        for pid: Int32,
        usage: rusage_info_v4?,
        collectors: ProcessCollectorMask
    ) -> ProcessRecord? {
        var process = ProcessRecord(pid: pid)
        if let usage {
            process.startTime = usage.ri_proc_start_abstime
            process.userTime = usage.ri_user_time
            process.systemTime = usage.ri_system_time
            process.packageIdleWakeups = usage.ri_pkg_idle_wkups
            process.interruptWakeups = usage.ri_interrupt_wkups
            process.pageIns = usage.ri_pageins
            process.wiredSize = usage.ri_wired_size
            process.residentSize = usage.ri_resident_size
            process.physicalFootprint = usage.ri_phys_footprint
            process.diskBytesRead = usage.ri_diskio_bytesread
            process.diskBytesWritten = usage.ri_diskio_byteswritten
            process.availability.insert(.resourceUsage)
        } else if pid != 0 {
            return nil
        }

        if let rawInfo = taskAllInfo(for: pid) {
            rawInfo.withUnsafeBytes { bytes in
                populateBSDInfo(from: bytes, into: &process)
                if collectors.contains(.taskCounters) {
                    populateTaskInfo(from: bytes, into: &process)
                }
            }
        } else {
            process.name = processName(for: pid)
        }
        if pid == 0, process.name.isEmpty { process.name = "kernel_task" }

        if collectors.contains(.fileDescriptors), process.availability.contains(.bsd) {
            if let counts = descriptorCounts(for: pid) {
                process.fileDescriptorCount = counts.files
                process.socketCount = counts.sockets
                process.availability.insert(.fileDescriptors)
            }
        } else {
            process.fileDescriptorCount = 0
        }

        if collectors.contains(.executablePaths), let path = executablePath(for: pid) {
            process.executablePath = path
            process.availability.insert(.executablePath)
        }

        if collectors.contains(.commandLines), let arguments = commandLine(for: pid) {
            process.arguments = arguments
            process.availability.insert(.commandLine)
        }

        if collectors.contains(.ports), let count = portCount(for: pid) {
            process.portCount = count
            process.availability.insert(.ports)
        }

        if collectors.contains(.sandbox), let sandbox = sandboxStatus(for: pid) {
            process.sandboxStatus = sandbox
            process.availability.insert(.sandbox)
        }

        if collectors.contains(.taskMetadata) {
            populateTaskMetadata(pid: pid, process: &process)
        }

        return pid != 0 && process.startTime == 0 ? nil : process
    }

    private func resourceUsage(for pid: Int32) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            inspectorProcPIDResourceUsage(
                pid,
                PrivateSystemConstant.resourceUsageV4,
                UnsafeMutableRawPointer($0)
            )
        }
        return result == 0 ? usage : nil
    }

    private func taskAllInfo(for pid: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: PrivateSystemConstant.processTaskAllInfoSize)
        let result = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            inspectorProcPIDInfo(
                pid,
                PrivateSystemConstant.processTaskAllInfo,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        return result == bytes.count ? bytes : nil
    }

    private func populateBSDInfo(
        from bytes: UnsafeRawBufferPointer,
        into process: inout ProcessRecord
    ) {
        guard bytes.count >= PrivateSystemConstant.bsdInfoSize,
              let flags = bytes.inspectorLoad(UInt32.self, at: 0),
              let status = bytes.inspectorLoad(UInt32.self, at: 4),
              let parentPID = bytes.inspectorLoad(UInt32.self, at: 16),
              let userID = bytes.inspectorLoad(UInt32.self, at: 20),
              let groupID = bytes.inspectorLoad(UInt32.self, at: 24),
              let fileCount = bytes.inspectorLoad(UInt32.self, at: 96),
              let nice = bytes.inspectorLoad(Int32.self, at: 116) else { return }

        process.flags = flags
        process.status = status
        process.parentPID = Int32(bitPattern: parentPID)
        process.userID = userID
        process.groupID = groupID
        process.fileDescriptorCount = fileCount
        let registeredName = bytes.inspectorCString(at: 64, capacity: 32)
        process.name = registeredName.isEmpty
            ? bytes.inspectorCString(at: 48, capacity: 16)
            : registeredName
        process.nice = nice
        process.terminalDevice = bytes.inspectorLoad(UInt32.self, at: 108) ?? 0
        process.availability.insert(.bsd)
    }

    private func populateTaskInfo(
        from bytes: UnsafeRawBufferPointer,
        into process: inout ProcessRecord
    ) {
        let base = PrivateSystemConstant.bsdInfoSize
        guard bytes.count >= PrivateSystemConstant.processTaskAllInfoSize,
              let virtualSize = bytes.inspectorLoad(UInt64.self, at: base),
              let residentSize = bytes.inspectorLoad(UInt64.self, at: base + 8),
              let faults = bytes.inspectorLoad(Int32.self, at: base + 52),
              let copyOnWriteFaults = bytes.inspectorLoad(Int32.self, at: base + 60),
              let messagesSent = bytes.inspectorLoad(Int32.self, at: base + 64),
              let messagesReceived = bytes.inspectorLoad(Int32.self, at: base + 68),
              let machCalls = bytes.inspectorLoad(Int32.self, at: base + 72),
              let unixCalls = bytes.inspectorLoad(Int32.self, at: base + 76),
              let contextSwitches = bytes.inspectorLoad(Int32.self, at: base + 80),
              let threadCount = bytes.inspectorLoad(Int32.self, at: base + 84),
              let runningCount = bytes.inspectorLoad(Int32.self, at: base + 88),
              let priority = bytes.inspectorLoad(Int32.self, at: base + 92) else { return }

        process.virtualSize = virtualSize
        if process.residentSize == 0 {
            process.residentSize = residentSize
        }
        process.faults = nonnegative(faults)
        process.copyOnWriteFaults = nonnegative(copyOnWriteFaults)
        process.messagesSent = nonnegative(messagesSent)
        process.messagesReceived = nonnegative(messagesReceived)
        process.machSystemCalls = nonnegative(machCalls)
        process.unixSystemCalls = nonnegative(unixCalls)
        process.contextSwitches = nonnegative(contextSwitches)
        process.threadCount = UInt32(clamping: threadCount)
        process.runningThreadCount = UInt32(clamping: runningCount)
        process.priority = priority
        process.availability.insert(.task)
    }

    private func processName(for pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return inspectorProcName(pid, baseAddress, UInt32(bytes.count))
        }
        guard count > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    }

    private func executablePath(for pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return inspectorProcPIDPath(pid, baseAddress, UInt32(bytes.count))
        }
        guard count > 0, count <= buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    }

    private func descriptorCounts(for pid: Int32) -> (files: UInt32, sockets: UInt32)? {
        let required = Int(inspectorProcPIDInfo(
            pid,
            PrivateSystemConstant.processListFileDescriptors,
            0,
            nil,
            0
        ))
        guard required > 0, required <= 32_768 else { return nil }
        var bytes = [UInt8](repeating: 0, count: required)
        let count = bytes.withUnsafeMutableBytes {
            inspectorProcPIDInfo(
                pid,
                PrivateSystemConstant.processListFileDescriptors,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard count > 0, count <= bytes.count else { return nil }

        var files: UInt32 = 0
        var sockets: UInt32 = 0
        for offset in stride(from: 0, to: Int(count) - 7, by: 8) {
            guard let type = bytes.withUnsafeBytes({ $0.inspectorLoad(UInt32.self, at: offset + 4) }) else {
                continue
            }
            if type == FileDescriptorKind.socket.rawValue { sockets &+= 1 }
            if FileDescriptorKind(rawValue: type) != nil { files &+= 1 }
        }
        return (files, sockets)
    }

    private func portCount(for pid: Int32) -> UInt32? {
        var bytes = [UInt8](repeating: 0, count: 8)
        let count = bytes.withUnsafeMutableBytes {
            inspectorProcPIDInfo(
                pid,
                PrivateSystemConstant.processIPCTableInfo,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard count == bytes.count else { return nil }
        return bytes.withUnsafeBytes { buffer in
            guard let size = buffer.inspectorLoad(UInt32.self, at: 0),
                  let free = buffer.inspectorLoad(UInt32.self, at: 4),
                  size >= free else { return nil }
            return size - free
        }
    }

    private func commandLine(for pid: Int32) -> [String]? {
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var size = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), nil, &size, nil, 0)
        }
        guard sizeResult == 0,
              size > MemoryLayout<Int32>.size,
              size <= 65_536 else { return nil }

        var bytes = [UInt8](repeating: 0, count: size)
        let readResult = mib.withUnsafeMutableBufferPointer { mib in
            bytes.withUnsafeMutableBytes {
                sysctl(mib.baseAddress, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
            }
        }
        guard readResult == 0 else { return nil }
        let argumentCount = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount >= 0, argumentCount <= 128 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var arguments = [String]()
        arguments.reserveCapacity(Int(argumentCount))
        while index < size, arguments.count < Int(argumentCount) {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            while index < size, bytes[index] == 0 { index += 1 }
        }
        return arguments
    }

    private func sandboxStatus(for pid: Int32) -> ProcessSandboxStatus? {
        guard pid != 0, let check = Self.sandboxCheck else {
            return pid == 0 ? .unrestricted : nil
        }
        let result = check(pid, nil, 0)
        return result < 0 ? nil : result == 0 ? .unrestricted : .sandboxed
    }

    private func populateTaskMetadata(pid: Int32, process: inout ProcessRecord) {
        if let priority = basePriority(for: pid) { process.basePriority = priority }
        guard let task = PrivateSystem.readTask(pid) else { return }
        defer { mach_port_deallocate(mach_task_self_, task) }
        process.availability.insert(.taskMetadata)

        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        if withUnsafeMutablePointer(to: &basic, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(task, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }) == KERN_SUCCESS {
            process.maximumResidentSize = basic.resident_size_max
        }

        var role: integer_t = 0
        var roleCount: mach_msg_type_number_t = 1
        var getDefault = boolean_t(0)
        if task_policy_get(
            task,
            task_policy_flavor_t(TASK_CATEGORY_POLICY),
            &role,
            &roleCount,
            &getDefault
        ) == KERN_SUCCESS {
            process.taskRole = UInt32(bitPattern: role)
        }

        var power = task_power_info_data_t()
        var powerCount = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        if withUnsafeMutablePointer(to: &power, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(task, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
            }
        }) == KERN_SUCCESS {
            process.timerWakeups = adding(
                power.task_timer_wakeups_bin_1,
                power.task_timer_wakeups_bin_2
            )
        }
    }

    private func basePriority(for pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_PID), pid]
        let result = mib.withUnsafeMutableBufferPointer { mib in
            withUnsafeMutablePointer(to: &info) {
                sysctl(mib.baseAddress, UInt32(mib.count), $0, &size, nil, 0)
            }
        }
        guard result == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        return Int32(info.kp_proc.p_priority)
    }

    private func systemRecord(processes: [ProcessRecord]) -> SystemRecord {
        var record = SystemRecord(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            activeProcessorCount: UInt32(clamping: ProcessInfo.processInfo.activeProcessorCount)
        )
        for process in processes {
            record.totalThreadCount = adding(record.totalThreadCount, UInt64(process.threadCount))
            record.totalUserTime = adding(record.totalUserTime, process.userTime)
            record.totalSystemTime = adding(record.totalSystemTime, process.systemTime)
        }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let (freeMemory, overflow) = UInt64(statistics.free_count)
                .multipliedReportingOverflow(by: UInt64(vm_kernel_page_size))
            record.freeMemory = overflow ? UInt64.max : freeMemory
        }
        return record
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func nonnegative(_ value: Int32) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }

    private typealias SandboxCheck = @convention(c) (
        Int32,
        UnsafePointer<CChar>?,
        Int32
    ) -> Int32

    private static let sandboxCheck: SandboxCheck? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "sandbox_check") else { return nil }
        return unsafeBitCast(symbol, to: SandboxCheck.self)
    }()
}
