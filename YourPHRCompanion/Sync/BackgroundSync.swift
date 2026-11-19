import BackgroundTasks
import Foundation
import HealthKit
import UIKit

/// Wires the three wake-ups that actually exist on iOS:
/// - foreground 5-minute timer (the only strict interval)
/// - HKObserverQuery + immediate background delivery (new samples)
/// - BGAppRefreshTask as a catch-up, requested every 5 minutes (iOS may delay it)
final class BackgroundSync {
    static let shared = BackgroundSync()
    static let refreshTaskID = "org.yourphr.companion.refresh"

    private let store = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    private var foregroundTimer: Timer?
    private let engine = SyncEngine()
    private let syncLock = NSLock()
    private var isSyncing = false

    /// Called from the app's `init` before the first frame — BGTaskScheduler requires that.
    static func registerTasks(handler: @escaping (BGAppRefreshTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handler(refresh)
        }
    }

    func startObservers(onWake: @escaping () -> Void) {
        stopObservers()
        guard HKHealthStore.isHealthDataAvailable() else { return }

        for type in HealthKitAuthorizer.backgroundDeliveryTypes {
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                defer { completion() }
                if let error, (error as? HKError)?.code == .errorDatabaseInaccessible {
                    SyncStateStore.shared.pendingUnlock = true
                    return
                }
                if error != nil { return }
                onWake()
                self?.scheduleRefresh()
            }
            observerQueries.append(query)
            store.execute(query)
        }
    }

    func stopObservers() {
        for query in observerQueries {
            store.stop(query)
        }
        observerQueries.removeAll()
        for type in HealthKitAuthorizer.backgroundDeliveryTypes {
            store.disableBackgroundDelivery(for: type) { _, _ in }
        }
    }

    func startForegroundTimer(every interval: TimeInterval = 5 * 60, fire: @escaping () -> Void) {
        stopForegroundTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            fire()
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        foregroundTimer = timer
    }

    func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleRefreshTask(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            do {
                _ = try await engine.sync(budget: .background)
                task.setTaskCompleted(success: true)
            } catch {
                if error is SyncError {
                    // databaseInaccessible is expected on a locked wake; say success so iOS keeps scheduling.
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
            }
        }
        task.expirationHandler = { work.cancel() }
    }

    func runSync(budget: SyncBudget, onProgress: (@MainActor (String) -> Void)? = nil) async {
        syncLock.lock()
        if isSyncing {
            syncLock.unlock()
            return
        }
        isSyncing = true
        syncLock.unlock()
        defer {
            syncLock.lock()
            isSyncing = false
            syncLock.unlock()
        }
        do {
            _ = try await engine.sync(budget: budget, onProgress: onProgress)
        } catch SyncError.databaseInaccessible {
            await MainActor.run {
                SyncStateStore.shared.recordFailure(SyncError.databaseInaccessible.localizedDescription, pendingUnlock: true)
            }
        } catch {
            await MainActor.run {
                SyncStateStore.shared.recordFailure(error.localizedDescription)
            }
        }
    }
}
