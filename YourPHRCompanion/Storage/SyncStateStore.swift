import Foundation

/// Non-secret sync bookkeeping. Anchors themselves are in the Keychain (they resume a HealthKit
/// query); these flags just tell the UI and the background retry path what happened last.
final class SyncStateStore {
    static let shared = SyncStateStore()

    private enum Key {
        static let lastSyncAt = "ipc.health.lastSyncAt"
        static let lastError = "ipc.health.lastError"
        static let pendingUnlock = "ipc.health.pendingUnlock"
        static let lastStored = "ipc.health.lastStored"
        static let lastReceived = "ipc.health.lastReceived"
        static let lookbackDays = "ipc.health.lookbackDays"
        static let healthAuthorized = "ipc.health.healthAuthorized"
        static let postedStepDays = "ipc.health.postedStepDays"
    }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastSyncAt: Date? {
        get { defaults.object(forKey: Key.lastSyncAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSyncAt) }
    }

    var lastError: String? {
        get { defaults.string(forKey: Key.lastError) }
        set { defaults.set(newValue, forKey: Key.lastError) }
    }
	
    /// Observer fired while the HealthKit store was encrypted. Retry on unlock / foreground.
    var pendingUnlock: Bool {
        get { defaults.bool(forKey: Key.pendingUnlock) }
        set { defaults.set(newValue, forKey: Key.pendingUnlock) }
    }

    var lastStored: Int {
        get { defaults.integer(forKey: Key.lastStored) }
        set { defaults.set(newValue, forKey: Key.lastStored) }
    }

    var lastReceived: Int {
        get { defaults.integer(forKey: Key.lastReceived) }
        set { defaults.set(newValue, forKey: Key.lastReceived) }
    }

    /// First-run backfill window. Default 30 days — a year of 5-minute HR is ~21 batches and
    /// belongs in the foreground, not on a 30-second background wake.
    var lookbackDays: Int {
        get {
            let value = defaults.integer(forKey: Key.lookbackDays)
            return value > 0 ? value : 30
        }
        set { defaults.set(newValue, forKey: Key.lookbackDays) }
    }

    var healthAuthorized: Bool {
        get { defaults.bool(forKey: Key.healthAuthorized) }
        set { defaults.set(newValue, forKey: Key.healthAuthorized) }
    }

    /// Local days whose step total was accepted. A later empty day retracts that total.
    var postedStepDays: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.postedStepDays) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.postedStepDays) }
    }

    func recordSuccess(received: Int, stored: Int) {
        lastSyncAt = Date()
        lastError = nil
        pendingUnlock = false
        lastReceived = received
        lastStored = stored
    }

    func recordFailure(_ message: String, pendingUnlock: Bool = false) {
        lastError = message
        self.pendingUnlock = pendingUnlock
    }

    func clear() {
        [Key.lastSyncAt, Key.lastError, Key.pendingUnlock, Key.lastStored, Key.lastReceived, Key.healthAuthorized, Key.postedStepDays].forEach {
            defaults.removeObject(forKey: $0)
        }
    }
}

/// Local HKQueryAnchor blobs, keyed by HealthKit type identifier (not metric type). The server
/// stores the same blobs keyed by metric type; both maps are kept in sync after a successful POST.
struct AnchorStore {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
    }

    func loadAll() -> [String: String] {
        guard let raw = keychain.get(account: KeychainStore.Account.anchors),
              let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return map
    }

    func saveAll(_ map: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        guard let raw = String(data: data, encoding: .utf8) else { return }
        try keychain.set(raw, account: KeychainStore.Account.anchors)
    }

    func set(identifier: String, base64: String) throws {
        var map = loadAll()
        map[identifier] = base64
        try saveAll(map)
    }

    func get(identifier: String) -> String? {
        loadAll()[identifier]
    }

    func mergeServerStates(_ states: [RemoteSyncState]) throws {
        var map = loadAll()
        for state in states where !state.anchor.isEmpty {
            if let metric = SyncedMetric(rawValue: state.metricType) {
                if map[metric.hkTypeIdentifier] == nil {
                    map[metric.hkTypeIdentifier] = state.anchor
                }
            }
        }
        try saveAll(map)
    }
}
