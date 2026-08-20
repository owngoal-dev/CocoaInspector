import Foundation

enum InspectorFormat {
    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory))
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    static func cpuTime(_ ticks: UInt64, numerator: UInt32, denominator: UInt32) -> String {
        guard denominator != 0, numerator != 0 else { return "—" }
        let seconds = Double(ticks) * Double(numerator) / Double(denominator) / 1_000_000_000
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    static func duration(_ nanoseconds: UInt64) -> String {
        let total = Int(nanoseconds / 1_000_000_000)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return String(localized: "\(days)d \(hours)h") }
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
        return String(localized: "\(minutes)m")
    }

    static func user(_ uid: UInt32) -> String {
        guard let name = UserAccountResolver.shared.name(for: uid_t(uid)) else {
            return "UID \(uid)"
        }
        return "\(name) (\(uid))"
    }

    static func sandbox(_ status: ProcessSandboxStatus) -> String {
        switch status {
        case .unavailable: String(localized: "Unknown")
        case .unrestricted: String(localized: "Unrestricted")
        case .sandboxed: String(localized: "Sandboxed")
        }
    }

    static func threadState(_ runState: Int32) -> String {
        switch runState {
        case 1: String(localized: "Running")
        case 2: String(localized: "Stopped")
        case 3: String(localized: "Waiting")
        case 4: String(localized: "Uninterruptible")
        case 5: String(localized: "Halted")
        default: String(localized: "State \(Int(runState))")
        }
    }

    static func fileKind(_ kind: FileDescriptorKind) -> String {
        switch kind {
        case .vnode: String(localized: "File")
        case .socket: String(localized: "Socket")
        case .kqueue: String(localized: "Kqueue")
        case .pipe: String(localized: "Pipe")
        }
    }

    static func portRights(_ rights: UInt32) -> String {
        var parts = [String]()
        if rights & 0x10000 != 0 { parts.append("send") }
        if rights & 0x20000 != 0 { parts.append("receive") }
        if rights & 0x40000 != 0 { parts.append("send-once") }
        if rights & 0x80000 != 0 { parts.append("port-set") }
        if rights & 0x100000 != 0 { parts.append("dead") }
        return parts.isEmpty ? hex(UInt64(rights)) : parts.joined(separator: ", ")
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    // Marketing version plus build, the way a bug report should quote it.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "v\(version)(\(build))"
    }
}

enum InspectorErrorText {
    static func describe(_ error: Error) -> String {
        guard let error = error as? InspectorDataError else {
            return String(localized: "Something unexpected went wrong.")
        }
        switch error {
        case .disconnected:
            return String(localized: "Lost the connection to the inspector service.")
        case .alreadyActive:
            return String(localized: "This session is already running.")
        case .busy:
            return String(localized: "Another request is still finishing.")
        case .invalidReply:
            return String(localized: "The inspector service sent an unexpected reply.")
        case .transportFailure:
            return String(localized: "Couldn’t reach the inspector service.")
        case .malformedSnapshot:
            return String(localized: "The process data couldn’t be read.")
        case .rejected(let code):
            switch code {
            case .success:
                return String(localized: "Done.")
            case .invalidRequest:
                return String(localized: "The inspector service turned down this request.")
            case .foregroundLeaseRequired:
                return String(localized: "The session timed out. Please try again.")
            case .busy:
                return String(localized: "The inspector service is busy right now.")
            case .targetChanged:
                return String(localized: "This process has ended or changed.")
            case .ticketExpired:
                return String(localized: "That took too long. Please try again.")
            case .operationFailed:
                return String(localized: "The inspector service couldn’t complete this.")
            }
        }
    }
}
