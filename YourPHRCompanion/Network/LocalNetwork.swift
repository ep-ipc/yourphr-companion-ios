import Foundation
import Network

/// Whether a pairing URL is on the local network, where iOS requires Local Network permission.
enum LocalNetworkHost {
    static func isLocal(_ url: URL?) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") { return isLocalIPv6(host) }
        if !host.contains(".") { return true }
        return isLocalIPv4(host)
    }

    /// Host, and port when the URL has one, for the error the person sees.
    static func label(for url: URL) -> String {
        let host = normalizedHost(url) ?? "the server"
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    private static func normalizedHost(_ url: URL?) -> String? {
        guard let raw = url?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func isLocalIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        let first = Int(octets[0]) ?? -1
        let second = Int(octets[1]) ?? -1
        if first == 10 || first == 127 || first == 0 { return true }
        if first == 192 && second == 168 { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16 ... 31).contains(second) { return true }
        return false
    }

    /// Link-local (fe80::/10), unique-local (fc00::/7), and loopback.
    private static func isLocalIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") {
            return true
        }
        return false
    }
}

/// One granted check per process. Repeating the Bonjour trigger on every sample upload is
/// unnecessary once Local Network access is allowed.
actor LocalNetworkGate {
    static let shared = LocalNetworkGate()
    private var granted = false

    func authorize(_ url: URL) async throws {
        guard LocalNetworkHost.isLocal(url) else { return }
        if granted { return }
        let allowed = await LocalNetworkAuthorization().request()
        if allowed {
            granted = true
            return
        }
        throw APIClientError.localNetworkDenied(LocalNetworkHost.label(for: url))
    }

    func revoke() {
        granted = false
    }
}

/// Shows the Local Network prompt and waits for the answer.
///
/// A TCP connection to a LAN IP is denied at once, the app never appears under
/// Settings → Privacy & Security → Local Network, and iOS reports the internet as offline.
/// Publishing and browsing `_yourphr._tcp` — the type listed in `NSBonjourServices` — is what
/// presents the prompt. The operations stay running until Allow (`netServiceDidPublish` or a
/// ready browser) or Don't Allow. Cancelling early is what skipped the prompt.
final class LocalNetworkAuthorization: NSObject, NetServiceDelegate {
    /// Matches `NSBonjourServices` in Info.plist. NetService wants the trailing dot.
    private static let serviceType = "_yourphr._tcp."
    private static let policyDenied: Int32 = -65570

    private var browser: NWBrowser?
    private var service: NetService?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var denialArmed = false

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.begin(continuation)
            }
        }
    }

    @MainActor
    private func begin(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation

        let browser = NWBrowser(for: .bonjour(type: "_yourphr._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        browser.start(queue: .main)

        let name = "ipc-\(UUID().uuidString.prefix(8))"
        let service = NetService(domain: "local.", type: Self.serviceType, name: name, port: 9)
        self.service = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.publish()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            self?.finish(false)
        }
    }

    @MainActor
    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            finish(true)
        case .waiting(let error), .failed(let error):
            if Self.isPolicyDenied(error) {
                armDenialTimeout()
            }
        default:
            break
        }
    }

    /// Policy-denied is also reported while the prompt is on screen. Keep the browse alive
    /// long enough for Allow to publish the service, then give up.
    @MainActor
    private func armDenialTimeout() {
        guard !denialArmed else { return }
        denialArmed = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
            self?.finish(false)
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in self.finish(true) }
    }

    @MainActor
    private func finish(_ allowed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.cancel()
        browser = nil
        service?.stop()
        service = nil
        continuation.resume(returning: allowed)
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == policyDenied { return true }
        return false
    }
}
