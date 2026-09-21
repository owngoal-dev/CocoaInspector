import Darwin
import XPC

enum PrivateSystem {
    private typealias TaskRead = @convention(c) (
        mach_port_t,
        Int32,
        UnsafeMutablePointer<mach_port_t>
    ) -> kern_return_t

    private static let taskRead: TaskRead? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "task_read_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: TaskRead.self)
    }()

    static func readTask(_ pid: Int32) -> mach_port_t? {
        guard let taskRead else { errno = ENOTSUP; return nil }
        var task = mach_port_t(MACH_PORT_NULL)
        guard taskRead(mach_task_self_, pid, &task) == KERN_SUCCESS,
              task != MACH_PORT_NULL else { errno = EPERM; return nil }
        return task
    }
}

@_silgen_name("proc_listallpids")
func inspectorProcListAllPIDs(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@_silgen_name("proc_name")
func inspectorProcName(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("proc_pidpath")
func inspectorProcPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("proc_pidinfo")
func inspectorProcPIDInfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int32
) -> Int32

@_silgen_name("proc_pidfdinfo")
func inspectorProcPIDFDInfo(
    _ pid: Int32,
    _ descriptor: Int32,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int32
) -> Int32

@_silgen_name("proc_pid_rusage")
func inspectorProcPIDResourceUsage(
    _ pid: Int32,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

@_silgen_name("mach_vm_read_overwrite")
func inspectorMachVMReadOverwrite(
    _ task: mach_port_t,
    _ address: mach_vm_address_t,
    _ size: mach_vm_size_t,
    _ destination: mach_vm_address_t,
    _ copied: UnsafeMutablePointer<mach_vm_size_t>
) -> kern_return_t

@_silgen_name("xpc_connection_get_audit_token")
func inspectorXPCConnectionGetAuditToken(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

@_silgen_name("xpc_copy_entitlement_for_token")
func inspectorXPCCopyEntitlement(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<audit_token_t>
) -> xpc_object_t?

@_silgen_name("xpc_connection_create_mach_service")
func inspectorCreateMachServiceListener(
    _ name: UnsafePointer<CChar>,
    _ targetQueue: DispatchQueue?,
    _ flags: UInt64
) -> xpc_connection_t?

enum PrivateSystemConstant {
    static let processTaskAllInfo: Int32 = 2
    static let processTaskAllInfoSize = 232
    static let bsdInfoSize = 136
    static let processThreadInfo: Int32 = 5
    static let processListThreads: Int32 = 6
    static let processThreadID64Info: Int32 = 15
    static let processListThreadIDs: Int32 = 28
    static let processIPCTableInfo: Int32 = 32
    static let processListFileDescriptors: Int32 = 1
    static let processRegionPathInfo: Int32 = 8
    static let fileDescriptorVnodePathInfo: Int32 = 2
    static let fileDescriptorSocketInfo: Int32 = 3
    static let fileDescriptorPipeInfo: Int32 = 6
    static let fileDescriptorKqueueInfo: Int32 = 7
    static let resourceUsageV4: Int32 = 4
    static let machServiceListener: UInt64 = 1
}

extension UnsafeRawBufferPointer {
    func inspectorLoad<T>(_ type: T.Type, at offset: Int) -> T? {
        let (end, overflow) = offset.addingReportingOverflow(MemoryLayout<T>.size)
        guard !overflow, offset >= 0, end <= count else { return nil }
        return loadUnaligned(fromByteOffset: offset, as: type)
    }

    func inspectorCString(at offset: Int, capacity: Int) -> String {
        guard offset >= 0, capacity >= 0, offset + capacity <= count else { return "" }
        let bytes = self[offset..<(offset + capacity)]
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
