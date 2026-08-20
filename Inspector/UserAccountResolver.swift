import Darwin
import Foundation

// Resolve accounts from the device's user database instead of assuming that a
// particular UID always has a particular name. Process rows ask for these
// values frequently, so both successful and failed lookups are cached.
final class UserAccountResolver: @unchecked Sendable {
    private struct NameCacheEntry {
        let name: String?
    }

    private struct IDCacheEntry {
        let id: uid_t?
    }

    static let shared = UserAccountResolver()

    private let lock = NSLock()
    private var namesByID: [uid_t: NameCacheEntry] = [:]
    private var idsByName: [String: IDCacheEntry] = [:]

    func name(for uid: uid_t) -> String? {
        lock.lock()
        if let cached = namesByID[uid] {
            lock.unlock()
            return cached.name
        }
        lock.unlock()

        let name = lookup(uid)
        lock.lock()
        namesByID[uid] = NameCacheEntry(name: name)
        if let name {
            idsByName[name] = IDCacheEntry(id: uid)
        }
        lock.unlock()
        return name
    }

    func id(for name: String) -> uid_t? {
        lock.lock()
        if let cached = idsByName[name] {
            lock.unlock()
            return cached.id
        }
        lock.unlock()

        let id = lookup(name)
        lock.lock()
        idsByName[name] = IDCacheEntry(id: id)
        if let id {
            namesByID[id] = NameCacheEntry(name: name)
        }
        lock.unlock()
        return id
    }

    private func lookup(_ uid: uid_t) -> String? {
        var bufferSize = 1_024
        while bufferSize <= 1_048_576 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let status = buffer.withUnsafeMutableBufferPointer { buffer in
                getpwuid_r(
                    uid,
                    &record,
                    buffer.baseAddress!,
                    buffer.count,
                    &result
                )
            }
            if status == ERANGE {
                bufferSize *= 2
                continue
            }
            guard status == 0,
                  result != nil,
                  let pointer = record.pw_name else { return nil }
            let name = String(cString: pointer)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private func lookup(_ name: String) -> uid_t? {
        var bufferSize = 1_024
        while bufferSize <= 1_048_576 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let status = name.withCString { name in
                buffer.withUnsafeMutableBufferPointer { buffer in
                    getpwnam_r(
                        name,
                        &record,
                        buffer.baseAddress!,
                        buffer.count,
                        &result
                    )
                }
            }
            if status == ERANGE {
                bufferSize *= 2
                continue
            }
            guard status == 0, result != nil else { return nil }
            return record.pw_uid
        }
        return nil
    }
}
