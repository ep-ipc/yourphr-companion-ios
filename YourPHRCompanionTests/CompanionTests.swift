import HealthKit
import XCTest
@testable import YourPHRCompanion

final class PairingPayloadTests: XCTestCase {
    func testParseQR_ReadsServerAndSetupCode() throws {
        let raw = """
        { "v": 1, "server": "https://phr.example.org/api/", "code": "yphr_setup_abc" }
        """
        let payload = try PairingPayload.parseQR(raw)
        XCTAssertEqual(payload.server, "https://phr.example.org/api")
        XCTAssertEqual(payload.code, "yphr_setup_abc")
    }

    func testParseDeepLink_ReadsClaimURL() throws {
        let url = try XCTUnwrap(URL(string: "yourphr-device://claim?server=https%3A%2F%2Fphr.example.org%2Fapi&code=yphr_setup_abc"))
        let payload = try PairingPayload.parse(url)
        XCTAssertEqual(payload.server, "https://phr.example.org/api")
        XCTAssertEqual(payload.code, "yphr_setup_abc")
        let fromQR = try PairingPayload.parseQR(url.absoluteString)
        XCTAssertEqual(fromQR, payload)
    }

    func testParseQR_RejectsMissingCode() {
        XCTAssertThrowsError(try PairingPayload.parseQR(#"{"v":1,"server":"https://phr.example.org/api"}"#)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .missingCode)
        }
    }

    func testParseQR_RejectsNonJSON() {
        XCTAssertThrowsError(try PairingPayload.parseQR("not json")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .notJSON)
        }
    }

    func testParseManual_AppendsAPIWhenTheOriginHasNoPath() throws {
        let payload = try PairingPayload.parseManual(baseURL: " http://192.168.1.10:9090/ ", code: " yphr_setup_abc ")
        XCTAssertEqual(payload.code, "yphr_setup_abc")
        XCTAssertEqual(payload.server, "http://192.168.1.10:9090/api")
    }
}

final class HealthSampleJSONTests: XCTestCase {
    func testHeartRateSample_IsObservationWithLOINC() throws {
        let start = ISO8601DateFormatter.api.date(from: "2026-03-01T12:00:00Z")!
        let sample = quantityMapped(
            uuid: "hr-1",
            metric: .heartRate,
            start: start,
            value: 72,
            sourceName: "Apple Watch",
            sourceBundleID: "com.apple.health",
            deviceName: "Apple Watch"
        ).asInput()
        let data = try APIJSON.encoder.encode(sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["resourceType"] as? String, "Observation")
        XCTAssertEqual(object["status"] as? String, "final")
        let identifier = try XCTUnwrap((object["identifier"] as? [[String: Any]])?.first)
        XCTAssertEqual(identifier["system"] as? String, "urn:uuid")
        XCTAssertEqual(identifier["value"] as? String, "hr-1")
        let code = try XCTUnwrap(((object["code"] as? [String: Any])?["coding"] as? [[String: Any]])?.first)
        XCTAssertEqual(code["system"] as? String, "http://loinc.org")
        XCTAssertEqual(code["code"] as? String, "8867-4")
        XCTAssertEqual(object["effectiveDateTime"] as? String, "2026-03-01T12:00:00Z")
        XCTAssertNil(object["source_id"])
        let quantity = try XCTUnwrap(object["valueQuantity"] as? [String: Any])
        XCTAssertEqual(quantity["value"] as? Double, 72)
        XCTAssertEqual(quantity["code"] as? String, "/min")
        XCTAssertEqual(quantity["system"] as? String, "http://unitsofmeasure.org")
        XCTAssertEqual((object["device"] as? [String: Any])?["display"] as? String, "Apple Watch")
        XCTAssertEqual((object["meta"] as? [String: Any])?["source"] as? String, "Apple Watch")
        XCTAssertEqual(object["source_bundle_id"] as? String, "com.apple.health")
        XCTAssertNil(object["type"])
        XCTAssertNil(object["correlation_uuid"])
        XCTAssertNil(object["value_text"])
    }

