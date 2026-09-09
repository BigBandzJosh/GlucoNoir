//
//  PersistenceTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
import SwiftData
@testable import GlucoNoir

// MARK: - Helpers

private func makeStore() throws -> GlucoseStore {
    let container = try ModelContainer(
        for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
        migrationPlan: GlucoNoirMigrationPlan.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return GlucoseStore(modelContainer: container)
}

private func reading(_ minutesAgo: Int, _ value: Int, _ trend: ShareTrend = .flat) -> ShareGlucoseReading {
    // Whole seconds so time keys are stable and comparable.
    let t = Date(timeIntervalSince1970: 1_757_000_000 - Double(minutesAgo * 60))
    return ShareGlucoseReading(sampleTime: t, valueMgdl: value, trend: trend)
}

// MARK: - Upsert

struct GlucoseStoreUpsertTests {

    @Test func insertsNewReadings() async throws {
        let store = try makeStore()
        let result = try await store.upsert([reading(10, 100), reading(5, 105), reading(0, 110)])
        #expect(result.inserted == 3)
        #expect(result.updated == 0)
        #expect(try await store.count() == 3)
    }

    /// The central guarantee. Every poll re-delivers readings we already hold;
    /// insert-only storage would accumulate duplicates that corrupt every
    /// aggregate derived from the store.
    @Test func repeatedPollsDoNotDuplicate() async throws {
        let store = try makeStore()
        let batch = [reading(10, 100), reading(5, 105), reading(0, 110)]

        _ = try await store.upsert(batch)
        let second = try await store.upsert(batch)
        let third = try await store.upsert(batch)

        #expect(second.inserted == 0)
        #expect(second.unchanged == 3)
        #expect(third.inserted == 0)
        #expect(try await store.count() == 3, "duplicates accumulated across polls")
    }

    @Test func overlappingWindowsInsertOnlyTheNewOnes() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(15, 90), reading(10, 95), reading(5, 100)])
        // Next poll overlaps by two and brings one new reading.
        let result = try await store.upsert([reading(10, 95), reading(5, 100), reading(0, 105)])

        #expect(result.inserted == 1)
        #expect(result.unchanged == 2)
        #expect(try await store.count() == 4)
    }

    /// Dexcom occasionally revises a published reading.
    @Test func revisedValueUpdatesInPlace() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(5, 100, .flat)])
        let result = try await store.upsert([reading(5, 118, .singleUp)])

        #expect(result.updated == 1)
        #expect(result.inserted == 0)
        #expect(try await store.count() == 1, "a revision must not create a second row")

        let stored = try await store.readings(since: .distantPast)
        #expect(stored.first?.valueMgdl == 118)
        #expect(stored.first?.trend == .singleUp)
    }

    @Test func emptyBatchIsANoOp() async throws {
        let store = try makeStore()
        let result = try await store.upsert([])
        #expect(result == GlucoseStore.UpsertResult())
        #expect(try await store.count() == 0)
    }

    @Test func subSecondDifferencesAreTheSameReading() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_757_000_000)
        _ = try await store.upsert([ShareGlucoseReading(sampleTime: base, valueMgdl: 100, trend: .flat)])
        // Same sample, millisecond jitter — must not become a second row.
        let jittered = base.addingTimeInterval(0.4)
        let result = try await store.upsert([ShareGlucoseReading(sampleTime: jittered, valueMgdl: 100, trend: .flat)])

        #expect(result.inserted == 0)
        #expect(try await store.count() == 1)
    }
}

// MARK: - Queries

struct GlucoseStoreQueryTests {

    @Test func readsBackNewestFirst() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(0, 110), reading(10, 100), reading(5, 105)])
        let all = try await store.readings(since: .distantPast)
        #expect(all.map(\.valueMgdl) == [110, 105, 100])
    }

    @Test func filtersBySince() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(120, 90), reading(10, 100), reading(0, 110)])
        let cutoff = Date(timeIntervalSince1970: 1_757_000_000 - 30 * 60)
        let recent = try await store.readings(since: cutoff)
        #expect(recent.count == 2)
    }

    @Test func respectsLimit() async throws {
        let store = try makeStore()
        _ = try await store.upsert((0..<10).map { reading($0, 100 + $0) })
        let limited = try await store.readings(since: .distantPast, limit: 3)
        #expect(limited.count == 3)
    }

    /// Backfilled rows carry no trend and must never be presented as current.
    @Test func latestLiveIgnoresBackfilledRows() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(10, 100)], isBackfilled: false)
        _ = try await store.upsert([reading(0, 200)], isBackfilled: true)

        let live = try await store.latestLive()
        #expect(live?.valueMgdl == 100, "a backfilled row was selected as the current value")
    }

    @Test func reportsNewestAndOldestSampleTimes() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(60, 90), reading(0, 110)])
        let newest = try await store.newestSampleTime()
        let oldest = try await store.oldestSampleTime()
        #expect(newest == reading(0, 110).sampleTime)
        #expect(oldest == reading(60, 90).sampleTime)
    }

    @Test func deleteAllEmptiesTheStore() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(5, 100), reading(0, 105)])
        try await store.deleteAll()
        #expect(try await store.count() == 0)
    }
}

