#pragma once

// The SDK's own XPC constants, handed to Swift as functions. See
// module.modulemap for why they cannot be named directly in Swift, and
// `InspectorXPC` in Shared/InspectorXPC.swift for the Swift side. Nothing is
// defined here; every body is an SDK macro.

#include <xpc/xpc.h>
#include <xpc/connection.h>

static inline xpc_type_t inspector_xpc_type_bool(void) { return XPC_TYPE_BOOL; }
static inline xpc_type_t inspector_xpc_type_connection(void) { return XPC_TYPE_CONNECTION; }
static inline xpc_type_t inspector_xpc_type_dictionary(void) { return XPC_TYPE_DICTIONARY; }
static inline xpc_type_t inspector_xpc_type_error(void) { return XPC_TYPE_ERROR; }
