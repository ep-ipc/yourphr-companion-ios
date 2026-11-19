import Foundation

/// The setup QR and the `yourphr-device://claim` link from Settings → Connected devices.
struct PairingPayload: Equatable {
    /// API root, including `/api`. Paths are appended to this.
    var server: String
    var code: String
}

enum PairingPayloadError: LocalizedError, Equatable {
    case empty
    case notJSON
    case missingCode
    case missingServer

    var errorDescription: String? {
        switch self {
        case .empty: return "Paste a setup code, or scan the QR from Connected devices."
        case .notJSON: return "That QR is not a YourPHR device setup."
        case .missingCode: return "The setup code is missing."
        case .missingServer: return "The setup payload has no server."
        }
    }
}

extension PairingPayload {
    /// JSON `{ "v": 1, "server": "https://host/api", "code": "yphr_setup_…" }` or the claim link.
    static func parseQR(_ raw: String) throws -> PairingPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PairingPayloadError.empty }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "yourphr-device" {
            return try parse(url)
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PairingPayloadError.notJSON
        }
        guard let code = stringValue(object["code"]), code.hasPrefix("yphr_setup_") else {
            throw PairingPayloadError.missingCode
        }
        guard let server = stringValue(object["server"]) else {
            throw PairingPayloadError.missingServer
        }
        return PairingPayload(server: apiBase(server), code: code)
    }

    static func parse(_ url: URL) throws -> PairingPayload {
        guard url.scheme?.lowercased() == "yourphr-device" else { throw PairingPayloadError.notJSON }
        guard url.host?.lowercased() == "claim" else { throw PairingPayloadError.notJSON }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let server = items.first { $0.name == "server" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard code.hasPrefix("yphr_setup_") else { throw PairingPayloadError.missingCode }
        guard !server.isEmpty else { throw PairingPayloadError.missingServer }
        return PairingPayload(server: apiBase(server), code: code)
    }

    /// Manual pairing: the API base (or the site origin) and the one-time setup code.
    static func parseManual(baseURL: String, code: String) throws -> PairingPayload {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let setup = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw PairingPayloadError.missingServer }
        guard setup.hasPrefix("yphr_setup_") else { throw PairingPayloadError.missingCode }
        return PairingPayload(server: apiBase(url), code: setup)
    }

    static func normalizeBaseURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// `server` in the QR already includes `/api`. A pasted site origin gets that suffix.
    static func apiBase(_ raw: String) -> String {
        let url = normalizeBaseURL(raw)
        if url.hasSuffix("/api") { return url }
        return url + "/api"
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let value = any as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
