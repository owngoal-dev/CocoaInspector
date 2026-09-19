import Foundation

@main
enum SceneRestorationHarness {
    static func main() throws {
        let files = FileManager.default
        let library = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: library) }
        let restoration = library.appendingPathComponent("Saved Application State")
        let savedState = restoration.appendingPathComponent("wiki.qaq.Inspector.savedState")
        let sessions = savedState.appendingPathComponent("KnownSceneSessions/data.data")
        let preferences = library.appendingPathComponent("Preferences/settings.plist")
        let sibling = restoration.appendingPathComponent("another.app.savedState/data.data")
        for url in [preferences, sibling] {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: url)
        }

        func reset() throws {
            try SceneRestorationReset.removeSavedState(in: library, bundleIdentifier: "wiki.qaq.Inspector")
        }

        // A fresh install and repeated resets both succeed without saved state.
        try reset()
        try reset()
        precondition(!files.fileExists(atPath: savedState.path))

        // Every cold launch removes the whole restoration tree, irrespective
        // of delegate type or archive format, including new UIKit sessions.
        for contents in ["SwiftUI.AppSceneDelegate", "Inspector.SceneDelegate", "unknown format"] {
            try files.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: sessions)
            try Data("scene state".utf8).write(to: savedState.appendingPathComponent("scene.data"))
            try reset()
            precondition(!files.fileExists(atPath: savedState.path))
            let settings = try Data(contentsOf: preferences)
            let otherState = try Data(contentsOf: sibling)
            precondition(settings == Data("keep".utf8))
            precondition(otherState == Data("keep".utf8))
        }
        print("CocoaInspector scene-restoration harness passed")
    }
}
