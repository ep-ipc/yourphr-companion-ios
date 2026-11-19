import Foundation
import HealthKit

/// Metrics this companion syncs. Canonical identity on the server is LOINC; HealthKit type
/// identifiers are vendor keys that the catalog maps into the same Observation.
enum SyncedMetric: String, CaseIterable, Equatable {
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability_sdnn"
    case bloodPressureSystolic = "blood_pressure_systolic"
    case bloodPressureDiastolic = "blood_pressure_diastolic"
    case stepCount = "step_count"
    case bodyMass = "body_mass"
    case oxygenSaturation = "oxygen_saturation"
    case bodyTemperature = "body_temperature"
    case sleepStage = "sleep_stage"

    /// Exact HealthKit type identifier, e.g. `HKQuantityTypeIdentifierHeartRate`.
    var hkTypeIdentifier: String {
        switch self {
        case .heartRate: return HKQuantityTypeIdentifier.heartRate.rawValue
        case .restingHeartRate: return HKQuantityTypeIdentifier.restingHeartRate.rawValue
        case .heartRateVariability: return HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        case .bloodPressureSystolic: return HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        case .bloodPressureDiastolic: return HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
        case .stepCount: return HKQuantityTypeIdentifier.stepCount.rawValue
        case .bodyMass: return HKQuantityTypeIdentifier.bodyMass.rawValue
        case .oxygenSaturation: return HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        case .bodyTemperature: return HKQuantityTypeIdentifier.bodyTemperature.rawValue
        case .sleepStage: return HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        }
    }

    /// LOINC code the Observation carries. BP halves resolve to the panel.
    var loinc: String {
        switch self {
        case .heartRate: return "8867-4"
        case .restingHeartRate: return "40443-4"
        case .heartRateVariability: return "80404-7"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "85354-9"
        case .stepCount: return "55423-8"
        case .bodyMass: return "29463-7"
        case .oxygenSaturation: return "59408-5"
        case .bodyTemperature: return "8310-5"
        case .sleepStage: return "93828-2"
        }
    }

    var loincDisplay: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .heartRateVariability: return "Heart rate variability SDNN"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "Blood pressure panel"
        case .stepCount: return "Number of steps"
        case .bodyMass: return "Body weight"
        case .oxygenSaturation: return "Oxygen saturation"
        case .bodyTemperature: return "Body temperature"
        case .sleepStage: return "Awake"
        }
    }

    /// Observation.category code.
    var observationCategory: String {
        switch self {
        case .stepCount: return "activity"
        case .sleepStage: return "activity"
        default: return "vital-signs"
        }
    }

    /// UCUM code posted on valueQuantity. HealthKit's own unitString differs for HR, steps, temp.
    var fhirUnit: String {
        switch self {
        case .heartRate, .restingHeartRate: return "/min"
        case .heartRateVariability: return "ms"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mm[Hg]"
        case .stepCount: return "{steps}"
        case .bodyMass: return "kg"
        case .oxygenSaturation: return "%"
        case .bodyTemperature: return "Cel"
        case .sleepStage: return ""
        }
    }

    /// Second coding, after the canonical one. Pulse oximetry posts `59408-5` then `2708-6`.
    var alsoLoinc: [String] {
        switch self {
        case .oxygenSaturation: return ["2708-6"]
        default: return []
        }
    }

    var isQuantity: Bool { self != .sleepStage }
    var isBloodPressureHalf: Bool {
        self == .bloodPressureSystolic || self == .bloodPressureDiastolic
    }

    var displayName: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .heartRateVariability: return "Heart-rate variability"
        case .bloodPressureSystolic: return "Blood pressure (systolic)"
        case .bloodPressureDiastolic: return "Blood pressure (diastolic)"
        case .stepCount: return "Steps"
        case .bodyMass: return "Weight"
        case .oxygenSaturation: return "Oxygen saturation"
        case .bodyTemperature: return "Body temperature"
        case .sleepStage: return "Sleep"
        }
    }

    static func from(hkTypeIdentifier: String) -> SyncedMetric? {
        allCases.first { $0.hkTypeIdentifier == hkTypeIdentifier }
    }

    /// Anchored quantity and category queries. Steps are a daily statistics total instead:
    /// the phone and the watch both record steps, and sending both would add them.
    static var anchoredMetrics: [SyncedMetric] { allCases.filter { $0 != .stepCount } }

    static var bloodPressureCorrelationIdentifier: String {
        HKCorrelationTypeIdentifier.bloodPressure.rawValue
    }
}

enum SleepStageValue {
    /// LOINC stage the server rolls up. In bed (`0`) and unspecified (`1`) stay off the wire.
    static func loinc(rawValue: Int) -> (code: String, display: String)? {
        switch rawValue {
        case 2: return ("93828-2", "Awake")
        case 3: return ("93830-8", "Core sleep")
        case 4: return ("93831-6", "Deep sleep")
        case 5: return ("93829-0", "REM sleep")
        default: return nil
        }
    }

    static func loinc(sampleValue: HKCategoryValueSleepAnalysis) -> (code: String, display: String)? {
        loinc(rawValue: sampleValue.rawValue)
    }
}

enum OffsetTimestamp {
    /// RFC 3339 with an explicit offset. UTC is `Z`; every other zone keeps its offset.
    static func string(from date: Date, timeZone: TimeZone) -> String {
        if timeZone.secondsFromGMT(for: date) == 0 {
            return ISO8601DateFormatter.api.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }
}
