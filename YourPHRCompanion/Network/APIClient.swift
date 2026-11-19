import Foundation

enum APIClientError: LocalizedError, Equatable {
    case notPaired
    case invalidURL(String)
    case httpStatus(Int, String)
    case apiError(String)
    case emptyResponse
    case permissionEnded(String)
    case paused(String)
    case refreshInterrupted
    case rateLimited(String)
    case healthDisabled
    /// Local Network permission is off, so iOS reports the LAN address as offline.
    case localNetworkDenied(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "This phone is not paired with a YourPHR instance."
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .httpStatus(let code, let body): return "Server returned \(code): \(body)"
        case .apiError(let message): return message
        case .emptyResponse: return "The server returned an empty response."
        case .permissionEnded(let message):
            return message.isEmpty
                ? "This phone is no longer allowed to add to the record. Add the device again in Settings → Connected devices."
                : message
        case .paused(let message):
            return message.isEmpty
                ? "This phone is paused. Resume it in Settings → Connected devices."
                : message
        case .refreshInterrupted:
            return "The connection dropped while refreshing this phone’s key. Add the device again in Settings → Connected devices so the key is not sent twice."
        case .rateLimited(let message):
            return message.isEmpty ? "YourPHR asked this phone to wait, then try again." : message
        case .healthDisabled:
            return "YourPHR is not accepting health samples. Turn on Connected devices and Health, then sync again."
        case .localNetworkDenied(let host):
            return "iOS blocked YourPHR Companion from reaching \(host) on the local network. Tap Allow if asked to find devices on your local network. YourPHR Companion appears under Settings → Privacy & Security → Local Network only after that prompt."
        }
    }
}

/// URLSession client for the device grant and the health sample routes.
/// `baseURL` is the API root (`https://host/api`).
final class APIClient {
    var baseURL: String
    var token: String
    private let session: URLSession

    init(baseURL: String, token: String, session: URLSession = .shared) {
        self.baseURL = PairingPayload.normalizeBaseURL(baseURL)
        self.token = token
        self.session = session
    }

    func claim(_ code: String) async throws -> DeviceGrant {
        let envelope: APIEnvelope<DeviceGrant> = try await post(
            path: "/device/claim",
            body: ClaimBody(code: code),
            authorize: false,
            call: .claim
        )
        return try unwrap(envelope)
    }

    func refreshDevice(_ refreshToken: String) async throws -> DeviceGrant {
        let envelope: APIEnvelope<DeviceGrant> = try await post(
            path: "/device/token",
            body: RefreshBody(refreshToken: refreshToken),
            authorize: false,
            call: .refresh
        )
        return try unwrap(envelope)
    }

    func getSyncStates(deviceID: String?) async throws -> [RemoteSyncState] {
        var path = "/secure/health/sync-state"
        if let deviceID, !deviceID.isEmpty {
            path += "?device_id=\(deviceID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceID)"
        }
        let envelope: APIEnvelope<[RemoteSyncState]> = try await get(path: path)
        return try unwrap(envelope)
    }

    func ingest(_ request: HealthSampleIngestRequest) async throws -> HealthSampleIngestResponse {
        let envelope: APIEnvelope<HealthSampleIngestResponse> = try await post(
            path: "/secure/health/samples",
            body: request,
            authorize: true,
            call: .upload
        )
        return try unwrap(envelope)
    }

    private struct ClaimBody: Encodable {
        var code: String
    }

    private struct RefreshBody: Encodable {
        var refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private enum Call {
        case claim
        case refresh
        case upload
    }

    private func unwrap<T>(_ envelope: APIEnvelope<T>) throws -> T {
        guard envelope.success else {
            throw APIClientError.apiError(envelope.error ?? "request failed")
        }
        guard let data = envelope.data else { throw APIClientError.emptyResponse }
        return data
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", body: nil, authorize: true)
        return try await send(request, call: .upload)
    }

    private func post<Body: Encodable, T: Decodable>(path: String, body: Body, authorize: Bool, call: Call) async throws -> T {
        let data = try APIJSON.encoder.encode(body)
        let request = try makeRequest(path: path, method: "POST", body: data, authorize: authorize)
        return try await send(request, call: call)
    }

    private func makeRequest(path: String, method: String, body: Data?, authorize: Bool) throws -> URLRequest {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else { throw APIClientError.invalidURL(urlString) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if authorize, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, call: Call) async throws -> T {
        if let url = request.url {
            try await LocalNetworkGate.shared.authorize(url)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let url = request.url, LocalNetworkHost.isLocal(url), Self.isReportedOffline(error) {
                await LocalNetworkGate.shared.revoke()
                throw APIClientError.localNetworkDenied(LocalNetworkHost.label(for: url))
            }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, call == .upload {
            throw APIClientError.healthDisabled
        }
        if status == 401 || status == 403 || status == 429 {
            throw try refusal(status: status, data: data, call: call)
        }
        if status >= 400 {
            throw APIClientError.apiError(message(from: data, fallback: "Server returned \(status)"))
        }
        return try APIJSON.decoder.decode(T.self, from: data)
    }

    private func refusal(status: Int, data: Data, call: Call) throws -> APIClientError {
        let text = message(from: data, fallback: "")
        if call == .refresh {
            if status == 401 { return .permissionEnded(text) }
            if status == 403, text.lowercased().hasPrefix("paused") { return .paused(text) }
            if status == 429 { return .rateLimited(text) }
        }
        if status == 429 { return .rateLimited(text) }
        if call == .claim, status == 401 {
            return .apiError(text.isEmpty ? "That setup code is not valid. Ask for a new one in Connected devices." : text)
        }
        return .httpStatus(status, text)
    }

    /// URLSession uses this for a LAN address when Local Network access is denied.
    private static func isReportedOffline(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isReportedOffline(underlying)
        }
        return false
    }

    private func message(from data: Data, fallback: String) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorBody.self, from: data),
           let error = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty ? fallback : body
    }

    private struct ErrorBody: Decodable {
        var error: String?
    }
}
