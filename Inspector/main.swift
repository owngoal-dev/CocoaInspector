import UIKit

// Every cold launch starts with fresh scenes, regardless of its launch source.
// Do this before UIKit reads saved sessions; background resumes do not run main.
do {
    if let bundleIdentifier = Bundle.main.bundleIdentifier {
        let library = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        try SceneRestorationReset.removeSavedState(in: library, bundleIdentifier: bundleIdentifier)
    }
} catch {
    NSLog("Could not clear Inspector scene restoration: %@", String(describing: error))
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
