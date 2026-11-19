import Foundation

/// Pairing claims a one-time setup code, then reads sync state with the new access token.
final class PairingService {
    private let keychain: KeychainStore
    private let anchors: AnchorStore
    private let syncState: SyncStateStore
    private let refreshGate = RefreshGate()

    init(keychain: KeychainStore = .shared, anchors: AnchorStore = AnchorStore(), syncState: SyncStateStore = .shared) {
        self.keychain = keychain
        self.anchors = anchors
        self.syncState = syncState
    }

    var isPaired: Bool {
        guard let token = keychain.get(account: KeychainStore.Account.token), !token.isEmpty,
              let refresh = keychain.get(account: KeychainStore.Account.refreshToken), !refresh.isEmpty,
              let url = keychain.get(account: KeychainStore.Account.baseURL), !url.isEmpty else {
            return false
        }
        return true
    }

    func makeClient() throws -> APIClient {
        guard let token = keychain.get(account: KeychainStore.Account.token),
              let url = keychain.get(account: KeychainStore.Account.baseURL) else {
            throw APIClientError.notPaired
        }
        return APIClient(baseURL: url, token: token)
    }

    /// A client whose access token is not about to expire. Refreshing does not count as activity.
    func clientForUpload() async throws -> APIClient {
        if keychain.accessTokenNeedsRefresh() {
            try await refreshGrant()
        }
        return try makeClient()
    }

    /// Called after an upload returns 401. One refresh, then the caller retries the upload once.
    func clientAfterUnauthorized() async throws -> APIClient {
        try await refreshGrant()
        return try makeClient()
    }

    func pair(payload: PairingPayload) async throws -> DeviceGrant {
        let client = APIClient(baseURL: payload.server, token: "")
        let grant = try await client.claim(payload.code)
        try keychain.commitGrant(grant, server: payload.server)
        try keychain.set(grant.label, account: KeychainStore.Account.username)
        _ = try keychain.deviceID()

        let authed = try makeClient()
        if let states = try? await authed.getSyncStates(deviceID: nil) {
            try? anchors.mergeServerStates(states)
        }
        return grant
    }

    func unpair() {
        keychain.removeAll()
        syncState.clear()
    }

    private func refreshGrant() async throws {
        try await refreshGate.run { [self] in
            try await self.performRefresh()
        }
    }

    private func performRefresh() async throws {
        let refreshToken = try keychain.beginPresentedRefresh()
        let client = try makeClient()
        do {
            let grant = try await client.refreshDevice(refreshToken)
            try keychain.commitGrant(grant)
            if !grant.label.isEmpty {
                try keychain.set(grant.label, account: KeychainStore.Account.username)
            }
        } catch let error as APIClientError {
            switch error {
            case .paused, .rateLimited, .localNetworkDenied:
                keychain.clearPresentedRefresh()
                throw error
            case .permissionEnded:
                throw error
            default:
                throw APIClientError.refreshInterrupted
            }
        } catch {
            throw APIClientError.refreshInterrupted
        }
    }
}

/// One refresh at a time. A second caller waits for the first instead of presenting the same token.
private actor RefreshGate {
    private var task: Task<Void, Error>?

    func run(_ body: @escaping () async throws -> Void) async throws {
        if let existing = task {
            try await existing.value
            return
        }
        let created = Task { try await body() }
        task = created
        defer { task = nil }
        try await created.value
    }
}
