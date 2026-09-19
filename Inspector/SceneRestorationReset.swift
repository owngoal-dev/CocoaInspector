import Foundation

enum SceneRestorationReset {
    static func removeSavedState(in library: URL, bundleIdentifier: String) throws {
        let savedState = library
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
        guard FileManager.default.fileExists(atPath: savedState.path) else { return }
        try FileManager.default.removeItem(at: savedState)
    }
}
