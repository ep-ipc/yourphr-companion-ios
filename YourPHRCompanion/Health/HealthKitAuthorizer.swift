import Foundation
import HealthKit

enum HealthKitAuthorizerError: LocalizedError {
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this device. Pairing still works; syncing needs a physical iPhone."
        case .denied:
            return "Health access was not granted. Enable the types you want in Settings → Health → Data Access."
        }
    }
}

final class HealthKitAuthorizer {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Types passed to `requestAuthorization`. Correlation types are excluded: HealthKit throws
    /// `NSInvalidArgumentException` if you ask to read `HKCorrelationTypeIdentifierBloodPressure`.
    /// Authorize the contained quantity types instead; queries for the correlation then succeed.
    static var readTypes: Set<HKObjectType> {
        Set(metricSampleTypes.map { $0 as HKObjectType })
    }

    /// Anchored queries, including the blood-pressure correlation so a cuff reading is one
    /// Observation with components. Step count is queried as a daily total instead.
    /// Do not pass this set to `requestAuthorization`.
    static var sampleTypesForQuery: [HKSampleType] {
        var types = sampleTypes(for: SyncedMetric.anchoredMetrics)
        if let correlation = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) {
            types.append(correlation)
        }
        return types
    }

    /// `enableBackgroundDelivery` accepts quantity, category, and workout types only — not correlations.
    /// Systolic/diastolic observers still wake the app when a cuff reading is saved. Steps stay
    /// here so a new step count wakes a statistics sync.
    static var backgroundDeliveryTypes: [HKSampleType] { sampleTypes(for: SyncedMetric.allCases) }

    private static var metricSampleTypes: [HKSampleType] { sampleTypes(for: SyncedMetric.allCases) }

    private static func sampleTypes(for metrics: [SyncedMetric]) -> [HKSampleType] {
        metrics.compactMap { metric in
            if metric.isQuantity {
                return HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.hkTypeIdentifier))
            }
            return HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.hkTypeIdentifier))
        }
    }

    func requestReadAccess() async throws {
        guard Self.isAvailable else { throw HealthKitAuthorizerError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        // HealthKit does not tell us which types the user actually granted (by design). Treat the
        // sheet completing as authorized; individual queries will return empty for denied types.
        SyncStateStore.shared.healthAuthorized = true
    }

    func authorizationStatus(for metric: SyncedMetric) -> HKAuthorizationStatus {
        if metric.isQuantity,
           let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.hkTypeIdentifier)) {
            return store.authorizationStatus(for: type)
        }
        if let type = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.hkTypeIdentifier)) {
            return store.authorizationStatus(for: type)
        }
        return .notDetermined
    }
}
