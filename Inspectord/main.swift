import Dispatch
import Foundation

autoreleasepool {
    do {
        let server = DaemonServer()
        try server.start()
        withExtendedLifetime(server) {
            dispatchMain()
        }
    } catch {
        exit(EXIT_FAILURE)
    }
}
