import Foundation
import HealthKit

/// The scale shown beside a health type. Weight and temperature follow the phone's Health preference.
enum ReadingDisplayUnit: Equatable {
    case beatsPerMinute
    case milliseconds
    case millimetersOfMercury
    case steps
    case kilograms
    case pounds
    case percent
    case celsius
    case fahrenheit

    static func resolve(metric: SyncedMetric, preferred: HKUnit?) -> ReadingDisplayUnit {
        switch metric {
        case .heartRate, .restingHeartRate:
            return .beatsPerMinute
        case .heartRateVariability:
            return .milliseconds
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return .millimetersOfMercury
        case .stepCount:
            return .steps
        case .bodyMass:
            if preferred == HKUnit.pound() { return .pounds }
            return .kilograms
        case .oxygenSaturation:
            return .percent
        case .bodyTemperature:
            if preferred == HKUnit.degreeFahrenheit() { return .fahrenheit }
            return .celsius
        case .sleepStage:
            return .celsius
        }
    }

    var hkUnit: HKUnit {
        switch self {
        case .beatsPerMinute:
            return HKUnit.count().unitDivided(by: .minute())
        case .milliseconds:
            return .secondUnit(with: .milli)
        case .millimetersOfMercury:
            return .millimeterOfMercury()
        case .steps:
            return .count()
        case .kilograms:
            return .gramUnit(with: .kilo)
        case .pounds:
            return .pound()
        case .percent:
            return .percent()
        case .celsius:
            return .degreeCelsius()
        case .fahrenheit:
            return .degreeFahrenheit()
        }
    }
}

enum LatestReadingFormat {
    /// HealthKit stores oxygen as a fraction. A value of 1 or less is scaled to a percent.
    static func quantity(_ value: Double, unit: ReadingDisplayUnit, locale: Locale = .current) -> String {
        switch unit {
        case .beatsPerMinute:
            return "\(rounded(value, fractionDigits: 0, locale: locale)) bpm"
        case .milliseconds:
            return "\(rounded(value, fractionDigits: 0, locale: locale)) ms"
        case .millimetersOfMercury:
            return "\(rounded(value, fractionDigits: 0, locale: locale)) mmHg"
        case .steps:
            return "\(rounded(value, fractionDigits: 0, locale: locale)) steps"
        case .kilograms:
            return "\(rounded(value, fractionDigits: 1, locale: locale)) kg"
        case .pounds:
            return "\(rounded(value, fractionDigits: 1, locale: locale)) lb"
        case .percent:
            let scaled = value >= 0 && value <= 1 ? value * 100 : value
            return "\(rounded(scaled, fractionDigits: 0, locale: locale))%"
        case .celsius:
            return "\(rounded(value, fractionDigits: 1, locale: locale)) °C"
        case .fahrenheit:
            return "\(rounded(value, fractionDigits: 1, locale: locale)) °F"
        }
    }

    static func sleep(rawValue: Int) -> String? {
        switch rawValue {
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            return "In bed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return "Asleep"
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return "Awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return "Core sleep"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return "Deep sleep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return "REM sleep"
        default:
            return nil
        }
    }

    private static func rounded(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Most recent HealthKit reading for each synced type. Steps are the latest daily total,
/// because a single step sample is only an increment.
struct LatestReadings {
    var store: HKHealthStore
    var lookbackDays: Int = 30

    func load() async -> [String: String] {
        let quantityTypes = Set(SyncedMetric.allCases.compactMap { quantityType(for: $0) })
        let preferred = (try? await store.preferredUnits(for: quantityTypes)) ?? [:]
        var readings: [String: String] = [:]
        for metric in SyncedMetric.allCases {
            if let text = await reading(for: metric, preferred: preferred) {
                readings[metric.rawValue] = text
            }
        }
        return readings
    }

    private func reading(for metric: SyncedMetric, preferred: [HKQuantityType: HKUnit]) async -> String? {
        if metric == .stepCount {
            guard let steps = try? await latestStepTotal() else { return nil }
            return LatestReadingFormat.quantity(steps, unit: .steps)
        }
        if metric == .sleepStage {
            guard let sample = try? await latestSample(for: metric) as? HKCategorySample else { return nil }
            return LatestReadingFormat.sleep(rawValue: sample.value)
        }
        guard let sample = try? await latestSample(for: metric) as? HKQuantitySample else { return nil }
        let unit = ReadingDisplayUnit.resolve(metric: metric, preferred: preferred[sample.quantityType])
        let value = sample.quantity.doubleValue(for: unit.hkUnit)
        return LatestReadingFormat.quantity(value, unit: unit)
    }

    private func latestSample(for metric: SyncedMetric) async throws -> HKSample? {
        guard let sampleType = sampleType(for: metric) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples?.first)
            }
            store.execute(query)
        }
    }

    private func latestStepTotal() async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -lookbackDays, to: calendar.startOfDay(for: end)) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: calendar.startOfDay(for: end),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var latest: Double?
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    if let sum = statistics.sumQuantity()?.doubleValue(for: .count()) {
                        latest = sum
                    }
                }
                continuation.resume(returning: latest)
            }
            store.execute(query)
        }
    }

    private func quantityType(for metric: SyncedMetric) -> HKQuantityType? {
        guard metric.isQuantity else { return nil }
        return HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.hkTypeIdentifier))
    }

    private func sampleType(for metric: SyncedMetric) -> HKSampleType? {
        if let quantity = quantityType(for: metric) { return quantity }
        return HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.hkTypeIdentifier))
    }
}
