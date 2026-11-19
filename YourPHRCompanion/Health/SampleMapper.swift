import Foundation
import HealthKit

enum Batching {
    static let maxBatch = 5000

    static func split<T>(_ items: [T], size: Int = maxBatch) -> [[T]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0 ..< min($0 + size, items.count)])
        }
    }
}

enum AnchorCodec {
    /// HKQueryAnchor is NSSecureCoding. The server stores the blob without interpreting it, so a
    /// reinstalled app can hand the same bytes back to HealthKit.
    static func encode(_ anchor: HKQueryAnchor) -> String {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        return data?.base64EncodedString() ?? ""
    }

    static func decode(_ base64: String) -> HKQueryAnchor? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

enum AnchorPosting {
    /// The server rejects an anchor longer than 1024 characters on the whole request, samples included.
    /// A longer blob stays on the phone. `nil` means "do not send this anchor".
    static func serverBlob(_ blob: String, maxLength: Int = SyncEngine.maxAnchorLength) -> String? {
        guard !blob.isEmpty, blob.count <= maxLength else { return nil }
        return blob
    }

    static func anchors(metric: String?, blob: String, maxLength: Int = SyncEngine.maxAnchorLength) -> [String: String] {
        guard let metric, let accepted = serverBlob(blob, maxLength: maxLength) else { return [:] }
        return [metric: accepted]
    }
}

struct MappedComponent: Equatable {
    var code: String
    var display: String
    var value: Double
    var unit: String
}

/// Intermediate sample used by tests without constructing HKQuantitySample.
struct MappedSample: Equatable {
    var uuid: String
    var hkTypeIdentifier: String
    var metricType: String
    var loinc: String
    var loincDisplay: String
    var category: String
    var start: Date
    var end: Date
    var value: Double? = nil
    var unit: String? = nil
    var valueText: String? = nil
    var valueDisplay: String? = nil
    var components: [MappedComponent] = []
    var sourceName: String? = nil
    var sourceBundleID: String? = nil
    var deviceName: String? = nil
    var alsoLoinc: [String] = []
    var valueSystem: String = FHIRSystem.loinc
    var timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!

    func asInput() -> HealthSampleInput {
        let categoryConcept = CodeableConcept(coding: [
            FHIRCoding(system: FHIRSystem.observationCategory, code: category),
        ])
        var codings = [FHIRCoding(system: FHIRSystem.loinc, code: loinc, display: loincDisplay)]
        codings += alsoLoinc.map { FHIRCoding(system: FHIRSystem.loinc, code: $0) }
        let code = CodeableConcept(coding: codings)
        var input = HealthSampleInput(
            identifier: [FHIRIdentifier(system: FHIRSystem.uuid, value: uuid)],
            category: [categoryConcept],
            code: code
        )
        if start == end {
            input.effectiveDateTime = OffsetTimestamp.string(from: start, timeZone: timeZone)
        } else {
            input.effectivePeriod = FHIRPeriod(
                start: OffsetTimestamp.string(from: start, timeZone: timeZone),
                end: OffsetTimestamp.string(from: end, timeZone: timeZone)
            )
        }
        if !components.isEmpty {
            input.component = components.map { component in
                FHIRComponent(
                    code: CodeableConcept(coding: [
                        FHIRCoding(system: FHIRSystem.loinc, code: component.code, display: component.display),
                    ]),
                    valueQuantity: FHIRQuantity(value: component.value, unit: component.unit, code: component.unit)
                )
            }
        } else if let value, let unit {
            input.valueQuantity = FHIRQuantity(value: value, unit: unit, code: unit)
        } else if let valueText {
            input.valueCodeableConcept = CodeableConcept(coding: [
                FHIRCoding(system: valueSystem, code: valueText, display: valueDisplay),
            ])
        }
        let deviceLabel = deviceName ?? sourceName
        if let deviceLabel, !deviceLabel.isEmpty {
            input.device = FHIRDeviceRef(display: deviceLabel)
        }
        if let sourceName, !sourceName.isEmpty {
            input.meta = FHIRMeta(source: sourceName)
        }
        input.sourceBundleID = sourceBundleID
        return input
    }
}

enum SampleMapper {
    static func quantityUnit(for metric: SyncedMetric) -> HKUnit? {
        switch metric {
        case .heartRate, .restingHeartRate:
            return HKUnit.count().unitDivided(by: HKUnit.minute())
        case .heartRateVariability:
            return HKUnit.secondUnit(with: .milli)
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return HKUnit.millimeterOfMercury()
        case .stepCount:
            return HKUnit.count()
        case .bodyMass:
            return HKUnit.gramUnit(with: .kilo)
        case .oxygenSaturation:
            return HKUnit.percent()
        case .bodyTemperature:
            return HKUnit.degreeCelsius()
        case .sleepStage:
            return nil
        }
    }

