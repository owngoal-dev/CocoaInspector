import Darwin
import Foundation
import MachO

final class DetailSampler {
    private static let maximumThreads = 4_096
    private static let maximumFileDescriptors = 4_096
    private static let maximumPorts = 8_192
    private static let maximumRegions = 16_384
    private static let maximumModules = 2_048
    private static let maximumPropertyListBytes = 1_024 * 1_024
    private static let maximumLoadCommandBytes: UInt32 = 32_768

    private let processes: ProcessSampler

    init(processes: ProcessSampler) {
        self.processes = processes
    }

    func snapshot(
        kind: ProcessDetailKind,
        identity: ProcessIdentity
    ) -> ProcessDetailSnapshot {
        guard processes.isCurrent(identity) else {
            return failure(kind, identity, ESRCH)
        }

        switch kind {
        case .summary:
            guard let process = processes.record(for: identity, collectors: .all) else {
                return failure(kind, identity, ESRCH)
            }
            return ProcessDetailSnapshot(
                identity: identity,
                kind: kind,
                status: .available,
                errorCode: 0,
                process: process,
                bundle: bundleMetadata(for: process.executablePath)
            )
        case .threads:
            guard let records = threads(for: identity.pid) else {
                return failure(kind, identity, errno)
            }
            return ProcessDetailSnapshot(
                identity: identity,
                kind: kind,
                status: .available,
                errorCode: 0,
                process: nil,
                threads: records
            )
        case .files:
            guard let records = files(for: identity.pid) else {
                return failure(kind, identity, errno)
            }
            return ProcessDetailSnapshot(
                identity: identity,
                kind: kind,
                status: .available,
                errorCode: 0,
                process: nil,
                files: records
            )
        case .ports:
            guard let records = ports(for: identity.pid) else {
                return failure(kind, identity, errno)
            }
            return ProcessDetailSnapshot(
                identity: identity,
                kind: kind,
                status: .available,
                errorCode: 0,
                process: nil,
                ports: records
            )
        case .modules:
            guard let result = modules(for: identity.pid) else {
                return failure(kind, identity, errno)
            }
            return ProcessDetailSnapshot(
                identity: identity,
                kind: kind,
                status: result.status,
                errorCode: 0,
                process: nil,
                modules: result.records
            )
        }
    }

