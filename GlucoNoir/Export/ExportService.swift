//
//  ExportService.swift
//  GlucoNoir
//
//  Getting data out.
//
//  Everything else in this app can be rebuilt from source. The readings cannot:
//  Dexcom Share retains 24 hours and Apple Health 90 days, so history beyond
//  that exists only here. Export is therefore a v1 feature, not a v3 one.
//

import Foundation

nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case json
    case nightscout

    var id: String { rawValue }

    var label: String {
        switch self {
        case .csv:        return "CSV"
        case .json:       return "JSON backup"
        case .nightscout: return "Nightscout"
        }
    }

    var detail: String {
        switch self {
        case .csv:        return "Spreadsheet-friendly. One row per reading."
        case .json:       return "Full fidelity. This is the file that restores."
        case .nightscout: return "Entries format, for the wider T1D tooling ecosystem."
        }
    }

    var fileExtension: String { self == .csv ? "csv" : "json" }
}

nonisolated struct ExportResult: Equatable, Sendable {
    let url: URL
    let readingCount: Int
    let byteCount: Int

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

nonisolated enum ExportError: Error, Equatable {
    case noData
    case writeFailed(String)
    case readFailed(String)
    case unrecognisedFormat

    var userMessage: String {
        switch self {
        case .noData:                return "There are no readings to export."
        case .writeFailed(let d):    return "Could not write the file: \(d)"
        case .readFailed(let d):     return "Could not read the file: \(d)"
        case .unrecognisedFormat:    return "That file isn't a GlucoNoir backup."
        }
    }
}

// MARK: - Backup document

/// The JSON backup envelope.
///
/// Versioned and self-describing so a file can be validated before anything is
/// written, and so a future schema change can migrate old backups rather than
/// rejecting them.
nonisolated struct BackupDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let magic = "gluconoir.backup"

    var format: String = BackupDocument.magic
    var version: Int = BackupDocument.currentVersion
    var exportedAt: Date
    var readingCount: Int
    var readings: [BackupReading]

    struct BackupReading: Codable, Equatable, Sendable {
        /// Whole seconds since 1970 — the same key the store deduplicates on.
        let t: Int
        /// mg/dL, canonical.
        let v: Int
        /// Raw trend value.
        let d: Int
        /// Imported from Health rather than polled live.
        let b: Bool
    }

    var isValid: Bool { format == Self.magic && version <= Self.currentVersion }
}

// MARK: - Service

actor ExportService {

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Export

    func export(_ readings: [ShareGlucoseReading],
                format: ExportFormat,
                backfilledKeys: Set<Int> = []) throws -> ExportResult {
        guard !readings.isEmpty else { throw ExportError.noData }

        let ordered = readings.sorted { $0.sampleTime < $1.sampleTime }
        let data: Data
        switch format {
        case .csv:        data = try csv(ordered)
        case .json:       data = try json(ordered, backfilledKeys: backfilledKeys)
        case .nightscout: data = try nightscout(ordered)
        }

        let url = try temporaryURL(for: format)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return ExportResult(url: url, readingCount: ordered.count, byteCount: data.count)
    }

    /// Each export gets its own directory, so the user-facing filename can stay
    /// readable while remaining unique.
    ///
    /// A timestamped filename alone is not enough: at minute resolution two
    /// exports in the same minute collide and the second silently overwrites
    /// the first — including a CSV overwriting a JSON backup the user had not
    /// yet shared.
    private func temporaryURL(for format: ExportFormat) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "GlucoNoir-\(format.rawValue)-\(stamp.string(from: Date())).\(format.fileExtension)"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return directory.appendingPathComponent(name)
    }

    // MARK: Formats

    private func csv(_ readings: [ShareGlucoseReading]) throws -> Data {
        // Both units are written so the file is useful without knowing the
        // app's display setting, and mg/dL stays the canonical column.
        var out = "timestamp,epoch_seconds,mg_dl,mmol_l,trend\n"
        out.reserveCapacity(readings.count * 64)

        for reading in readings {
            let mmol = String(format: "%.1f", Double(reading.valueMgdl) / GlucoseUnit.mmolDivisor)
            out += "\(isoFormatter.string(from: reading.sampleTime)),"
            out += "\(Int(reading.sampleTime.timeIntervalSince1970)),"
            out += "\(reading.valueMgdl),"
            out += "\(mmol),"
            out += "\(reading.trend.nightscoutDirection)\n"
        }

        guard let data = out.data(using: .utf8) else {
            throw ExportError.writeFailed("could not encode CSV as UTF-8")
        }
        return data
    }

    private func json(_ readings: [ShareGlucoseReading], backfilledKeys: Set<Int>) throws -> Data {
        let entries = readings.map { reading -> BackupDocument.BackupReading in
            let key = Int(reading.sampleTime.timeIntervalSince1970.rounded())
            return BackupDocument.BackupReading(
                t: key,
                v: reading.valueMgdl,
                d: reading.trend.rawValue,
                b: backfilledKeys.contains(key)
            )
        }
        let document = BackupDocument(
            exportedAt: Date(),
            readingCount: entries.count,
            readings: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(document)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    private func nightscout(_ readings: [ShareGlucoseReading]) throws -> Data {
        let entries = readings.map { reading -> [String: Any] in
            [
                "type": "sgv",
                "sgv": reading.valueMgdl,
                "date": Int(reading.sampleTime.timeIntervalSince1970 * 1000),
                "dateString": isoFormatter.string(from: reading.sampleTime),
                "direction": reading.trend.nightscoutDirection,
                "device": "GlucoNoir"
            ]
        }
        do {
            return try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Restore

    /// Parses a backup file. Validates before returning anything, so a wrong
    /// file is rejected rather than partially applied.
    func readBackup(at url: URL) throws -> BackupDocument {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExportError.readFailed(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(BackupDocument.self, from: data),
              document.isValid else {
            throw ExportError.unrecognisedFormat
        }
        return document
    }
}

// MARK: - Nightscout trend names

nonisolated extension ShareTrend {
    /// Nightscout's `direction` strings. Distinct from Dexcom's own naming for
    /// the non-directional states.
    var nightscoutDirection: String {
        switch self {
        case .doubleUp:       return "DoubleUp"
        case .singleUp:       return "SingleUp"
        case .fortyFiveUp:    return "FortyFiveUp"
        case .flat:           return "Flat"
        case .fortyFiveDown:  return "FortyFiveDown"
        case .singleDown:     return "SingleDown"
        case .doubleDown:     return "DoubleDown"
        case .none:           return "NONE"
        case .notComputable:  return "NOT COMPUTABLE"
        case .rateOutOfRange: return "RATE OUT OF RANGE"
        }
    }
}

nonisolated extension BackupDocument.BackupReading {
    var asShareReading: ShareGlucoseReading {
        ShareGlucoseReading(
            sampleTime: Date(timeIntervalSince1970: Double(t)),
            valueMgdl: v,
            trend: ShareTrend(rawValue: d) ?? .none
        )
    }
}