    /// UCUM code posted on the Observation. HealthKit's unitString is only used to *read* samples.
    static func unitString(for metric: SyncedMetric) -> String {
        metric.fhirUnit
    }

    /// HealthKit % is 0–1; FHIR/UCUM % is 0–100. Observation ingest does not scale on the server.
    static func postedQuantityValue(_ value: Double, metric: SyncedMetric) -> Double {
        if metric == .oxygenSaturation, value >= 0, value <= 1 {
            return (value * 1000).rounded() / 10
        }
        return value
    }

    static func mapQuantity(_ sample: HKQuantitySample, metric: SyncedMetric) -> MappedSample? {
        guard let unit = quantityUnit(for: metric) else { return nil }
        var value = sample.quantity.doubleValue(for: unit)
        value = postedQuantityValue(value, metric: metric)
        return MappedSample(
            uuid: sample.uuid.uuidString.lowercased(),
            hkTypeIdentifier: metric.hkTypeIdentifier,
            metricType: metric.rawValue,
            loinc: metric.loinc,
            loincDisplay: metric.loincDisplay,
            category: metric.observationCategory,
            start: sample.startDate,
            end: sample.endDate,
            value: value,
            unit: metric.fhirUnit,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            deviceName: sample.device?.name,
            alsoLoinc: metric.alsoLoinc,
            timeZone: timeZone(of: sample)
        )
    }

    static func mapCategory(_ sample: HKCategorySample, metric: SyncedMetric) -> MappedSample? {
        guard metric == .sleepStage, let stage = SleepStageValue.loinc(rawValue: sample.value) else {
            return nil
        }
        return MappedSample(
            uuid: sample.uuid.uuidString.lowercased(),
            hkTypeIdentifier: metric.hkTypeIdentifier,
            metricType: metric.rawValue,
            loinc: stage.code,
            loincDisplay: stage.display,
            category: metric.observationCategory,
            start: sample.startDate,
            end: sample.endDate,
            valueText: stage.code,
            valueDisplay: stage.display,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            deviceName: sample.device?.name,
            valueSystem: FHIRSystem.loinc,
            timeZone: timeZone(of: sample)
        )
    }

    /// One cuff reading arrives as an HKCorrelation of two quantity samples. Posted as a single
    /// Observation (LOINC 85354-9) with systolic/diastolic components.
    static func mapBloodPressureCorrelation(_ correlation: HKCorrelation) -> [MappedSample] {
        let mmHg = HKUnit.millimeterOfMercury()
        var sys: Double?
        var dia: Double?
        var sourceName: String?
        var sourceBundleID: String?
        var deviceName: String?
        for object in correlation.objects {
            guard let quantity = object as? HKQuantitySample else { continue }
            if quantity.quantityType == HKQuantityType(.bloodPressureSystolic) {
                sys = quantity.quantity.doubleValue(for: mmHg)
            } else if quantity.quantityType == HKQuantityType(.bloodPressureDiastolic) {
                dia = quantity.quantity.doubleValue(for: mmHg)
            }
            sourceName = sourceName ?? quantity.sourceRevision.source.name
            sourceBundleID = sourceBundleID ?? quantity.sourceRevision.source.bundleIdentifier
            deviceName = deviceName ?? quantity.device?.name
        }
        var components: [MappedComponent] = []
        if let sys {
            components.append(MappedComponent(code: "8480-6", display: "Systolic blood pressure", value: sys, unit: "mm[Hg]"))
        }
        if let dia {
            components.append(MappedComponent(code: "8462-4", display: "Diastolic blood pressure", value: dia, unit: "mm[Hg]"))
        }
        guard !components.isEmpty else { return [] }
        return [MappedSample(
            uuid: correlation.uuid.uuidString.lowercased(),
            hkTypeIdentifier: SyncedMetric.bloodPressureCorrelationIdentifier,
            metricType: "blood_pressure",
            loinc: "85354-9",
            loincDisplay: "Blood pressure panel",
            category: "vital-signs",
            start: correlation.startDate,
            end: correlation.endDate,
            unit: "mm[Hg]",
            components: components,
            sourceName: sourceName,
            sourceBundleID: sourceBundleID,
            deviceName: deviceName,
            timeZone: timeZone(of: correlation)
        )]
    }