    private func threads(for pid: Int32) -> [ThreadRecord]? {
        var identifiers = [UInt64](repeating: 0, count: Self.maximumThreads)
        let bytes = identifiers.withUnsafeMutableBytes {
            inspectorProcPIDInfo(
                pid,
                PrivateSystemConstant.processListThreadIDs,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        let flavor: Int32
        let result: Int32
        if bytes > 0 {
            flavor = PrivateSystemConstant.processThreadID64Info
            result = bytes
        } else {
            result = identifiers.withUnsafeMutableBytes {
                inspectorProcPIDInfo(
                    pid,
                    PrivateSystemConstant.processListThreads,
                    0,
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            flavor = PrivateSystemConstant.processThreadInfo
        }
        guard result > 0, result <= identifiers.count * MemoryLayout<UInt64>.size else {
            if errno == 0 { errno = ESRCH }
            return nil
        }

        var records = [ThreadRecord]()
        records.reserveCapacity(Int(result) / MemoryLayout<UInt64>.size)
        for id in identifiers.prefix(Int(result) / MemoryLayout<UInt64>.size) where id != 0 {
            autoreleasepool {
                var info = [UInt8](repeating: 0, count: 112)
                let count = info.withUnsafeMutableBytes {
                    inspectorProcPIDInfo(pid, flavor, id, $0.baseAddress, Int32($0.count))
                }
                guard count == info.count else { return }
                info.withUnsafeBytes { bytes in
                    guard let user = bytes.inspectorLoad(UInt64.self, at: 0),
                          let system = bytes.inspectorLoad(UInt64.self, at: 8),
                          let cpu = bytes.inspectorLoad(Int32.self, at: 16),
                          let policy = bytes.inspectorLoad(Int32.self, at: 20),
                          let state = bytes.inspectorLoad(Int32.self, at: 24),
                          let flags = bytes.inspectorLoad(Int32.self, at: 28),
                          let sleep = bytes.inspectorLoad(Int32.self, at: 32),
                          let current = bytes.inspectorLoad(Int32.self, at: 36),
                          let base = bytes.inspectorLoad(Int32.self, at: 40),
                          let maximum = bytes.inspectorLoad(Int32.self, at: 44) else { return }
                    records.append(ThreadRecord(
                        id: id,
                        userTime: user,
                        systemTime: system,
                        cpuUsage: cpu,
                        policy: policy,
                        runState: state,
                        flags: flags,
                        sleepTime: sleep,
                        currentPriority: current,
                        basePriority: base,
                        maximumPriority: maximum,
                        name: bytes.inspectorCString(at: 48, capacity: 64)
                    ))
                }
            }
        }
        return records
    }

    private func files(for pid: Int32) -> [FileDescriptorRecord]? {
        let required = Int(inspectorProcPIDInfo(
            pid,
            PrivateSystemConstant.processListFileDescriptors,
            0,
            nil,
            0
        ))
        guard required > 0, required <= Self.maximumFileDescriptors * 8 else {
            if errno == 0 { errno = required > 0 ? ENOSPC : ESRCH }
            return nil
        }
        let capacity = min(required * 2, Self.maximumFileDescriptors * 8)
        var descriptors = [UInt8](repeating: 0, count: capacity)
        let bytes = descriptors.withUnsafeMutableBytes {
            inspectorProcPIDInfo(
                pid,
                PrivateSystemConstant.processListFileDescriptors,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard bytes > 0, bytes <= descriptors.count else {
            if errno == 0 { errno = ESRCH }
            return nil
        }

        var records = [FileDescriptorRecord]()
        records.reserveCapacity(Int(bytes) / 8)
        for offset in stride(from: 0, to: Int(bytes) - 7, by: 8) {
            autoreleasepool {
                descriptors.withUnsafeBytes { list in
                    guard let descriptor = list.inspectorLoad(Int32.self, at: offset),
                          let rawKind = list.inspectorLoad(UInt32.self, at: offset + 4),
                          let kind = FileDescriptorKind(rawValue: rawKind),
                          let record = file(pid: pid, descriptor: descriptor, kind: kind) else { return }
                    records.append(record)
                }
            }
        }
        return records
    }

    private func file(
        pid: Int32,
        descriptor: Int32,
        kind: FileDescriptorKind
    ) -> FileDescriptorRecord? {
        let flavor: Int32
        let size: Int
        switch kind {
        case .vnode:
            flavor = PrivateSystemConstant.fileDescriptorVnodePathInfo
            size = 1_200
        case .socket:
            flavor = PrivateSystemConstant.fileDescriptorSocketInfo
            size = 792
        case .pipe:
            flavor = PrivateSystemConstant.fileDescriptorPipeInfo
            size = 184
        case .kqueue:
            flavor = PrivateSystemConstant.fileDescriptorKqueueInfo
            size = 168
        }
        var info = [UInt8](repeating: 0, count: size)
        let count = info.withUnsafeMutableBytes {
            inspectorProcPIDFDInfo(pid, descriptor, flavor, $0.baseAddress, Int32($0.count))
        }
        guard count == info.count else { return nil }

        return info.withUnsafeBytes { bytes in
            var record = FileDescriptorRecord(descriptor: descriptor, kind: kind)
            record.openFlags = bytes.inspectorLoad(UInt32.self, at: 0) ?? 0
            switch kind {
            case .vnode:
                record.object = bytes.inspectorLoad(UInt64.self, at: 32) ?? 0
                record.path = bytes.inspectorCString(at: 176, capacity: 1_024)
            case .pipe:
                record.object = bytes.inspectorLoad(UInt64.self, at: 160) ?? 0
                record.peer = bytes.inspectorLoad(UInt64.self, at: 168) ?? 0
                record.status = bytes.inspectorLoad(UInt32.self, at: 176) ?? 0
                record.detail = "PIPE"
            case .kqueue:
                record.status = bytes.inspectorLoad(UInt32.self, at: 160) ?? 0
                record.object = UInt64(record.status)
                record.detail = "KQUEUE"
            case .socket:
                populateSocket(bytes, record: &record)
            }
            return record
        }
    }

    private func populateSocket(
        _ bytes: UnsafeRawBufferPointer,
        record: inout FileDescriptorRecord
    ) {
        let protocolBase = 264
        let socketKind = bytes.inspectorLoad(Int32.self, at: 256) ?? 0
        let family = bytes.inspectorLoad(Int32.self, at: 184) ?? 0
        let socketType = bytes.inspectorLoad(Int32.self, at: 176) ?? 0
        record.object = bytes.inspectorLoad(UInt64.self, at: 160) ?? 0
        record.status = UInt32(bitPattern: socketKind)

        switch socketKind {
        case 1, 2:
            let localPort = port(bytes, at: protocolBase + 4)
            let remotePort = port(bytes, at: protocolBase)
            let localIP = address(bytes, family: family, at: protocolBase + 48)
            let remoteIP = address(bytes, family: family, at: protocolBase + 32)
            record.localAddress = endpoint(localIP, port: localPort)
            record.remoteAddress = remotePort == 0 ? "Listening" : endpoint(remoteIP, port: remotePort)
            record.detail = socketKind == 2 ? (family == AF_INET6 ? "TCP6" : "TCP")
                : (family == AF_INET6 ? "UDP6" : "UDP")
        case 3:
            record.peer = bytes.inspectorLoad(UInt64.self, at: protocolBase) ?? 0
            record.localAddress = bytes.inspectorCString(at: protocolBase + 18, capacity: 104)
            record.remoteAddress = bytes.inspectorCString(at: protocolBase + 273, capacity: 104)
            record.detail = "UNIX \(socketType)"
        case 5:
            let vendor = bytes.inspectorLoad(UInt32.self, at: protocolBase) ?? 0
            let eventClass = bytes.inspectorLoad(UInt32.self, at: protocolBase + 4) ?? 0
            let subclass = bytes.inspectorLoad(UInt32.self, at: protocolBase + 8) ?? 0
            record.detail = "KEVNT \(vendor)/\(eventClass)/\(subclass)"
        case 6:
            record.detail = "KCTL \(bytes.inspectorCString(at: protocolBase + 24, capacity: 96))"
        case 4:
            record.detail = "NDRV \(family)"
        default:
            record.detail = "SOCKET \(family)"
        }
    }

    private func ports(for pid: Int32) -> [MachPortRecord]? {
        guard let task = PrivateSystem.readTask(pid) else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var space = ipc_info_space_t()
        var table: ipc_info_name_array_t?
        var tableCount: mach_msg_type_number_t = 0
        var tree: ipc_info_tree_name_array_t?
        var treeCount: mach_msg_type_number_t = 0
        let result = mach_port_space_info(
            task,
            &space,
            &table,
            &tableCount,
            &tree,
            &treeCount
        )
        guard result == KERN_SUCCESS else { errno = EPERM; return nil }
        defer {
            if let table {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(UInt(bitPattern: table)),
                    vm_size_t(tableCount) * vm_size_t(MemoryLayout<ipc_info_name_t>.stride)
                )
            }
            if let tree {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(UInt(bitPattern: tree)),
                    vm_size_t(treeCount) * vm_size_t(MemoryLayout<ipc_info_tree_name_t>.stride)
                )
            }
        }
        guard tableCount <= Self.maximumPorts, let table else { errno = ENOSPC; return nil }

        var records = [MachPortRecord]()
        records.reserveCapacity(Int(tableCount))
        for index in 0..<Int(tableCount) {
            autoreleasepool {
                let info = table[index]
                var objectType = ipc_info_object_type_t(rawValue: 0)!
                var objectAddress: mach_vm_address_t = 0
                if mach_port_kobject(task, info.iin_name, &objectType, &objectAddress) != KERN_SUCCESS {
                    objectType = ipc_info_object_type_t(rawValue: 0)!
                }
                records.append(MachPortRecord(
                    name: info.iin_name,
                    rights: info.iin_type,
                    userReferences: info.iin_urefs,
                    object: info.iin_object,
                    objectType: UInt32(objectType.rawValue),
                    setMembers: portSetMembers(task: task, name: info.iin_name, rights: info.iin_type)
                ))
            }
        }
        return records
    }

    private func portSetMembers(
        task: mach_port_t,
        name: mach_port_name_t,
        rights: mach_port_type_t
    ) -> [UInt32] {
        let portSetRight = mach_port_type_t(1 << 19)
        guard rights & portSetRight != 0 else { return [] }
        var members: mach_port_name_array_t?
        var count: mach_msg_type_number_t = 0
        guard mach_port_get_set_status(task, name, &members, &count) == KERN_SUCCESS,
              count <= Self.maximumPorts,
              let members else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: members)),
                vm_size_t(count) * vm_size_t(MemoryLayout<mach_port_name_t>.stride)
            )
        }
        return Array(UnsafeBufferPointer(start: members, count: Int(count)))
    }