    func testTimestamp_UsesTheSampleOffset() throws {
        let start = ISO8601DateFormatter.api.date(from: "2026-03-01T12:00:00Z")!
        var mapped = quantityMapped(uuid: "hr-1", metric: .heartRate, start: start, value: 72)
        mapped.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let data = try APIJSON.encoder.encode(mapped.asInput())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["effectiveDateTime"] as? String, "2026-03-01T08:00:00-04:00")
    }

    func testSleepSample_SendsStageLOINC() throws {
        let start = ISO8601DateFormatter.api.date(from: "2026-03-01T12:00:00Z")!
        let end = ISO8601DateFormatter.api.date(from: "2026-03-01T18:00:00Z")!
        let stage = try XCTUnwrap(SleepStageValue.loinc(rawValue: 4))
        let sample = MappedSample(
            uuid: "sleep-1",
            hkTypeIdentifier: SyncedMetric.sleepStage.hkTypeIdentifier,
            metricType: SyncedMetric.sleepStage.rawValue,
            loinc: stage.code,
            loincDisplay: stage.display,
            category: SyncedMetric.sleepStage.observationCategory,
            start: start,
            end: end,
            valueText: stage.code,
            valueDisplay: stage.display,
            timeZone: TimeZone(secondsFromGMT: -4 * 3600)!
        ).asInput()
        let data = try APIJSON.encoder.encode(sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let period = try XCTUnwrap(object["effectivePeriod"] as? [String: Any])
        XCTAssertEqual(period["start"] as? String, "2026-03-01T08:00:00-04:00")
        XCTAssertEqual(period["end"] as? String, "2026-03-01T14:00:00-04:00")
        let category = try XCTUnwrap(((object["category"] as? [[String: Any]])?.first)?["coding"] as? [[String: Any]])
        XCTAssertEqual(category.first?["code"] as? String, "activity")
        let code = try XCTUnwrap(((object["code"] as? [String: Any])?["coding"] as? [[String: Any]])?.first)
        XCTAssertEqual(code["system"] as? String, "http://loinc.org")
        XCTAssertEqual(code["code"] as? String, "93831-6")
        let concept = try XCTUnwrap(((object["valueCodeableConcept"] as? [String: Any])?["coding"] as? [[String: Any]])?.first)
        XCTAssertEqual(concept["system"] as? String, "http://loinc.org")
        XCTAssertEqual(concept["code"] as? String, "93831-6")
        XCTAssertNil(object["valueQuantity"])
        XCTAssertNil(object["value_text"])
    }

    func testOxygenSample_PostsPulseOxThenSaturation() throws {
        let start = ISO8601DateFormatter.api.date(from: "2026-03-01T12:00:00Z")!
        let sample = quantityMapped(uuid: "ox-1", metric: .oxygenSaturation, start: start, value: 97).asInput()
        let data = try APIJSON.encoder.encode(sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let codings = try XCTUnwrap((object["code"] as? [String: Any])?["coding"] as? [[String: Any]])
        XCTAssertEqual(codings.map { $0["code"] as? String }, ["59408-5", "2708-6"])
        XCTAssertEqual(codings.first?["system"] as? String, "http://loinc.org")
        let quantity = try XCTUnwrap(object["valueQuantity"] as? [String: Any])
        XCTAssertEqual(quantity["value"] as? Double, 97)
        XCTAssertEqual(quantity["code"] as? String, "%")
    }

    func testDeviceGrant_DecodesClaimAndRefresh() throws {
        let json = """
        {"success":true,"data":{"access_token":"yphr_at_a","token_type":"Bearer","expires_in":86400,"refresh_token":"yphr_rt_b","grant_ends_at":"2026-10-30T14:02:11.000Z","label":"Jim's iPhone"}}
        """.data(using: .utf8)!
        let envelope = try APIJSON.decoder.decode(APIEnvelope<DeviceGrant>.self, from: json)
        XCTAssertEqual(envelope.data?.accessToken, "yphr_at_a")
        XCTAssertEqual(envelope.data?.refreshToken, "yphr_rt_b")
        XCTAssertEqual(envelope.data?.expiresIn, 86400)
        XCTAssertEqual(envelope.data?.grantEndsAt, "2026-10-30T14:02:11.000Z")
        XCTAssertEqual(envelope.data?.label, "Jim's iPhone")
        XCTAssertEqual(envelope.data?.tokenType, "Bearer")
    }

    func testIngestRequest_EncodesDeviceAndAnchors() throws {
        let start = ISO8601DateFormatter.api.date(from: "2026-03-01T12:00:00Z")!
        let request = HealthSampleIngestRequest(
            device: HealthDeviceInfo(deviceID: "iphone-a", name: "iPhone", osVersion: "18.0", appVersion: "0.1.0"),
            samples: [
                quantityMapped(uuid: "hr-1", metric: .heartRate, start: start, value: 72).asInput(),
            ],
            anchors: ["heart_rate": "YQ=="]
        )
        let data = try APIJSON.encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let device = try XCTUnwrap(object["device"] as? [String: Any])
        XCTAssertEqual(device["device_id"] as? String, "iphone-a")
        XCTAssertEqual(device["os_version"] as? String, "18.0")
        XCTAssertEqual(device["app_version"] as? String, "0.1.0")
        let anchors = try XCTUnwrap(object["anchors"] as? [String: String])
        XCTAssertEqual(anchors["heart_rate"], "YQ==")
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.first?["resourceType"] as? String, "Observation")
    }

    func testIngestResponse_DecodesCounts() throws {
        let json = """
        {"success":true,"data":{"received":3,"accepted":3,"stored":1,"duplicates":2,"rejected":0}}
        """.data(using: .utf8)!
        let envelope = try APIJSON.decoder.decode(APIEnvelope<HealthSampleIngestResponse>.self, from: json)
        XCTAssertTrue(envelope.success)
        XCTAssertEqual(envelope.data?.stored, 1)
        XCTAssertEqual(envelope.data?.duplicates, 2)
    }
}

