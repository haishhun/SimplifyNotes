import SwiftUI
import SwiftData
import UIKit

@main
struct InkwellApp: App {
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.tools)
                .environment(environment.settings)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
        }
        .modelContainer(environment.container)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                persistForBackground()
            }
        }
    }

    /// Gives pending writes time to finish even if the app is suspended right away.
    private func persistForBackground() {
        let application = UIApplication.shared
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = application.beginBackgroundTask(withName: "SaveNotes") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        NotificationCenter.default.post(name: .inkwellWillResignActive, object: nil)
        environment.flushAll()
        if taskID != .invalid { application.endBackgroundTask(taskID) }
    }
}

extension Notification.Name {
    /// Editors flush in-memory changes to the store when this is posted.
    static let inkwellWillResignActive = Notification.Name("inkwellWillResignActive")
}