// MARK: - Durability & migration

/// Serialized: these tests open real SQLite files on disk. Swift Testing runs
/// tests in parallel by default, and SwiftData does not deterministically close
/// a store's file when its container goes out of scope — so a reopen can race a
/// still-draining WAL from another test. Running them in parallel produced an
/// intermittent failure that looked like data loss but was file contention.
@Suite(.serialized)
struct SchemaTests {

    /// History must survive the app being killed. Simulated by discarding the
    /// container and reopening the same file.
    @Test func dataSurvivesContainerRecreation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("durability-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Separate function so the container is released before the reopen.
        func writeInitialData() async throws {
            let container = try ModelContainer(
                for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
                migrationPlan: GlucoNoirMigrationPlan.self,
                configurations: ModelConfiguration(url: url)
            )
            let store = GlucoseStore(modelContainer: container)
            _ = try await store.upsert([reading(10, 100), reading(5, 105), reading(0, 110)])
            #expect(try await store.count() == 3)
        }
        try await writeInitialData()

        // Fresh container over the same file — the app relaunching.
        let reopened = try ModelContainer(
            for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
            migrationPlan: GlucoNoirMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
        let store = GlucoseStore(modelContainer: reopened)
        #expect(try await store.count() == 3, "history did not survive relaunch")
        #expect(try await store.latestLive()?.valueMgdl == 110)
    }

    /// The reason versioning exists. Readings cannot be re-fetched — Share
    /// retains only 24 hours — so a schema change must carry them forward.
    @Test func migratesV1StoreToV2WithoutDataLoss() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write with the old schema, as a previous build would have.
        // Separate function so the V1 container is released before migrating.
        func writeV1Store() throws {
            let v1 = try ModelContainer(
                for: Schema(versionedSchema: GlucoNoirSchemaV1.self),
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(v1)
            for i in 0..<5 {
                context.insert(GlucoNoirSchemaV1.GlucoseReadingRecord(
                    timeKey: 1_757_000_000 - i * 300,
                    sampleTime: Date(timeIntervalSince1970: Double(1_757_000_000 - i * 300)),
                    valueMgdl: 100 + i,
                    trendRaw: ShareTrend.flat.rawValue
                ))
            }
            try context.save()
        }
        try writeV1Store()

        // Reopen under the current schema; the migration plan runs.
        let migrated = try ModelContainer(
            for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
            migrationPlan: GlucoNoirMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
        let store = GlucoseStore(modelContainer: migrated)

        #expect(try await store.count() == 5, "readings were lost during migration")
        let all = try await store.readings(since: .distantPast)
        #expect(all.map(\.valueMgdl) == [100, 101, 102, 103, 104])

        // The added property takes its default, which is what makes this
        // migration lightweight: pre-existing rows were all live.
        let live = try await store.latestLive()
        #expect(live?.valueMgdl == 100)
    }

    @Test func migrationPlanCoversEveryVersion() {
        #expect(GlucoNoirMigrationPlan.schemas.count == 2)
        #expect(GlucoNoirMigrationPlan.stages.count == 1)
        #expect(GlucoNoirSchemaV1.versionIdentifier < GlucoNoirSchemaV2.versionIdentifier)
    }

    /// CloudKit sync (a v3 goal) rejects unique constraints outright.
    /// Deduplication is enforced in GlucoseStore instead.
    @Test func schemaUsesNoUniqueConstraints() {
        let schema = Schema(versionedSchema: GlucoNoirSchemaV2.self)
        for entity in schema.entities {
            for property in entity.properties {
                if let attribute = property as? Schema.Attribute {
                    #expect(!attribute.isUnique, "\(entity.name).\(property.name) is unique — incompatible with CloudKit")
                }
            }
        }
    }
}
