//
//  AppDelegate.swift
//  Inspector
//
//  Created by qaq on 3/8/2026.
//

import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UpdateNotice.shared.startWatching()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let model = ProcessListModel()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        // The asset catalog's global accent only reaches UIKit from iOS 14.
        window.tintColor = UIColor(named: "AccentColor")
        window.rootViewController = InspectorSplitViewController(model: model)
        window.makeKeyAndVisible()
        self.window = window
    }

    // Sampling follows the scene, not the launch: a locked-screen launch
    // (uiopen, prewarming) connects a scene that never becomes active, and an
    // unconditional start would keep an unnecessary client connection and
    // sampling loop alive behind the lock screen.
    func sceneDidBecomeActive(_ scene: UIScene) {
        model.start()
        UpdateNotice.shared.presentIfPending(in: window)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        model.stop()
    }
}

/// An update or a removal took the running copy's executable
/// (`ExecutableWatch`); the watch cannot tell which. After an update this is
/// old code against a daemon the package's postinst has already restarted.
@MainActor
final class UpdateNotice {
    static let shared = UpdateNotice()

    private var isPending = false

    func startWatching() {
        ExecutableWatch.start { [weak self] in
            guard let self else { return }
            self.isPending = true
            let window = UIApplication.shared.connectedScenes
                .filter { $0.activationState == .foregroundActive }
                .compactMap { ($0.delegate as? SceneDelegate)?.window }
                .first
            self.presentIfPending(in: window)
        }
    }

    // A suspended app hears about the update as it resumes, possibly before
    // any scene is active again; the notice then waits for the next one.
    func presentIfPending(in window: UIWindow?) {
        guard isPending, var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        isPending = false
        let alert = UIAlertController(
            title: String(localized: "Inspector Was Updated or Removed"),
            message: String(
                localized: "This copy is no longer installed. Quit it and open Inspector again to continue."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Later"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Quit Inspector"), style: .default) { _ in
            exit(0)
        })
        presenter.present(alert, animated: true)
    }
}