final class UnitMappingTests: XCTestCase {
    func testPostedUnits_AreUCUM() {
        XCTAssertEqual(SampleMapper.unitString(for: .heartRate), "/min")
        XCTAssertEqual(SampleMapper.unitString(for: .restingHeartRate), "/min")
        XCTAssertEqual(SampleMapper.unitString(for: .heartRateVariability), "ms")
        XCTAssertEqual(SampleMapper.unitString(for: .bloodPressureSystolic), "mm[Hg]")
        XCTAssertEqual(SampleMapper.unitString(for: .stepCount), "{steps}")
        XCTAssertEqual(SampleMapper.unitString(for: .bodyMass), "kg")
        XCTAssertEqual(SampleMapper.unitString(for: .oxygenSaturation), "%")
        XCTAssertEqual(SampleMapper.unitString(for: .bodyTemperature), "Cel")
        XCTAssertEqual(SampleMapper.postedQuantityValue(0.97, metric: .oxygenSaturation), 97)
        XCTAssertEqual(SampleMapper.postedQuantityValue(97, metric: .oxygenSaturation), 97)
        XCTAssertEqual(SampleMapper.postedQuantityValue(72, metric: .heartRate), 72)
    }

    func testReadTypes_ExcludeBloodPressureCorrelation() {
        let identifiers = Set(HealthKitAuthorizer.readTypes.map(\.identifier))
        XCTAssertFalse(
            identifiers.contains(SyncedMetric.bloodPressureCorrelationIdentifier),
            "requestAuthorization throws if HKCorrelationTypeIdentifierBloodPressure is in the read set"
        )
        XCTAssertTrue(identifiers.contains(SyncedMetric.bloodPressureSystolic.hkTypeIdentifier))
        XCTAssertTrue(identifiers.contains(SyncedMetric.bloodPressureDiastolic.hkTypeIdentifier))
        XCTAssertEqual(identifiers.count, SyncedMetric.allCases.count)
    }