    private func modules(
        for pid: Int32
    ) -> (records: [ModuleRecord], status: CollectorStatus)? {
        if pid == 0 {
            guard let records = kernelModules() else { return nil }
            return (records, .available)
        }

        let regions = regionModules(for: pid)
        guard let task = PrivateSystem.readTask(pid) else {
            return regions.map { ($0, .partial) }
        }
        defer { mach_port_deallocate(mach_task_self_, task) }
        guard let images = dyldImages(task: task), !images.isEmpty else {
            return regions.map { ($0, .partial) }
        }

        let regionByPath = Dictionary(
            uniqueKeysWithValues: (regions ?? []).map { ($0.path, $0) }
        )
        var seen = Set<String>()
        var records = [ModuleRecord]()
        records.reserveCapacity(min(images.count, Self.maximumModules))
        for image in images where records.count < Self.maximumModules && seen.insert(image.path).inserted {
            autoreleasepool {
                let region = regionByPath[image.path]
                // Everything in the shared cache is one region as far as
                // proc_regionpath is concerned, so those images have no region
                // of their own to take a size from — read it off the header.
                let size = region?.size ?? imageSize(task: task, address: image.address)
                records.append(ModuleRecord(
                    path: image.path,
                    identifier: "",
                    address: image.address,
                    size: size,
                    referenceCount: region?.referenceCount ?? 0
                ))
            }
        }
        return (records.sorted { $0.address < $1.address }, .available)
    }

