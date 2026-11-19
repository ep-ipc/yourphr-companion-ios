import BackgroundTasks
import SwiftUI

@main
struct YourPHRCompanionApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // Must register before launch finishes. BackgroundSync is not MainActor-isolated, so the
        // scheduler can call it from its own queue without hopping through AppModel.
        BackgroundSync.registerTasks { task in
            BackgroundSync.shared.handleRefreshTask(task)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { model.startRuntime() }
                .onOpenURL { model.openDeviceLink($0) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.sceneBecameActive()
            case .background:
                model.sceneWentBackground()
            default:
                break
            }
        }
    }
}
