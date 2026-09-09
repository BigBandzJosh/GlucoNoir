//
//  GlucoNoirSchema.swift
//  GlucoNoir
//
//  Versioned SwiftData schema.
//
//  Versioning exists from the first release on purpose. The schema will change
//  when event logging arrives, and by then the store will hold months of
//  readings that cannot be re-fetched — Dexcom Share only retains 24 hours.
//  Retrofitting versioning onto a populated store is far more expensive than
//  carrying it from the start.
//
//  Two constraints are observed throughout, both imposed by SwiftData's
//  CloudKit backing (a v3 goal). Adopting them now costs nothing; discovering
//  them later would mean migrating a full store:
//    1. No @Attribute(.unique) anywhere — deduplication is enforced in
//       GlucoseStore instead.
//    2. Every property has a default value.
//

import Foundation
import SwiftData

// MARK: - V1

enum GlucoNoirSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [GlucoseReadingRecord.self] }

    @Model
    final class GlucoseReadingRecord {
        /// Whole seconds since 1970. The deduplication key.
        ///
        /// An Int rather than the Date itself: Date equality is floating point,
        /// and Share returns millisecond precision, so matching on Date risks
        /// near-miss duplicates that would quietly corrupt every aggregate.
        var timeKey: Int = 0

        var sampleTime: Date = Date.distantPast
        /// Canonical storage is always integer mg/dL; unit conversion happens
        /// at display time only, so switching units is lossless.
        var valueMgdl: Int = 0
        /// Raw ShareTrend value, stored as Int so an unknown future trend does
        /// not fail decoding of the whole record.
        var trendRaw: Int = 0
        var sourceRaw: String = "share"

        init(timeKey: Int = 0,
             sampleTime: Date = .distantPast,
             valueMgdl: Int = 0,
             trendRaw: Int = 0,
             sourceRaw: String = "share") {
            self.timeKey = timeKey
            self.sampleTime = sampleTime
            self.valueMgdl = valueMgdl
            self.trendRaw = trendRaw
            self.sourceRaw = sourceRaw
        }
    }
}

// MARK: - V2

/// Adds provenance flagging needed by HealthKit backfill.
///
/// Backfilled readings carry no trend and must never be selected as the
/// displayed current value regardless of how their timestamps sort, so the
/// distinction has to be persisted rather than inferred.
enum GlucoNoirSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [GlucoseReadingRecord.self] }

    @Model
    final class GlucoseReadingRecord {
        #Index<GlucoseReadingRecord>([\.timeKey], [\.sampleTime])

        var timeKey: Int = 0
        var sampleTime: Date = Date.distantPast
        var valueMgdl: Int = 0
        var trendRaw: Int = 0
        var sourceRaw: String = "share"

        /// True when the reading came from historical backfill rather than a
        /// live poll. Defaulting to false is what makes the V1→V2 migration
        /// lightweight — existing rows were all live.
        var isBackfilled: Bool = false

        init(timeKey: Int = 0,
             sampleTime: Date = .distantPast,
             valueMgdl: Int = 0,
             trendRaw: Int = 0,
             sourceRaw: String = "share",
             isBackfilled: Bool = false) {
            self.timeKey = timeKey
            self.sampleTime = sampleTime
            self.valueMgdl = valueMgdl
            self.trendRaw = trendRaw
            self.sourceRaw = sourceRaw
            self.isBackfilled = isBackfilled
        }
    }
}

// MARK: - Current

typealias GlucoseReadingRecord = GlucoNoirSchemaV2.GlucoseReadingRecord

enum GlucoNoirMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [GlucoNoirSchemaV1.self, GlucoNoirSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Lightweight: the only change is an added property with a default, so
    /// SwiftData can infer the transformation.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: GlucoNoirSchemaV1.self,
        toVersion: GlucoNoirSchemaV2.self
    )
}

// MARK: - Conversion

extension GlucoseReadingRecord {
    /// Whole-second key derived from a sample time.
    static func timeKey(for date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }

    convenience init(_ reading: ShareGlucoseReading, isBackfilled: Bool = false) {
        self.init(
            timeKey: Self.timeKey(for: reading.sampleTime),
            sampleTime: reading.sampleTime,
            valueMgdl: reading.valueMgdl,
            trendRaw: reading.trend.rawValue,
            sourceRaw: "share",
            isBackfilled: isBackfilled
        )
    }

    var asShareReading: ShareGlucoseReading {
        ShareGlucoseReading(
            sampleTime: sampleTime,
            valueMgdl: valueMgdl,
            trend: ShareTrend(rawValue: trendRaw) ?? .none
        )
    }
}
