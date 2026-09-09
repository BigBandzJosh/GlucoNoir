//
//  HealthKitBackfill.swift
//  GlucoNoir
//
//  Historical backfill from Apple Health.
//
//  Health is NOT a live source and is never used as one. Dexcom documents the
//  Apple Health integration as carrying a deliberate three-hour delay, so a
//  reading arriving here says nothing about the present. Its value is purely
//  historical: it can populate 90 days of past readings in one pass, where
//  Dexcom Share only ever offers the last 24 hours.
//

import Foundation
import HealthKit

nonisolated enum HealthKitError: Error, Equatable {
    case unavailable
    case denied
    case queryFailed(String)

    var userMessage: String {
        switch self {
        case .unavailable:        return "Health data isn't available on this device."
        case .denied:             return "Health access was denied. Enable it in Settings → Health → Data Access."
        case .queryFailed(let d): return "Health query failed: \(d)"
        }
    }
}

nonisolated struct BackfillResult: Equatable, Sendable {
    var samplesRead = 0
    var inserted = 0
    var updated = 0
    var deletedSeen = 0
    /// Distinct source apps encountered, for diagnostics — confirms we are
    /// reading Dexcom's writes and not something else.
    var sources: [String] = []

    var didChangeAnything: Bool { inserted > 0 || updated > 0 }
}

actor HealthKitBackfill {

    private let healthStore = HKHealthStore()
    private let defaults: UserDefaults
    private static let anchorKey = "healthKitGlucoseAnchor"
    private static let lastBackfillKey = "healthKitLastBackfill"

    private var glucoseType: HKQuantityType {
        HKQuantityType(.bloodGlucose)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Authorization

    /// Requests read access. HealthKit deliberately does not reveal whether the
    /// user granted read permission — a denied read is indistinguishable from
    /// an empty data set, by design, so that apps cannot infer that a user has
    /// a condition from their refusal to share. So success here means "the
    /// prompt completed", not "we have access".
    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthKitError.unavailable }
        try await healthStore.requestAuthorization(toShare: [], read: [glucoseType])
    }

    // MARK: Backfill

    /// Reads glucose samples written by Dexcom and upserts them into the store.
    ///
    /// Uses an anchored query so subsequent runs fetch only what is new; the
    /// anchor is persisted between launches.
    @discardableResult
    func backfill(into store: GlucoseStore, days: Int = 90) async throws -> BackfillResult {
        guard Self.isAvailable else { throw HealthKitError.unavailable }

        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)

        let (samples, deleted, newAnchor) = try await runAnchoredQuery(predicate: predicate)

        var result = BackfillResult()
        result.deletedSeen = deleted.count

        var readings: [ShareGlucoseReading] = []
        var sources = Set<String>()

        for sample in samples {
            let bundle = sample.sourceRevision.source.bundleIdentifier
            sources.insert(sample.sourceRevision.source.name)

            // Only Dexcom's own writes. A manual fingerstick entry or another
            // app's estimate is not CGM data and must not enter the store as
            // though it were.
            guard bundle.lowercased().contains("dexcom") else { continue }

            let mgdl = Int(sample.quantity.doubleValue(for: .glucoseMgdl).rounded())
            // Health carries no trend; backfilled readings are flagged so they
            // can never be selected as the displayed current value.
            readings.append(ShareGlucoseReading(sampleTime: sample.startDate,
                                                valueMgdl: mgdl,
                                                trend: .none))
        }

        result.samplesRead = readings.count
        result.sources = sources.sorted()

        if !readings.isEmpty {
            let upsert = try await store.upsert(readings, isBackfilled: true)
            result.inserted = upsert.inserted
            result.updated = upsert.updated
        }

        // Only persist the anchor once the data is safely stored. Saving it
        // first would silently skip these samples forever if the write failed.
        if let newAnchor { saveAnchor(newAnchor) }
        defaults.set(Date(), forKey: Self.lastBackfillKey)

        return result
    }

    var lastBackfillDate: Date? {
        defaults.object(forKey: Self.lastBackfillKey) as? Date
    }

    /// Backfill runs on first launch and then once a day; more often would
    /// re-read three-hour-old data for nothing.
    var isBackfillDue: Bool {
        guard let last = lastBackfillDate else { return true }
        return Date().timeIntervalSince(last) > 20 * 3600
    }

    func resetAnchor() {
        defaults.removeObject(forKey: Self.anchorKey)
        defaults.removeObject(forKey: Self.lastBackfillKey)
    }

    // MARK: Query plumbing

    private func runAnchoredQuery(
        predicate: NSPredicate
    ) async throws -> ([HKQuantitySample], [HKDeletedObject], HKQueryAnchor?) {
        let anchor = loadAnchor()

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: glucoseType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (
                    (samples as? [HKQuantitySample]) ?? [],
                    deleted ?? [],
                    newAnchor
                ))
            }
            healthStore.execute(query)
        }
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: Self.anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor,
                                                           requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: Self.anchorKey)
    }
}

nonisolated extension HKUnit {
    /// Dexcom writes mg/dL; we store canonically in the same unit.
    static let glucoseMgdl = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
}