    /// Pure helper for tests: fold systolic/diastolic halves into one panel Observation.
    static func mergeBloodPressure(uuid: String, samples: [MappedSample]) -> [MappedSample] {
        var sys: MappedSample?
        var dia: MappedSample?
        var rest: [MappedSample] = []
        for sample in samples {
            if sample.metricType == SyncedMetric.bloodPressureSystolic.rawValue {
                sys = sample
            } else if sample.metricType == SyncedMetric.bloodPressureDiastolic.rawValue {
                dia = sample
            } else {
                rest.append(sample)
            }
        }
        guard sys != nil || dia != nil else { return samples }
        var components: [MappedComponent] = []
        if let sys, let value = sys.value {
            components.append(MappedComponent(code: "8480-6", display: "Systolic blood pressure", value: value, unit: sys.unit ?? "mm[Hg]"))
        }
        if let dia, let value = dia.value {
            components.append(MappedComponent(code: "8462-4", display: "Diastolic blood pressure", value: value, unit: dia.unit ?? "mm[Hg]"))
        }
        let seed = sys ?? dia!
        rest.insert(MappedSample(
            uuid: uuid,
            hkTypeIdentifier: SyncedMetric.bloodPressureCorrelationIdentifier,
            metricType: "blood_pressure",
            loinc: "85354-9",
            loincDisplay: "Blood pressure panel",
            category: "vital-signs",
            start: min(sys?.start ?? seed.start, dia?.start ?? seed.start),
            end: max(sys?.end ?? seed.end, dia?.end ?? seed.end),
            unit: "mm[Hg]",
            components: components,
            sourceName: seed.sourceName,
            sourceBundleID: seed.sourceBundleID,
            deviceName: seed.deviceName,
            timeZone: seed.timeZone
        ), at: 0)
        return rest
    }

    static func mapSample(_ sample: HKSample) -> [MappedSample] {
        if let correlation = sample as? HKCorrelation {
            return mapBloodPressureCorrelation(correlation)
        }
        if let quantity = sample as? HKQuantitySample,
           let metric = SyncedMetric.from(hkTypeIdentifier: quantity.sampleType.identifier) {
            // Halves are posted only as a correlation panel so a cuff reading is one Observation.
            if metric.isBloodPressureHalf { return [] }
            if let mapped = mapQuantity(quantity, metric: metric) { return [mapped] }
        }
        if let category = sample as? HKCategorySample,
           let metric = SyncedMetric.from(hkTypeIdentifier: category.sampleType.identifier) {
            if let mapped = mapCategory(category, metric: metric) { return [mapped] }
        }
        return []
    }

    /// A sample Apple Health deleted. The identifier matches the one already stored. No new time:
    /// the server keeps the stored interval and rewrites that day.
    static func deletion(identifier: String) -> HealthSampleInput {
        HealthSampleInput(
            status: "entered-in-error",
            identifier: [FHIRIdentifier(system: FHIRSystem.uuid, value: identifier.lowercased())]
        )
    }

    /// The zone HealthKit recorded on the sample, otherwise the phone's zone.
    static func timeZone(of sample: HKSample) -> TimeZone {
        if let name = sample.metadata?[HKMetadataKeyTimeZone] as? String,
           let zone = TimeZone(identifier: name) {
            return zone
        }
        return .current
    }
}

/// One local day's deduplicated step total. The identifier is stable so the next sync updates
/// that day instead of adding another copy.
enum StepDayTotal {
    static func identifier(for localDay: String) -> String { "steps-\(localDay)" }

    static func localDay(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func startOfDay(_ localDay: String, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let pieces = localDay.split(separator: "-")
        let year = Int(pieces.first ?? "") ?? 1970
        let month = pieces.count > 1 ? Int(pieces[1]) ?? 1 : 1
        let day = pieces.count > 2 ? Int(pieces[2]) ?? 1 : 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
            ?? Date(timeIntervalSince1970: 0)
    }

    static func observation(localDay: String, steps: Double, timeZone: TimeZone) -> HealthSampleInput {
        let start = startOfDay(localDay, timeZone: timeZone)
        let metric = SyncedMetric.stepCount
        return MappedSample(
            uuid: identifier(for: localDay),
            hkTypeIdentifier: metric.hkTypeIdentifier,
            metricType: metric.rawValue,
            loinc: metric.loinc,
            loincDisplay: metric.loincDisplay,
            category: metric.observationCategory,
            start: start,
            end: start,
            value: steps,
            unit: metric.fhirUnit,
            timeZone: timeZone
        ).asInput()
    }
}

struct StepDayReading: Equatable {
    var localDay: String
    /// Nil when the statistics bucket has no samples.
    var steps: Double?
}

enum StepDaySync {
    /// Positive totals are uploaded and remembered. A remembered day that dropped to nothing
    /// is retracted. Days outside this window stay remembered.
    static func plan(
        readings: [StepDayReading],
        previouslyPosted: Set<String>,
        timeZone: TimeZone
    ) -> (samples: [HealthSampleInput], posted: Set<String>) {
        var posted = previouslyPosted
        var samples: [HealthSampleInput] = []
        for reading in readings {
            if let steps = reading.steps, steps > 0 {
                samples.append(StepDayTotal.observation(localDay: reading.localDay, steps: steps, timeZone: timeZone))
                posted.insert(reading.localDay)
            } else if posted.contains(reading.localDay) {
                samples.append(SampleMapper.deletion(identifier: StepDayTotal.identifier(for: reading.localDay)))
                posted.remove(reading.localDay)
            }
        }
        return (samples, posted)
    }
}
