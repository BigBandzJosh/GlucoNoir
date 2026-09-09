//
//  SpikeLog.swift
//  GlucoNoir
//
//  Append-only log for the Phase 1 spike. Survives app restarts so a 48-hour
//  run can be reviewed after the fact rather than watched live.
//

import Foundation
import Combine

@MainActor
final class SpikeLog: ObservableObject {
    static let shared = SpikeLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let kind: Kind
        let text: String

        enum Kind: String {
            case reading, connection, error, info
        }
    }

    /// Newest first. Capped so the UI stays responsive over a long run.
    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 500

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("spike-log.txt")
    }()

    private lazy var stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    func log(_ kind: Entry.Kind, _ text: String) {
        let entry = Entry(date: Date(), kind: kind, text: text)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }

        let line = "\(stamp.string(from: entry.date))\t\(kind.rawValue)\t\(text)\n"
        print(line, terminator: "")
        append(line)
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    var logFileURL: URL { fileURL }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
