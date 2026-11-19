import Foundation

/// JSON envelope every YourPHR handler returns.
struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
}

/// Keys from `POST /device/claim` and `POST /device/token`.
struct DeviceGrant: Decodable, Equatable {
    var accessToken: String
    var tokenType: String
    var expiresIn: Int
    var refreshToken: String
    var grantEndsAt: String
    var label: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case grantEndsAt = "grant_ends_at"
        case label
    }
}

/// Matches `HealthDeviceInfo` in the ingest handler.
struct HealthDeviceInfo: Codable, Equatable {
    var deviceID: String
    var name: String
    var osVersion: String
    var appVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}

enum FHIRSystem {
    static let loinc = "http://loinc.org"
    static let ucum = "http://unitsofmeasure.org"
    static let observationCategory = "http://terminology.hl7.org/CodeSystem/observation-category"
    static let uuid = "urn:uuid"
}

struct FHIRCoding: Codable, Equatable {
    var system: String
    var code: String
    var display: String? = nil
}

struct CodeableConcept: Codable, Equatable {
    var coding: [FHIRCoding]
}

struct FHIRIdentifier: Codable, Equatable {
    var system: String
    var value: String
}

struct FHIRQuantity: Codable, Equatable {
    var value: Double
    var unit: String
    var system: String = FHIRSystem.ucum
    var code: String
}

struct FHIRPeriod: Codable, Equatable {
    var start: String
    var end: String
}

struct FHIRComponent: Codable, Equatable {
    var code: CodeableConcept
    var valueQuantity: FHIRQuantity
}

struct FHIRDeviceRef: Codable, Equatable {
    var display: String
}

struct FHIRMeta: Codable, Equatable {
    var source: String
}

/// Observation-shaped ingest body. The server still accepts the older HealthKit DTO, but this
/// companion maps locally (HealthKitOnFHIR-style) so Android Health Connect can POST the same shape.
struct HealthSampleInput: Codable, Equatable {
    var resourceType: String = "Observation"
    var status: String = "final"
    var identifier: [FHIRIdentifier]
    var category: [CodeableConcept]? = nil
    /// Absent on a deletion, which names the sample by identifier only.
    var code: CodeableConcept? = nil
    var effectiveDateTime: String? = nil
    var effectivePeriod: FHIRPeriod? = nil
    var valueQuantity: FHIRQuantity? = nil
    var valueCodeableConcept: CodeableConcept? = nil
    var component: [FHIRComponent]? = nil
    var device: FHIRDeviceRef? = nil
    var meta: FHIRMeta? = nil
    var sourceBundleID: String? = nil

    enum CodingKeys: String, CodingKey {
        case resourceType, status, identifier, category, code
        case effectiveDateTime, effectivePeriod, valueQuantity, valueCodeableConcept
        case component, device, meta
        case sourceBundleID = "source_bundle_id"
    }
}

struct HealthSampleIngestRequest: Codable, Equatable {
    var device: HealthDeviceInfo
    var samples: [HealthSampleInput]
    var anchors: [String: String]
}

struct HealthSampleRejection: Codable, Equatable {
    var uuid: String
    var type: String
    var reason: String
}

struct HealthSampleIngestResponse: Codable, Equatable {
    var received: Int
    var accepted: Int
    var stored: Int64
    var duplicates: Int64
    var rejected: Int
    var errors: [HealthSampleRejection]?
}

/// One row from `GET /api/secure/health/sync-state`.
struct RemoteSyncState: Decodable, Equatable {
    var deviceID: String
    var metricType: String
    var anchor: String
    var deviceName: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case metricType = "metric_type"
        case anchor
        case deviceName = "device_name"
    }
}

enum APIJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(ISO8601DateFormatter.api.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.api.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not RFC3339: \(raw)")
        }
        return decoder
    }()
}

extension ISO8601DateFormatter {
    static let api: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