    func testSampleTypesForQuery_IncludeBloodPressureCorrelation() {
        let identifiers = HealthKitAuthorizer.sampleTypesForQuery.map(\.identifier)
        XCTAssertTrue(identifiers.contains(SyncedMetric.bloodPressureCorrelationIdentifier))
        XCTAssertTrue(identifiers.contains(SyncedMetric.bloodPressureSystolic.hkTypeIdentifier))
        XCTAssertFalse(
            identifiers.contains(SyncedMetric.stepCount.hkTypeIdentifier),
            "step samples from the phone and the watch would be added; steps use a daily total"
        )
        XCTAssertTrue(HealthKitAuthorizer.readTypes.contains { $0.identifier == SyncedMetric.stepCount.hkTypeIdentifier })
        XCTAssertTrue(HealthKitAuthorizer.backgroundDeliveryTypes.contains { $0.identifier == SyncedMetric.stepCount.hkTypeIdentifier })
        XCTAssertFalse(
            HealthKitAuthorizer.backgroundDeliveryTypes.contains(where: { $0 is HKCorrelationType }),
            "enableBackgroundDelivery does not support HKCorrelationType"
        )
    }

    func testQuantityTypeIdentifiers_MatchServerKeys() {
        XCTAssertEqual(SyncedMetric.heartRate.hkTypeIdentifier, "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(SyncedMetric.restingHeartRate.hkTypeIdentifier, "HKQuantityTypeIdentifierRestingHeartRate")
        XCTAssertEqual(SyncedMetric.heartRateVariability.hkTypeIdentifier, "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        XCTAssertEqual(SyncedMetric.bloodPressureSystolic.hkTypeIdentifier, "HKQuantityTypeIdentifierBloodPressureSystolic")
        XCTAssertEqual(SyncedMetric.bloodPressureDiastolic.hkTypeIdentifier, "HKQuantityTypeIdentifierBloodPressureDiastolic")
        XCTAssertEqual(SyncedMetric.stepCount.hkTypeIdentifier, "HKQuantityTypeIdentifierStepCount")
        XCTAssertEqual(SyncedMetric.bodyMass.hkTypeIdentifier, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertEqual(SyncedMetric.oxygenSaturation.hkTypeIdentifier, "HKQuantityTypeIdentifierOxygenSaturation")
        XCTAssertEqual(SyncedMetric.bodyTemperature.hkTypeIdentifier, "HKQuantityTypeIdentifierBodyTemperature")
        XCTAssertEqual(SyncedMetric.sleepStage.hkTypeIdentifier, "HKCategoryTypeIdentifierSleepAnalysis")
        XCTAssertEqual(SyncedMetric.bloodPressureCorrelationIdentifier, "HKCorrelationTypeIdentifierBloodPressure")
        XCTAssertEqual(SyncedMetric.heartRate.loinc, "8867-4")
        XCTAssertEqual(SyncedMetric.oxygenSaturation.loinc, "59408-5")
        XCTAssertEqual(SyncedMetric.oxygenSaturation.alsoLoinc, ["2708-6"])
        XCTAssertEqual(SyncedMetric.sleepStage.loinc, "93828-2")
        XCTAssertEqual(SyncedMetric.sleepStage.observationCategory, "activity")
        XCTAssertEqual(SyncEngine.maxAnchorLength, 1024)
    }

    func testSleepStage_MapsHealthKitEnumToLOINC() {
        XCTAssertNil(SleepStageValue.loinc(rawValue: 0))
        XCTAssertNil(SleepStageValue.loinc(rawValue: 1))
        XCTAssertEqual(SleepStageValue.loinc(rawValue: 2)?.code, "93828-2")
        XCTAssertEqual(SleepStageValue.loinc(rawValue: 3)?.code, "93830-8")
        XCTAssertEqual(SleepStageValue.loinc(rawValue: 4)?.code, "93831-6")
        XCTAssertEqual(SleepStageValue.loinc(rawValue: 5)?.code, "93829-0")
        XCTAssertNil(SleepStageValue.loinc(rawValue: 99))
    }
}

final class StepAndDeletionTests: XCTestCase {
    func testStepDay_UsesStableIdentifierAndLocalOffset() throws {
        let zone = TimeZone(secondsFromGMT: -4 * 60 * 60)!
        let input = StepDayTotal.observation(localDay: "2026-08-24", steps: 8421, timeZone: zone)
        let data = try APIJSON.encoder.encode(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let identifier = try XCTUnwrap((object["identifier"] as? [[String: Any]])?.first)
        XCTAssertEqual(identifier["system"] as? String, "urn:uuid")
        XCTAssertEqual(identifier["value"] as? String, "steps-2026-08-24")
        XCTAssertEqual(object["effectiveDateTime"] as? String, "2026-08-24T00:00:00-04:00")
        let code = try XCTUnwrap(((object["code"] as? [String: Any])?["coding"] as? [[String: Any]])?.first)
        XCTAssertEqual(code["code"] as? String, "55423-8")
        let quantity = try XCTUnwrap(object["valueQuantity"] as? [String: Any])
        XCTAssertEqual(quantity["value"] as? Double, 8421)
        XCTAssertEqual(quantity["code"] as? String, "{steps}")
    }

    func testStepDaySync_RetractsARememberedDayThatDroppedToNothing() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let planned = StepDaySync.plan(
            readings: [
                StepDayReading(localDay: "2026-08-24", steps: 100),
                StepDayReading(localDay: "2026-08-23", steps: nil),
                StepDayReading(localDay: "2026-08-22", steps: nil),
            ],
            previouslyPosted: ["2026-08-23", "2026-07-01"],
            timeZone: zone
        )
        XCTAssertEqual(planned.posted, Set(["2026-07-01", "2026-08-24"]))
        XCTAssertEqual(planned.samples.count, 2)
        let encoded = try planned.samples.map { sample -> [String: Any] in
            let data = try APIJSON.encoder.encode(sample)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let values = encoded.compactMap { ($0["identifier"] as? [[String: Any]])?.first?["value"] as? String }
        XCTAssertEqual(values, ["steps-2026-08-24", "steps-2026-08-23"])
        XCTAssertEqual(encoded[1]["status"] as? String, "entered-in-error")
        XCTAssertNil(encoded[1]["effectiveDateTime"])
    }

    func testDeletion_IsEnteredInErrorByUUID() throws {
        let input = SampleMapper.deletion(identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE".lowercased())
        let data = try APIJSON.encoder.encode(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["resourceType"] as? String, "Observation")
        XCTAssertEqual(object["status"] as? String, "entered-in-error")
        XCTAssertNil(object["effectiveDateTime"])
        XCTAssertNil(object["effectivePeriod"])
        XCTAssertNil(object["code"])
        let identifier = try XCTUnwrap((object["identifier"] as? [[String: Any]])?.first)
        XCTAssertEqual(identifier["value"] as? String, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    func testLongAnchor_StaysOffTheRequestThatCarriesTheSamples() throws {
        let long = String(repeating: "a", count: SyncEngine.maxAnchorLength + 1)
        XCTAssertNil(AnchorPosting.serverBlob(long))
        XCTAssertEqual(AnchorPosting.serverBlob(String(repeating: "b", count: SyncEngine.maxAnchorLength))?.count, SyncEngine.maxAnchorLength)
        let anchors = AnchorPosting.anchors(metric: "heart_rate", blob: long)
        XCTAssertTrue(anchors.isEmpty)
        let start = ISO8601DateFormatter.api.date(from: "2026-03-01T12:00:00Z")!
        let request = HealthSampleIngestRequest(
            device: HealthDeviceInfo(deviceID: "iphone-a", name: "Phone", osVersion: "18.0", appVersion: "0.1.0"),
            samples: [quantityMapped(uuid: "hr-1", metric: .heartRate, start: start, value: 72).asInput()],
            anchors: anchors
        )
        let data = try APIJSON.encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        let sentAnchors = try XCTUnwrap(object["anchors"] as? [String: String])
        XCTAssertTrue(sentAnchors.isEmpty)
    }

    func testHealthDisabled_NamesBothSwitches() {
        XCTAssertEqual(
            APIClientError.healthDisabled.localizedDescription,
            "YourPHR is not accepting health samples. Turn on Connected devices and Health, then sync again."
        )
    }

    func testLocalNetwork_PrivateAddressesNeedPermission() {
        XCTAssertTrue(LocalNetworkHost.isLocal(URL(string: "http://192.168.1.20:4200/api")))
        XCTAssertTrue(LocalNetworkHost.isLocal(URL(string: "http://10.0.0.5:8080/api")))
        XCTAssertTrue(LocalNetworkHost.isLocal(URL(string: "http://172.16.0.1/api")))
        XCTAssertTrue(LocalNetworkHost.isLocal(URL(string: "http://172.31.255.1/api")))
        XCTAssertTrue(LocalNetworkHost.isLocal(URL(string: "http://yourphr.local:8080/api")))
        XCTAssertTrue(LocalNetworkHost.isLocal(URL(string: "http://[fe80::1]:8080/api")))
        XCTAssertFalse(LocalNetworkHost.isLocal(URL(string: "http://172.32.0.1/api")))
        XCTAssertFalse(LocalNetworkHost.isLocal(URL(string: "https://phr.example.org/api")))
        XCTAssertFalse(LocalNetworkHost.isLocal(URL(string: "http://1.1.1.1/api")))
        XCTAssertEqual(LocalNetworkHost.label(for: URL(string: "http://192.168.1.20:4200/api")!), "192.168.1.20:4200")
    }

    func testLocalNetworkDenied_NamesTheSettingsSwitch() {
        let message = APIClientError.localNetworkDenied("192.168.1.20:4200").errorDescription
        XCTAssertEqual(
            message,
            "iOS blocked YourPHR Companion from reaching 192.168.1.20:4200 on the local network. Tap Allow if asked to find devices on your local network. YourPHR Companion appears under Settings → Privacy & Security → Local Network only after that prompt."
        )
    }
}

final class BatchingTests: XCTestCase {
    func testSplit_PagesAtFiveThousand() {
        let items = Array(0 ..< 12_001)
        let pages = Batching.split(items)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].count, 5000)
        XCTAssertEqual(pages[1].count, 5000)
        XCTAssertEqual(pages[2].count, 2001)
        XCTAssertEqual(pages[0].first, 0)
        XCTAssertEqual(pages[2].last, 12_000)
    }

    func testSplit_EmptyIsEmpty() {
        XCTAssertTrue(Batching.split([Int]()).isEmpty)
    }

    func testSplit_ExactPage() {
        XCTAssertEqual(Batching.split(Array(0 ..< 5000)).count, 1)
    }
}

final class BloodPressureCorrelationTests: XCTestCase {
    func testMergeBloodPressure_EmitsOnePanelObservation() throws {
        let start = Date()
        let samples = [
            quantityMapped(uuid: "sys", metric: .bloodPressureSystolic, start: start, value: 120),
            quantityMapped(uuid: "dia", metric: .bloodPressureDiastolic, start: start, value: 80),
            quantityMapped(uuid: "hr", metric: .heartRate, start: start, value: 72),
        ]
        let merged = SampleMapper.mergeBloodPressure(uuid: "corr-1", samples: samples)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].uuid, "corr-1")
        XCTAssertEqual(merged[0].loinc, "85354-9")
        XCTAssertEqual(merged[0].components.map(\.code), ["8480-6", "8462-4"])
        XCTAssertEqual(merged[0].components.map(\.value), [120, 80])
        XCTAssertEqual(merged[1].metricType, "heart_rate")

        let input = merged[0].asInput()
        let data = try APIJSON.encoder.encode(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["resourceType"] as? String, "Observation")
        let code = try XCTUnwrap(((object["code"] as? [String: Any])?["coding"] as? [[String: Any]])?.first)
        XCTAssertEqual(code["code"] as? String, "85354-9")
        let components = try XCTUnwrap(object["component"] as? [[String: Any]])
        XCTAssertEqual(components.count, 2)
        XCTAssertNil(object["correlation_uuid"])
        XCTAssertNil(object["valueQuantity"])
    }
}

final class LatestReadingFormatTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testHeartRate_UsesBeatsPerMinute() {
        XCTAssertEqual(LatestReadingFormat.quantity(72, unit: .beatsPerMinute, locale: locale), "72 bpm")
    }

    func testSteps_GroupsThousands() {
        XCTAssertEqual(LatestReadingFormat.quantity(8432, unit: .steps, locale: locale), "8,432 steps")
    }

    func testOxygen_ScalesTheHealthKitFraction() {
        XCTAssertEqual(LatestReadingFormat.quantity(0.984, unit: .percent, locale: locale), "98%")
    }

    func testWeight_KeepsOneDecimalInKilogramsOrPounds() {
        XCTAssertEqual(LatestReadingFormat.quantity(70.2, unit: .kilograms, locale: locale), "70.2 kg")
        XCTAssertEqual(LatestReadingFormat.quantity(154, unit: .pounds, locale: locale), "154 lb")
    }

    func testTemperature_UsesThePreferredScale() {
        XCTAssertEqual(LatestReadingFormat.quantity(36.6, unit: .celsius, locale: locale), "36.6 °C")
        XCTAssertEqual(LatestReadingFormat.quantity(98.6, unit: .fahrenheit, locale: locale), "98.6 °F")
    }

    func testSleep_NamesTheStage() {
        XCTAssertEqual(LatestReadingFormat.sleep(rawValue: HKCategoryValueSleepAnalysis.inBed.rawValue), "In bed")
        XCTAssertEqual(LatestReadingFormat.sleep(rawValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue), "Core sleep")
        XCTAssertEqual(LatestReadingFormat.sleep(rawValue: HKCategoryValueSleepAnalysis.asleepREM.rawValue), "REM sleep")
        XCTAssertNil(LatestReadingFormat.sleep(rawValue: 99))
    }

    func testDisplayUnit_FollowsWeightAndTemperaturePreferences() {
        XCTAssertEqual(ReadingDisplayUnit.resolve(metric: .bodyMass, preferred: .pound()), .pounds)
        XCTAssertEqual(ReadingDisplayUnit.resolve(metric: .bodyMass, preferred: .gramUnit(with: .kilo)), .kilograms)
        XCTAssertEqual(ReadingDisplayUnit.resolve(metric: .bodyTemperature, preferred: .degreeFahrenheit()), .fahrenheit)
        XCTAssertEqual(ReadingDisplayUnit.resolve(metric: .heartRate, preferred: nil), .beatsPerMinute)
    }
}

final class AnchorCodecTests: XCTestCase {
    func testAnchor_RoundTripsThroughBase64() throws {
        let original = HKQueryAnchor(fromValue: 42)
        let blob = AnchorCodec.encode(original)
        XCTAssertFalse(blob.isEmpty)
        let decoded = try XCTUnwrap(AnchorCodec.decode(blob))
        let again = AnchorCodec.encode(decoded)
        XCTAssertEqual(again, blob, "the server stores this blob opaquely; encoding must be stable")
    }

    func testAnchor_RejectsGarbage() {
        XCTAssertNil(AnchorCodec.decode("not-base64!!!"))
        XCTAssertNil(AnchorCodec.decode("YQ=="))
    }
}

private func quantityMapped(
    uuid: String,
    metric: SyncedMetric,
    start: Date,
    value: Double,
    sourceName: String? = nil,
    sourceBundleID: String? = nil,
    deviceName: String? = nil
) -> MappedSample {
    MappedSample(
        uuid: uuid,
        hkTypeIdentifier: metric.hkTypeIdentifier,
        metricType: metric.rawValue,
        loinc: metric.loinc,
        loincDisplay: metric.loincDisplay,
        category: metric.observationCategory,
        start: start,
        end: start,
        value: value,
        unit: metric.fhirUnit,
        sourceName: sourceName,
        sourceBundleID: sourceBundleID,
        deviceName: deviceName,
        alsoLoinc: metric.alsoLoinc
    )
}
