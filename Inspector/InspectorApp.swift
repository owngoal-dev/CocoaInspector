//
//  InspectorApp.swift
//  Inspector
//
//  Created by qaq on 3/8/2026.
//

import Combine
import SwiftUI

@main
struct InspectorApp: App {
    @StateObject private var updateNotice = UpdateNotice()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .alert("Inspector Was Updated", isPresented: $updateNotice.isPending) {
                    Button("Later", role: .cancel) {}
                    Button("Quit Inspector") { exit(0) }
                } message: {
                    Text("This is still the old version. Quit Inspector and open it again to use the new one.")
                }
        }
    }
}

/// An update replaced the running copy (`ExecutableWatch`): old code, against
/// a daemon the package's postinst has already restarted.
@MainActor
final class UpdateNotice: ObservableObject {
    @Published var isPending = false

    init() {
        ExecutableWatch.start { [weak self] in self?.isPending = true }
    }
}
