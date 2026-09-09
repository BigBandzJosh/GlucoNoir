//
//  GlucoseStore.swift
//  GlucoNoir
//
//  Owns all writes to the glucose store.
//
//  A @ModelActor because SwiftData's ModelContext is not Sendable: sharing one
//  between the polling task and the UI will not compile under strict
//  concurrency, and the usual workarounds produce data races that surface as
//  store corruption rather than as crashes.
//

import Foundation
import SwiftData

@ModelActor
actor GlucoseStore {

    /// Result of a write, so callers can log what actually changed rather than
    /// assuming every poll brought new data.
    struct UpsertResult: Sendable, Equatable {
        var inserted = 0
        var updated = 0
        var unchanged = 0

        var didChangeAnything: Bool { inserted > 0 || updated > 0 }
    }

    // MARK: Writing

    /// Inserts new readings and updates existing ones in place.
    ///
    /// Upsert rather than insert is essential, not defensive: every poll asks
    /// for a window of readings and nearly all of them are already stored.
    /// Insert-only would accumulate hundreds of thousands of duplicates within
    /// days and silently corrupt every average, time-in-range figure, and chart
    /// derived from the store.
    @discardableResult
    func upsert(_ readings: [ShareGlucoseReading], isBackfilled: Bool = false) throws -> UpsertResult {
        guard !readings.isEmpty else { return UpsertResult() }

        // Fetch the affected span once rather than querying per reading.
        let keys = readings.map { GlucoseReadingRecord.timeKey(for: $0.sampleTime) }
        guard let lowKey = keys.min(), let highKey = keys.max() else { return UpsertResult() }

        let descriptor = FetchDescriptor<GlucoseReadingRecord>(
            predicate: #Predicate { $0.timeKey >= lowKey && $0.timeKey <= highKey }
        )
        let existing = try modelContext.fetch(descriptor)
        var byKey: [Int: GlucoseReadingRecord] = [:]
        for record in existing { byKey[record.timeKey] = record }

        var result = UpsertResult()

        for reading in readings {
            let key = GlucoseReadingRecord.timeKey(for: reading.sampleTime)

            if let record = byKey[key] {
                // Dexcom does occasionally revise a reading after publishing it.
                let valueChanged = record.valueMgdl != reading.valueMgdl
                let trendChanged = record.trendRaw != reading.trend.rawValue
                if valueChanged || trendChanged {
                    record.valueMgdl = reading.valueMgdl
                    record.trendRaw = reading.trend.rawValue
                    result.updated += 1
                } else {
                    result.unchanged += 1
                }
            } else {
                let record = GlucoseReadingRecord(reading, isBackfilled: isBackfilled)
                modelContext.insert(record)
                byKey[key] = record
                result.inserted += 1
            }
        }

        if result.didChangeAnything {
            try modelContext.save()
        }
        return result
    }

    // MARK: Reading

    /// Readings at or after `date`, newest first.
    func readings(since date: Date, limit: Int? = nil) throws -> [ShareGlucoseReading] {
        let key = GlucoseReadingRecord.timeKey(for: date)
        var descriptor = FetchDescriptor<GlucoseReadingRecord>(
            predicate: #Predicate { $0.timeKey >= key },
            sortBy: [SortDescriptor(\.timeKey, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor).map(\.asShareReading)
    }

    /// Newest live reading. Backfilled rows are excluded because they carry no
    /// trend and are not evidence of what is happening now.
    func latestLive() throws -> ShareGlucoseReading? {
        var descriptor = FetchDescriptor<GlucoseReadingRecord>(
            predicate: #Predicate { $0.isBackfilled == false },
            sortBy: [SortDescriptor(\.timeKey, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.asShareReading
    }

    /// Sample time of the newest stored reading, used to size the next fetch
    /// window so a gap since last launch is filled rather than skipped.
    func newestSampleTime() throws -> Date? {
        var descriptor = FetchDescriptor<GlucoseReadingRecord>(
            sortBy: [SortDescriptor(\.timeKey, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.sampleTime
    }

    func oldestSampleTime() throws -> Date? {
        var descriptor = FetchDescriptor<GlucoseReadingRecord>(
            sortBy: [SortDescriptor(\.timeKey, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.sampleTime
    }

    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<GlucoseReadingRecord>())
    }

    // MARK: Export & restore

    /// Every stored reading, oldest first. Used for export.
    func allReadings() throws -> [ShareGlucoseReading] {
        let descriptor = FetchDescriptor<GlucoseReadingRecord>(
            sortBy: [SortDescriptor(\.timeKey, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(\.asShareReading)
    }

    /// Time keys of imported readings, so an export preserves provenance and a
    /// restore does not promote historical rows into live ones.
    func backfilledTimeKeys() throws -> Set<Int> {
        let descriptor = FetchDescriptor<GlucoseReadingRecord>(
            predicate: #Predicate { $0.isBackfilled == true }
        )
        return Set(try modelContext.fetch(descriptor).map(\.timeKey))
    }

    /// Merges a backup into the store.
    ///
    /// Additive by design: restoring never deletes. A backup restored onto a
    /// store that has since collected new readings should yield the union, not
    /// replace the present with the past.
    @discardableResult
    func restore(_ document: BackupDocument) throws -> UpsertResult {
        let live = document.readings.filter { !$0.b }.map(\.asShareReading)
        let imported = document.readings.filter { $0.b }.map(\.asShareReading)

        var total = UpsertResult()
        if !live.isEmpty {
            let r = try upsert(live, isBackfilled: false)
            total.inserted += r.inserted; total.updated += r.updated; total.unchanged += r.unchanged
        }
        if !imported.isEmpty {
            let r = try upsert(imported, isBackfilled: true)
            total.inserted += r.inserted; total.updated += r.updated; total.unchanged += r.unchanged
        }
        return total
    }

    // MARK: Maintenance

    /// Destructive. Only reachable from an explicit user action.
    func deleteAll() throws {
        try modelContext.delete(model: GlucoseReadingRecord.self)
        try modelContext.save()
    }
}

// MARK: - Container

enum GlucoseStoreFactory {

    /// The store URL lives behind this single accessor so moving it into an App
    /// Group container — needed once widgets exist — is a one-line change plus
    /// a file move, rather than a refactor.
    static func storeURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("GlucoNoir.store")
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = inMemory
            ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: storeURL())

        return try ModelContainer(
            for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
            migrationPlan: GlucoNoirMigrationPlan.self,
            configurations: configuration
        )
    }
}
