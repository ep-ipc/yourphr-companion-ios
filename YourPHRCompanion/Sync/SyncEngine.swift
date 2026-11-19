import Foundation
import HealthKit
import UIKit

enum SyncError: LocalizedError {
    case notPaired
    case healthUnavailable
    case databaseInaccessible
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired with a YourPHR instance."
        case .healthUnavailable: return "HealthKit is not available (Simulator cannot sync samples)."
        case .databaseInaccessible: return "Waiting for unlock — HealthKit is encrypted while the phone is locked."
        case .cancelled: return "Sync cancelled."
        }
    }
}

enum SyncBudget {
    /// Foreground: drain the backlog, paging at 5000. First-run backfill belongs here.
    case foreground
    /// Background wake (~30s): one page per type, then stop.
    case background
}

struct SyncResult: Equatable {
    var received: Int = 0
    var stored: Int64 = 0
    var duplicates: Int64 = 0
    var rejected: Int = 0
}

/// Pulls new HealthKit samples via HKAnchoredObjectQuery and POSTs them. Anchors are persisted
/// locally and on the server only after HTTP 200, so a failed push retries the same window and
/// the server's (user_id, external_uuid) unique index makes overlap a no-op.
/// A bookmark longer than the server will store stays on the phone; the samples in that page still go.
actor SyncEngine {
    static let maxAnchorLength = 1024
    /// The ingest limit is 60 posts a minute. Three waits cover a window that is already full.
    static let rateLimitWaits = 3
    static let rateLimitDelay: TimeInterval = 60

    private let keychain: KeychainStore
    private let anchors: AnchorStore
    private let syncState: SyncStateStore
    private let pairing: PairingService
    private let store: HKHealthStore

    init(
        keychain: KeychainStore = .shared,
        anchors: AnchorStore = AnchorStore(),
        syncState: SyncStateStore = .shared,
        pairing: PairingService = PairingService(),
        store: HKHealthStore = HKHealthStore()
    ) {
        self.keychain = keychain
        self.anchors = anchors
        self.syncState = syncState
        self.pairing = pairing
        self.store = store
    }

    func sync(budget: SyncBudget, onProgress: (@MainActor (String) -> Void)? = nil) async throws -> SyncResult {
        guard pairing.isPaired else { throw SyncError.notPaired }
        guard HKHealthStore.isHealthDataAvailable() else { throw SyncError.healthUnavailable }

        var client = try await pairing.clientForUpload()
        let device = try currentDevice()
        var total = SyncResult()

        for type in HealthKitAuthorizer.sampleTypesForQuery {
            if Task.isCancelled { throw SyncError.cancelled }
            await onProgress?("Syncing \(type.identifier)…")
            let synced = try await syncType(type, client: client, device: device, budget: budget)
            client = synced.client
            total.add(synced.result)
        }

        await onProgress?("Syncing steps…")
        let steps = try await syncSteps(client: client, device: device, budget: budget)
        total.add(steps.result)

        await MainActor.run {
            syncState.recordSuccess(received: total.received, stored: Int(total.stored))
        }
        return total
    }

    private struct TypeSync {
        var result: SyncResult
        var client: APIClient
    }

    private func syncType(
        _ type: HKSampleType,
        client starting: APIClient,
        device: HealthDeviceInfo,
        budget: SyncBudget
    ) async throws -> TypeSync {
        var client = starting
        var total = SyncResult()
        var pages = 0
        let maxPages = budget == .background ? 1 : 64

        while pages < maxPages {
            pages += 1
            let existing = anchors.get(identifier: type.identifier)
            let anchor = existing.flatMap(AnchorCodec.decode)
            let lookback: Date? = existing == nil
                ? Date().addingTimeInterval(-Double(syncState.lookbackDays) * 24 * 60 * 60)
                : nil

            let page: QueryPage
            do {
                page = try await query(type: type, anchor: anchor, start: lookback, limit: Batching.maxBatch)
            } catch let error as HKError where error.code == .errorDatabaseInaccessible {
                throw SyncError.databaseInaccessible
            }

            let additions = page.samples.flatMap { SampleMapper.mapSample($0) }.map { $0.asInput() }
            let deletions = page.deleted.map { SampleMapper.deletion(identifier: $0.uuid.uuidString.lowercased()) }
            let inputs = additions + deletions
            let newAnchorB64 = page.anchor.map(AnchorCodec.encode) ?? existing ?? ""
            let serverAnchors = metricAnchors(for: type, blob: newAnchorB64)

            if inputs.isEmpty && serverAnchors.isEmpty {
                if !newAnchorB64.isEmpty {
                    try anchors.set(identifier: type.identifier, base64: newAnchorB64)
                }
            } else {
                let chunks = inputs.isEmpty ? [[HealthSampleInput]()] : Batching.split(inputs)
                for (index, chunk) in chunks.enumerated() {
                    let isLast = index == chunks.count - 1
                    let request = HealthSampleIngestRequest(
                        device: device,
                        samples: chunk,
                        anchors: isLast ? serverAnchors : [:]
                    )
                    let (response, nextClient) = try await ingest(request, client: client, budget: budget)
                    client = nextClient
                    total.add(response)
                }
                if !newAnchorB64.isEmpty {
                    try anchors.set(identifier: type.identifier, base64: newAnchorB64)
                }
            }

            if page.samples.count < Batching.maxBatch { break }
        }
        return TypeSync(result: total, client: client)
    }

    /// One cumulative total per local day. Raw step samples from the phone and the watch overlap,
    /// and the server would add them because they share this device's source.
    private func syncSteps(
        client starting: APIClient,
        device: HealthDeviceInfo,
        budget: SyncBudget
    ) async throws -> TypeSync {
        let readings: [StepDayReading]
        do {
            readings = try await queryStepDays(lookbackDays: syncState.lookbackDays)
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            throw SyncError.databaseInaccessible
        }
        let planned = StepDaySync.plan(
            readings: readings,
            previouslyPosted: syncState.postedStepDays,
            timeZone: .current
        )
        var client = starting
        var total = SyncResult()
        guard !planned.samples.isEmpty else {
            return TypeSync(result: total, client: client)
        }
        for chunk in Batching.split(planned.samples) {
            let request = HealthSampleIngestRequest(device: device, samples: chunk, anchors: [:])
            let (response, nextClient) = try await ingest(request, client: client, budget: budget)
            client = nextClient
            total.add(response)
        }
        syncState.postedStepDays = planned.posted
        return TypeSync(result: total, client: client)
    }

    private func metricAnchors(for type: HKSampleType, blob: String) -> [String: String] {
        // Keyed by normalized metric type, which is what GET /health/sync-state returns. A
        // blood-pressure *correlation* query has no metric type of its own; its anchor stays
        // local under the HealthKit type identifier so it cannot be restored onto a quantity query.
        let metric = SyncedMetric.from(hkTypeIdentifier: type.identifier)?.rawValue
        return AnchorPosting.anchors(metric: metric, blob: blob)
    }

    /// One refresh after a 401, then a single retry. A second 401 is the grant ending.
    /// A foreground 429 waits out the per-minute window and retries this same page. A background
    /// wake is shorter than that window, so it stops and the next wake sends the page again.
    private func ingest(
        _ request: HealthSampleIngestRequest,
        client starting: APIClient,
        budget: SyncBudget
    ) async throws -> (HealthSampleIngestResponse, APIClient) {
        var client = starting
        var didRefresh = false
        var waits = 0
        while true {
            do {
                return (try await client.ingest(request), client)
            } catch APIClientError.httpStatus(401, _) where !didRefresh {
                client = try await pairing.clientAfterUnauthorized()
                didRefresh = true
            } catch APIClientError.rateLimited where budget == .foreground && waits < Self.rateLimitWaits {
                waits += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.rateLimitDelay * 1_000_000_000))
                } catch is CancellationError {
                    throw SyncError.cancelled
                }
            }
        }
    }

    private func currentDevice() throws -> HealthDeviceInfo {
        let id = try keychain.deviceID()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let name = keychain.get(account: KeychainStore.Account.deviceLabel) ?? UIDevice.current.name
        return HealthDeviceInfo(
            deviceID: id,
            name: name,
            osVersion: UIDevice.current.systemVersion,
            appVersion: version
        )
    }

    private struct QueryPage {
        var samples: [HKSample]
        var deleted: [HKDeletedObject]
        var anchor: HKQueryAnchor?
    }

    private func query(type: HKSampleType, anchor: HKQueryAnchor?, start: Date?, limit: Int) async throws -> QueryPage {
        try await withCheckedThrowingContinuation { continuation in
            var predicate: NSPredicate?
            if let start {
                predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            }
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, added, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: QueryPage(samples: added ?? [], deleted: deleted ?? [], anchor: newAnchor))
            }
            store.execute(query)
        }
    }

    private func queryStepDays(lookbackDays: Int) async throws -> [StepDayReading] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [] }
        var calendar = Calendar.current
        calendar.timeZone = .current
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
                var days: [StepDayReading] = []
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let sum = statistics.sumQuantity()?.doubleValue(for: HKUnit.count())
                    days.append(StepDayReading(
                        localDay: StepDayTotal.localDay(for: statistics.startDate, calendar: calendar),
                        steps: sum
                    ))
                }
                continuation.resume(returning: days)
            }
            store.execute(query)
        }
    }
}

private extension SyncResult {
    mutating func add(_ other: SyncResult) {
        received += other.received
        stored += other.stored
        duplicates += other.duplicates
        rejected += other.rejected
    }

    mutating func add(_ response: HealthSampleIngestResponse) {
        received += response.received
        stored += response.stored
        duplicates += response.duplicates
        rejected += response.rejected
    }
}
