import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Route {
        case home
        case pair
        case sync
    }

    enum PairingIntent {
        case none
        case sync
    }

    @Published var route: Route = .home
    @Published var pairingError: String?
    @Published var pairingIntent: PairingIntent = .none
    @Published var isBusy = false
    @Published var progress: String?
    @Published var lastSyncAt: Date?
    @Published var lastError: String?
    @Published var pendingUnlock = false
    @Published var lastStored = 0
    @Published var lastReceived = 0
    @Published var username: String?
    @Published var baseURL: String?
    @Published var healthAuthorized = false
    @Published var showHealthPrompt = false
    @Published var latestReadings: [String: String] = [:]

    let pairing = PairingService()
    let authorizer = HealthKitAuthorizer()
    let background = BackgroundSync.shared
    private let syncState = SyncStateStore.shared

    init() {
        refreshFromStore()
    }

    func refreshFromStore() {
        lastSyncAt = syncState.lastSyncAt
        lastError = syncState.lastError
        pendingUnlock = syncState.pendingUnlock
        lastStored = syncState.lastStored
        lastReceived = syncState.lastReceived
        healthAuthorized = syncState.healthAuthorized
        baseURL = KeychainStore.shared.get(account: KeychainStore.Account.baseURL)
        username = KeychainStore.shared.get(account: KeychainStore.Account.username)
        if route == .pair { return }
        route = pairing.isPaired ? .sync : .home
    }

    func dismissPair() {
        pairingIntent = .none
        pairingError = nil
        route = pairing.isPaired ? .sync : .home
    }

    func requestSync() {
        guard pairing.isPaired else {
            pairingIntent = .sync
            pairingError = nil
            route = .pair
            return
        }
        route = .sync
        if !healthAuthorized {
            showHealthPrompt = true
        }
    }

    func pair(payload: PairingPayload) async {
        isBusy = true
        pairingError = nil
        defer { isBusy = false }
        do {
            let grant = try await pairing.pair(payload: payload)
            username = grant.label
            pairingIntent = .none
            refreshFromStore()
            route = .sync
            if !healthAuthorized { showHealthPrompt = true }
            startRuntime()
            await syncNow(budget: .foreground)
        } catch {
            pairingError = error.localizedDescription
        }
    }

    func requestHealthAccess() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await authorizer.requestReadAccess()
            refreshFromStore()
            startRuntime()
            await syncNow(budget: .foreground)
        } catch {
            lastError = error.localizedDescription
            syncState.recordFailure(error.localizedDescription)
            refreshFromStore()
        }
    }

    func skipHealthOnSimulator() {
        syncState.healthAuthorized = true
        refreshFromStore()
        startRuntime()
    }

    func openDeviceLink(_ url: URL) {
        do {
            let payload = try PairingPayload.parse(url)
            pairingError = nil
            route = .pair
            Task { await pair(payload: payload) }
        } catch {
            pairingError = error.localizedDescription
            route = .pair
        }
    }

    func startRuntime() {
        guard pairing.isPaired, syncState.healthAuthorized else { return }
        background.startObservers { [weak self] in
            Task { @MainActor in
                await self?.syncNow(budget: .background)
            }
        }
        background.startForegroundTimer { [weak self] in
            Task { @MainActor in
                await self?.syncNow(budget: .foreground)
            }
        }
        background.scheduleRefresh()
    }

    func sceneBecameActive() {
        refreshFromStore()
        guard pairing.isPaired, syncState.healthAuthorized else { return }
        startRuntime()
        if syncState.pendingUnlock {
            Task { await syncNow(budget: .foreground) }
        }
    }

    func sceneWentBackground() {
        background.stopForegroundTimer()
        background.scheduleRefresh()
    }

    func syncNow(budget: SyncBudget = .foreground) async {
        guard pairing.isPaired else { return }
        if !HealthKitAuthorizer.isAvailable {
            lastError = SyncError.healthUnavailable.localizedDescription
            refreshFromStore()
            return
        }
        isBusy = budget == .foreground
        progress = budget == .foreground ? "Syncing…" : nil
        await background.runSync(budget: budget) { [weak self] message in
            self?.progress = message
        }
        progress = nil
        isBusy = false
        refreshFromStore()
        await loadLatestReadings()
    }

    func readingText(for metric: SyncedMetric) -> String {
        latestReadings[metric.rawValue] ?? "—"
    }

    func loadLatestReadings() async {
        guard HealthKitAuthorizer.isAvailable else {
            latestReadings = [:]
            return
        }
        latestReadings = await LatestReadings(store: authorizer.store).load()
    }

    func unpair() {
        background.stopObservers()
        background.stopForegroundTimer()
        pairing.unpair()
        username = nil
        showHealthPrompt = false
        pairingIntent = .none
        latestReadings = [:]
        refreshFromStore()
        route = .home
    }
}
