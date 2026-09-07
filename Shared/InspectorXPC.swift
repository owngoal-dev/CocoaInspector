import CInspectorXPC
import XPC

/// The XPC type constants, read through C rather than through Swift's XPC overlay.
///
/// Naming the SDK's `XPC_TYPE_*` macros in Swift links
/// `/usr/lib/swift/libswiftXPC.dylib` as a required library, and iOS 15 does
/// not have it: dyld terminates the process before `main` with "Library not
/// loaded". Through `CInspectorXPC` they are the libSystem globals they have
/// always been, the overlay stays weakly linked and unused, and the same binary
/// runs on iOS 15 and on iOS 26. No Swift file in this project may spell them
/// directly; `make check` fails on one that does.
enum InspectorXPC {
    static var typeBool: xpc_type_t { inspector_xpc_type_bool() }
    static var typeConnection: xpc_type_t { inspector_xpc_type_connection() }
    static var typeDictionary: xpc_type_t { inspector_xpc_type_dictionary() }
    static var typeError: xpc_type_t { inspector_xpc_type_error() }
}