    private func regionModules(for pid: Int32) -> [ModuleRecord]? {
        struct Accumulator {
            var path: String
            var address: UInt64
            var size: UInt64
            var referenceCount: UInt32
            var executable: Bool
        }

        var address: UInt64 = 0
        var regions = 0
        var modules = [String: Accumulator]()
        while regions < Self.maximumRegions {
            var bytes = [UInt8](repeating: 0, count: 1_272)
            let count = bytes.withUnsafeMutableBytes {
                inspectorProcPIDInfo(
                    pid,
                    PrivateSystemConstant.processRegionPathInfo,
                    address,
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            guard count == bytes.count else { break }
            regions += 1

            let region = bytes.withUnsafeBytes { buffer -> (String, UInt64, UInt64, UInt32, Bool)? in
                guard let start = buffer.inspectorLoad(UInt64.self, at: 80),
                      let size = buffer.inspectorLoad(UInt64.self, at: 88),
                      let protection = buffer.inspectorLoad(UInt32.self, at: 0),
                      let maximum = buffer.inspectorLoad(UInt32.self, at: 4),
                      let references = buffer.inspectorLoad(UInt32.self, at: 52),
                      size > 0 else { return nil }
                let path = buffer.inspectorCString(at: 248, capacity: 1_024)
                let executable = (protection | maximum) & UInt32(VM_PROT_EXECUTE) != 0
                return (path, start, size, references, executable)
            }
            guard let region else { break }
            let (next, overflow) = region.1.addingReportingOverflow(region.2)
            guard !overflow, next > address else { break }
            address = next
            guard !region.0.isEmpty else { continue }

            if var existing = modules[region.0] {
                existing.address = min(existing.address, region.1)
                existing.size = adding(existing.size, region.2)
                existing.referenceCount = max(existing.referenceCount, region.3)
                existing.executable = existing.executable || region.4
                modules[region.0] = existing
            } else if modules.count < Self.maximumModules {
                modules[region.0] = Accumulator(
                    path: region.0,
                    address: region.1,
                    size: region.2,
                    referenceCount: region.3,
                    executable: region.4
                )
            } else {
                errno = ENOSPC
                return nil
            }
        }
        guard regions > 0 else { if errno == 0 { errno = ESRCH }; return nil }
        return modules.values
            .filter(\.executable)
            .map {
                ModuleRecord(
                    path: $0.path,
                    identifier: "",
                    address: $0.address,
                    size: $0.size,
                    referenceCount: $0.referenceCount
                )
            }
            .sorted { $0.address < $1.address }
    }

    private func dyldImages(task: mach_port_t) -> [(address: UInt64, path: String)]? {
        var info = task_dyld_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_DYLD_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS,
              info.all_image_info_format == TASK_DYLD_ALL_IMAGE_INFO_64,
              let header = readMemory(task: task, address: info.all_image_info_addr, count: 16) else {
            return nil
        }
        let values = header.withUnsafeBytes { bytes -> (UInt32, UInt64)? in
            guard let imageCount = bytes.inspectorLoad(UInt32.self, at: 4),
                  let imageArray = bytes.inspectorLoad(UInt64.self, at: 8),
                  imageCount <= Self.maximumModules else { return nil }
            return (imageCount, imageArray)
        }
        guard let (imageCount, imageArray) = values else { return nil }
        let (byteCount, overflow) = Int(imageCount).multipliedReportingOverflow(by: 24)
        guard !overflow,
              let entries = readMemory(task: task, address: imageArray, count: byteCount) else {
            return nil
        }

        var images = [(UInt64, String)]()
        images.reserveCapacity(Int(imageCount))
        for offset in stride(from: 0, to: byteCount, by: 24) {
            autoreleasepool {
                entries.withUnsafeBytes { bytes in
                    guard let address = bytes.inspectorLoad(UInt64.self, at: offset),
                          let pathAddress = bytes.inspectorLoad(UInt64.self, at: offset + 8),
                          let path = readCString(task: task, address: pathAddress),
                          !path.isEmpty else { return }
                    images.append((address, path))
                }
            }
        }
        return images
    }

    // Mapped bytes of a Mach-O image, summed from its segments. __PAGEZERO is
    // never mapped and __LINKEDIT is one region shared by every image in the
    // dyld cache, so counting either would report a size nothing else agrees
    // with. Returns 0 when the header can't be read — the UI shows a dash.
    private func imageSize(task: mach_port_t, address: UInt64) -> UInt64 {
        guard let header = readMemory(task: task, address: address, count: 32) else { return 0 }
        let counts = header.withUnsafeBytes { bytes -> (UInt32, Int)? in
            guard let magic = bytes.inspectorLoad(UInt32.self, at: 0),
                  magic == MH_MAGIC_64,
                  let commandCount = bytes.inspectorLoad(UInt32.self, at: 16),
                  let commandBytes = bytes.inspectorLoad(UInt32.self, at: 20),
                  commandCount > 0,
                  commandBytes >= 8,
                  commandBytes <= Self.maximumLoadCommandBytes else { return nil }
            return (commandCount, Int(commandBytes))
        }
        let (start, overflow) = address.addingReportingOverflow(32)
        guard let (commandCount, commandBytes) = counts,
              !overflow,
              let commands = readMemory(task: task, address: start, count: commandBytes) else {
            return 0
        }

        var total: UInt64 = 0
        var offset = 0
        for _ in 0..<commandCount {
            let segment = commands.withUnsafeBytes { bytes -> (size: Int, mapped: UInt64)? in
                guard let command = bytes.inspectorLoad(UInt32.self, at: offset),
                      let commandSize = bytes.inspectorLoad(UInt32.self, at: offset + 4),
                      commandSize >= 8,
                      offset + Int(commandSize) <= commandBytes else { return nil }
                guard command == UInt32(LC_SEGMENT_64), commandSize >= 72,
                      let mapped = bytes.inspectorLoad(UInt64.self, at: offset + 32) else {
                    return (Int(commandSize), 0)
                }
                let name = bytes.inspectorCString(at: offset + 8, capacity: 16)
                let counted = name != "__PAGEZERO" && name != "__LINKEDIT"
                return (Int(commandSize), counted ? mapped : 0)
            }
            guard let segment else { break }
            total = adding(total, segment.mapped)
            offset += segment.size
        }
        return total
    }

    private func readMemory(
        task: mach_port_t,
        address: UInt64,
        count: Int
    ) -> [UInt8]? {
        guard count >= 0, count <= 65_536 else { return nil }
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var copied: mach_vm_size_t = 0
        let result = bytes.withUnsafeMutableBytes { buffer -> kern_return_t in
            guard let destination = buffer.baseAddress else { return KERN_INVALID_ADDRESS }
            return inspectorMachVMReadOverwrite(
                task,
                mach_vm_address_t(address),
                mach_vm_size_t(count),
                mach_vm_address_t(UInt(bitPattern: destination)),
                &copied
            )
        }
        return result == KERN_SUCCESS && copied == count ? bytes : nil
    }

    private func readCString(task: mach_port_t, address: UInt64) -> String? {
        guard address != 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(Int(MAXPATHLEN))
        while bytes.count < Int(MAXPATHLEN) {
            let (chunkAddress, overflow) = address.addingReportingOverflow(UInt64(bytes.count))
            guard !overflow,
                  let chunk = readMemory(task: task, address: chunkAddress, count: 64) else {
                return nil
            }
            if let end = chunk.firstIndex(of: 0) {
                bytes.append(contentsOf: chunk[..<end])
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(contentsOf: chunk)
        }
        return nil
    }

    private func kernelModules() -> [ModuleRecord]? {
        guard let copy = Self.copyLoadedKextInfo,
              let unmanaged = copy(nil, nil) else { errno = ENOTSUP; return nil }
        let dictionary = unmanaged.takeRetainedValue() as NSDictionary
        var records = [ModuleRecord]()
        records.reserveCapacity(min(dictionary.count, Self.maximumModules))
        for (key, value) in dictionary where records.count < Self.maximumModules {
            autoreleasepool {
                guard let info = value as? NSDictionary else { return }
                let identifier = key as? String
                    ?? info["CFBundleIdentifier"] as? String
                    ?? ""
                let path = info["OSBundleExecutablePath"] as? String
                    ?? info["OSBundlePath"] as? String
                    ?? identifier
                records.append(ModuleRecord(
                    path: path,
                    identifier: identifier,
                    address: number(info["OSBundleLoadAddress"]),
                    size: number(info["OSBundleLoadSize"]),
                    referenceCount: UInt32(clamping: number(info["OSBundleRetainCount"]))
                ))
            }
        }
        return records.sorted { $0.address < $1.address }
    }

    private func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }

    private func bundleMetadata(for executablePath: String) -> BundleMetadata? {
        let directory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        guard directory.pathExtension == "app" else { return nil }
        let propertyList = directory.appendingPathComponent("Info.plist")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: propertyList.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= Self.maximumPropertyListBytes,
              let data = try? Data(contentsOf: propertyList, options: .mappedIfSafe),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return BundleMetadata(
            identifier: string(values["CFBundleIdentifier"]),
            name: string(values["CFBundleName"]),
            displayName: string(values["CFBundleDisplayName"]),
            version: string(values["CFBundleVersion"]),
            minimumOSVersion: string(values["MinimumOSVersion"]),
            SDKName: string(values["DTSDKName"]),
            platformVersion: string(values["DTPlatformVersion"]),
            compiler: string(values["DTCompiler"])
        )
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        return (value as? NSNumber)?.stringValue ?? ""
    }

    private func address(
        _ bytes: UnsafeRawBufferPointer,
        family: Int32,
        at offset: Int
    ) -> String {
        let count: Int
        let addressOffset: Int
        switch family {
        case AF_INET:
            count = 4
            addressOffset = offset + 12
        case AF_INET6:
            count = 16
            addressOffset = offset
        default:
            return ""
        }
        guard addressOffset >= 0, addressOffset + count <= bytes.count else { return "" }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return bytes.baseAddress.map { base in
            inet_ntop(family, base.advanced(by: addressOffset), &output, socklen_t(output.count))
                .map { _ in String(cString: output) } ?? ""
        } ?? ""
    }

    private func port(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: bytes.inspectorLoad(UInt32.self, at: offset) ?? 0))
    }

    private func endpoint(_ address: String, port: UInt16) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func failure(
        _ kind: ProcessDetailKind,
        _ identity: ProcessIdentity,
        _ error: Int32
    ) -> ProcessDetailSnapshot {
        let status: CollectorStatus
        switch error {
        case ESRCH: status = .processExited
        case EPERM, EACCES: status = .permissionDenied
        case ENOTSUP: status = .unsupported
        default: status = .failed
        }
        return ProcessDetailSnapshot(
            identity: identity,
            kind: kind,
            status: status,
            errorCode: error,
            process: nil
        )
    }

    private typealias CopyLoadedKextInfo = @convention(c) (
        CFArray?,
        CFArray?
    ) -> Unmanaged<CFDictionary>?

    private static let copyLoadedKextInfo: CopyLoadedKextInfo? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "OSKextCopyLoadedKextInfo") else { return nil }
        return unsafeBitCast(symbol, to: CopyLoadedKextInfo.self)
    }()
}
