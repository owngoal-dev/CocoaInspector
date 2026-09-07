import Darwin
import XPC

final class PeerAuthenticator {
    private static let mobileUserID: UInt32 = 501
    private static let requiredEntitlements = [
        InspectorProtocol.clientEntitlement,
        "platform-application",
        "com.apple.private.security.no-sandbox",
    ]

    private lazy var installedClientPaths = resolveInstalledClientPaths()

    func authenticate(_ connection: xpc_connection_t) -> Int32? {
        var token = audit_token_t()
        inspectorXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)
        guard pid > 1,
              (token.val.1 == 0 || token.val.1 == Self.mobileUserID),
              hasRequiredEntitlements(token: &token),
              let clientPath = processPath(pid: pid) else { return nil }

        for installedPath in installedClientPaths {
            guard isRootOwnedExecutable(installedPath) else { continue }
            if clientPath == installedPath { return pid }
        }
        return nil
    }

    private func resolveInstalledClientPaths() -> [String] {
        let suffix = "/usr/libexec/cocoainspectord"
        guard let daemonPath = processPath(pid: getpid()),
              daemonPath.hasSuffix(suffix) else { return [] }
        let root = daemonPath.dropLast(suffix.count)
        return InspectorProtocol.clientPaths.compactMap {
            canonicalPath(String(root) + $0)
        }
    }

    private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
        Self.requiredEntitlements.allSatisfy { entitlement in
            let value = entitlement.withCString {
                inspectorXPCCopyEntitlement($0, &token)
            }
            return value.map {
                xpc_get_type($0) == InspectorXPC.typeBool && xpc_bool_get_value($0)
            } ?? false
        }
    }

    private func processPath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes {
            inspectorProcPIDPath(pid, $0.baseAddress!, UInt32($0.count))
        }
        return result > 0 ? canonicalPath(String(cString: buffer)) : nil
    }

    private func canonicalPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) }
        }
        return result.map { _ in String(cString: buffer) }
    }

    private func isRootOwnedExecutable(_ path: String) -> Bool {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return false }
        return metadata.st_uid == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_mode & mode_t(S_IXUSR) != 0
            && metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }
}
