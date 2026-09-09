//
//  HealthKitTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
import HealthKit
@testable import GlucoNoir

private func makeStore() throws -> GlucoseStore {
    let container = try ModelContainer(
        for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
        migrationPlan: GlucoNoirMigrationPlan.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return GlucoseStore(modelContainer: container)
}

import SwiftData

struct HealthKitUnitTests {

    /// Dexcom writes mg/dL and the store is canonical mg/dL; a unit mismatch
    /// here would import values off by a factor of 18.
    @Test func glucoseUnitIsMilligramsPerDecilitre() {
        #expect(HKUnit.glucoseMgdl.unitString == "mg/dL")
    }

    @Test func roundTripsATypicalValue() {
        let quantity = HKQuantity(unit: .glucoseMgdl, doubleValue: 142)
        #expect(Int(quantity.doubleValue(for: .glucoseMgdl).rounded()) == 142)
    }

    /// If Health ever hands us mmol/L, the conversion must land on mg/dL.
    /// mmol/L is millimoles of glucose per litre — not moles per millilitre.
    @Test func convertsFromMillimolesIfNeeded() {
        let mmolPerLitre = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
            .unitDivided(by: .liter())
        let quantity = HKQuantity(unit: mmolPerLitre, doubleValue: 5.5)
        let mgdl = quantity.doubleValue(for: .glucoseMgdl)
        #expect(abs(mgdl - 99.1) < 0.5, "5.5 mmol/L is about 99 mg/dL")
    }
}

struct BackfillResultTests {

    @Test func reportsWhetherAnythingChanged() {
        var result = BackfillResult()
        #expect(!result.didChangeAnything)
        result.inserted = 3
        #expect(result.didChangeAnything)

        var updatedOnly = BackfillResult()
        updatedOnly.updated = 1
        #expect(updatedOnly.didChangeAnything)
    }

    /// Reading samples but storing none is the signature of every sample being
    /// filtered out — a different situation from finding nothing at all.
    @Test func readingWithoutStoringIsNotAChange() {
        var result = BackfillResult()
        result.samplesRead = 50
        #expect(!result.didChangeAnything)
    }
}

@MainActor
struct BackfillSchedulingTests {

    private func backfill() -> HealthKitBackfill {
        HealthKitBackfill(defaults: UserDefaults(suiteName: "hk-\(UUID().uuidString)")!)
    }

    @Test func firstRunIsDue() async {
        #expect(await backfill().isBackfillDue)
    }

    @Test func resetClearsScheduling() async {
        let b = backfill()
        await b.resetAnchor()
        #expect(await b.isBackfillDue)
        #expect(await b.lastBackfillDate == nil)
    }
}

/// Backfilled rows must never be presented as the current reading. Health data
/// is three hours stale by design, so a backfilled row that sorts newest is
/// still not evidence of what is happening now.
struct BackfillProvenanceTests {

    @Test func backfilledRowsAreExcludedFromLatestLive() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_757_000_000)

        _ = try await store.upsert(
            [ShareGlucoseReading(sampleTime: now.addingTimeInterval(-600), valueMgdl: 100, trend: .flat)],
            isBackfilled: false
        )
        // Newer, but from Health.
        _ = try await store.upsert(
            [ShareGlucoseReading(sampleTime: now, valueMgdl: 250, trend: .none)],
            isBackfilled: true
        )

        let live = try await store.latestLive()
        #expect(live?.valueMgdl == 100, "a backfilled row was shown as the current reading")
        #expect(try await store.count() == 2, "both rows still belong in history")
    }

    @Test func backfilledRowsStillCountTowardHistory() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let readings = (0..<12).map {
            ShareGlucoseReading(sampleTime: now.addingTimeInterval(-Double($0 * 300)),
                                valueMgdl: 100, trend: .none)
        }
        _ = try await store.upsert(readings, isBackfilled: true)

        let history = try await store.readings(since: .distantPast)
        #expect(history.count == 12)

        let stats = GlucoseStatistics.compute(readings: history, windowDuration: 3600, now: now)
        #expect(stats.readingCount > 0, "history statistics should include imported readings")
    }

    /// A live poll covering the same sample must not duplicate an imported row.
    @Test func liveReadingsDeduplicateAgainstImportedOnes() async throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_757_000_000)

        _ = try await store.upsert([ShareGlucoseReading(sampleTime: t, valueMgdl: 100, trend: .none)],
                                   isBackfilled: true)
        let result = try await store.upsert([ShareGlucoseReading(sampleTime: t, valueMgdl: 100, trend: .flat)],
                                            isBackfilled: false)

        #expect(result.inserted == 0)
        #expect(try await store.count() == 1)
    }
}

struct HealthKitErrorTests {

    @Test func messagesNameTheRemedy() {
        #expect(HealthKitError.denied.userMessage.contains("Settings"))
        #expect(!HealthKitError.unavailable.userMessage.isEmpty)
        #expect(HealthKitError.queryFailed("timeout").userMessage.contains("timeout"))
    }
}
