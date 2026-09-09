//
//  ExportTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
import SwiftData
@testable import GlucoNoir

private let base = Date(timeIntervalSince1970: 1_757_000_000)

private func reading(_ minutesAgo: Int, _ value: Int, _ trend: ShareTrend = .flat) -> ShareGlucoseReading {
    ShareGlucoseReading(sampleTime: base.addingTimeInterval(-Double(minutesAgo * 60)),
                        valueMgdl: value, trend: trend)
}

private func makeStore() throws -> GlucoseStore {
    let container = try ModelContainer(
        for: Schema(versionedSchema: GlucoNoirSchemaV2.self),
        migrationPlan: GlucoNoirMigrationPlan.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return GlucoseStore(modelContainer: container)
}

private func text(_ url: URL) throws -> String {
    String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
}

struct CSVExportTests {

    @Test func writesHeaderAndOneRowPerReading() async throws {
        let result = try await ExportService().export([reading(10, 100), reading(5, 105)], format: .csv)
        let lines = try text(result.url).split(separator: "\n")
        #expect(lines.first == "timestamp,epoch_seconds,mg_dl,mmol_l,trend")
        #expect(lines.count == 3)
        #expect(result.readingCount == 2)
    }

    /// Both units are written so the file makes sense without knowing which
    /// the app was displaying.
    @Test func includesBothUnits() async throws {
        let result = try await ExportService().export([reading(0, 100)], format: .csv)
        let body = try text(result.url).split(separator: "\n")[1]
        #expect(body.contains("100"))
        #expect(body.contains("5.5"), "mmol/L column should match Dexcom's conversion")
    }

    @Test func writesOldestFirstRegardlessOfInputOrder() async throws {
        let result = try await ExportService().export([reading(0, 110), reading(10, 100)], format: .csv)
        let lines = try text(result.url).split(separator: "\n")
        #expect(lines[1].contains(",100,"))
        #expect(lines[2].contains(",110,"))
    }

    @Test func rejectsEmptyExport() async {
        await #expect(throws: ExportError.noData) {
            _ = try await ExportService().export([], format: .csv)
        }
    }
}

struct NightscoutExportTests {

    @Test func emitsEntriesInNightscoutShape() async throws {
        let result = try await ExportService().export([reading(0, 142, .fortyFiveUp)], format: .nightscout)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [[String: Any]]
        let entry = try #require(json?.first)

        #expect(entry["type"] as? String == "sgv")
        #expect(entry["sgv"] as? Int == 142)
        #expect(entry["direction"] as? String == "FortyFiveUp")
        #expect(entry["date"] as? Int == Int(base.timeIntervalSince1970 * 1000))
    }

    /// Nightscout names the non-directional states differently from Dexcom.
    @Test func mapsNonDirectionalStates() {
        #expect(ShareTrend.none.nightscoutDirection == "NONE")
        #expect(ShareTrend.notComputable.nightscoutDirection == "NOT COMPUTABLE")
        #expect(ShareTrend.rateOutOfRange.nightscoutDirection == "RATE OUT OF RANGE")
        #expect(ShareTrend.doubleDown.nightscoutDirection == "DoubleDown")
    }
}

struct BackupRoundTripTests {

    @Test func backupContainsEveryReading() async throws {
        let readings = (0..<50).map { reading($0 * 5, 100 + $0) }
        let result = try await ExportService().export(readings, format: .json)
        let document = try await ExportService().readBackup(at: result.url)

        #expect(document.readingCount == 50)
        #expect(document.readings.count == 50)
        #expect(document.isValid)
    }

    /// The whole point: a backup must restore onto a fresh install.
    @Test func restoresOntoAnEmptyStore() async throws {
        let readings = (0..<20).map { reading($0 * 5, 100 + $0) }
        let file = try await ExportService().export(readings, format: .json)
        let document = try await ExportService().readBackup(at: file.url)

        let store = try makeStore()
        let restored = try await store.restore(document)

        #expect(restored.inserted == 20)
        #expect(try await store.count() == 20)

        let back = try await store.readings(since: .distantPast)
        #expect(back.map(\.valueMgdl).sorted() == readings.map(\.valueMgdl).sorted())
    }

    /// Provenance must survive the round trip, or restoring would promote
    /// historical Health rows into live ones and let them be shown as current.
    @Test func preservesBackfilledProvenance() async throws {
        let live = reading(10, 100)
        let imported = reading(5, 200)
        let importedKey = Int(imported.sampleTime.timeIntervalSince1970.rounded())

        let file = try await ExportService().export([live, imported], format: .json,
                                                    backfilledKeys: [importedKey])
        let document = try await ExportService().readBackup(at: file.url)

        let store = try makeStore()
        _ = try await store.restore(document)

        let latest = try await store.latestLive()
        #expect(latest?.valueMgdl == 100, "an imported reading was restored as live")
        #expect(try await store.count() == 2)
    }

    /// Restoring is additive: it must never delete readings collected since.
    @Test func restoreMergesRatherThanReplaces() async throws {
        let store = try makeStore()
        _ = try await store.upsert([reading(0, 999)])

        let file = try await ExportService().export([reading(60, 100), reading(55, 105)], format: .json)
        let document = try await ExportService().readBackup(at: file.url)
        _ = try await store.restore(document)

        #expect(try await store.count() == 3, "restoring must not discard existing readings")
    }

    @Test func restoringTwiceDoesNotDuplicate() async throws {
        let file = try await ExportService().export((0..<10).map { reading($0 * 5, 100) }, format: .json)
        let document = try await ExportService().readBackup(at: file.url)

        let store = try makeStore()
        _ = try await store.restore(document)
        let second = try await store.restore(document)

        #expect(second.inserted == 0)
        #expect(try await store.count() == 10)
    }

    @Test func preservesTrendValues() async throws {
        let file = try await ExportService().export([reading(0, 100, .doubleDown)], format: .json)
        let document = try await ExportService().readBackup(at: file.url)
        #expect(document.readings.first?.asShareReading.trend == .doubleDown)
    }
}

struct BackupValidationTests {

    @Test func rejectsUnrelatedJSON() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-backup-\(UUID().uuidString).json")
        try #"{"hello":"world"}"#.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExportError.unrecognisedFormat) {
            _ = try await ExportService().readBackup(at: url)
        }
    }

    @Test func rejectsAFutureBackupVersion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("future-\(UUID().uuidString).json")
        let payload = #"{"format":"gluconoir.backup","version":99,"exportedAt":"2026-09-09T00:00:00Z","readingCount":0,"readings":[]}"#
        try payload.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExportError.unrecognisedFormat) {
            _ = try await ExportService().readBackup(at: url)
        }
    }

    @Test func reportsMissingFileClearly() async {
        let url = URL(fileURLWithPath: "/nonexistent/backup.json")
        await #expect(throws: ExportError.self) {
            _ = try await ExportService().readBackup(at: url)
        }
    }
}

struct ExportVolumeTests {

    /// A 90-day export is ~26,000 readings — the real case.
    @Test func exportsNinetyDaysQuickly() async throws {
        let readings = (0..<25_920).map { i in
            ShareGlucoseReading(sampleTime: base.addingTimeInterval(-Double(i * 300)),
                                valueMgdl: 100 + (i % 80), trend: .flat)
        }
        let start = Date()
        let result = try await ExportService().export(readings, format: .csv)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.readingCount == 25_920)
        #expect(elapsed < 10, "90-day CSV export took \(elapsed)s")
        #expect(result.byteCount > 0)
    }
}
