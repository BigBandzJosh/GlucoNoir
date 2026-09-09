//
//  ShareMonitor.swift
//  GlucoNoir
//
//  Drives polling and owns the state the UI observes.
//
//  Poll timing is anchored to the sensor's own 5-minute cadence rather than a
//  fixed interval: after a reading at T, the next is due at T+5min, so we wake
//  shortly after that instead of polling blindly.
//

import Foundation
import Combine
import UIKit
import SwiftData

@MainActor
final class ShareMonitor: ObservableObject {

    enum Status: Equatable {
        case notConfigured
        case idle
        case polling
        case ok
        case failed(String)
        case locked(String)
    }

    @Published private(set) var status: Status = .notConfigured
    @Published private(set) var latest: ShareGlucoseReading?
    @Published private(set) var recent: [ShareGlucoseReading] = []
    @Published private(set) var lastPollAt: Date?
    @Published private(set) var credentials: ShareCredentials?

    /// Display preference only — readings are always stored as mg/dL.
    @Published var unit: GlucoseUnit {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey) }
    }
    private static let unitKey = "glucoseUnit"

    private let client = DexcomShareClient()
    private let log = SpikeLog.shared
    private var store: GlucoseStore?
    private let healthKit = HealthKitBackfill()
    private let exporter = ExportService()

    @Published private(set) var exportState: ExportState = .idle

    enum ExportState: Equatable {
        case idle
        case working
        case ready(ExportResult)
        case restored(inserted: Int, total: Int)
        case failed(String)
    }

    /// Outcome of the most recent Health import, surfaced in Settings.
    @Published private(set) var backfillStatus: BackfillStatus = .idle

    enum BackfillStatus: Equatable {
        case idle
        case running
        case done(inserted: Int, at: Date)
        case failed(String)
        case unavailable
    }
    /// How far back the store holds data, shown so history growth is visible.
    @Published private(set) var storedCount = 0

    /// Readings for the selected chart window, read from the store rather than
    /// from memory so the chart is populated on a cold launch, before the first
    /// poll returns, and works with no network at all.
    @Published private(set) var windowReadings: [ShareGlucoseReading] = []

    /// Computed once when the window's data changes, never in a view body.
    ///
    /// These were computed properties read directly from the view. With a
    /// 30-day window (~8,600 readings) and a one-second timer driving the age
    /// label, that recomputed a full statistics pass — including a median that
    /// sorts every reading — once per second.
    @Published private(set) var statistics: GlucoseStatistics = .empty
    @Published private(set) var windowCoverage: Double = 0

    @Published var chartWindow: ChartWindow = .h3 {
        didSet {
            UserDefaults.standard.set(chartWindow.rawValue, forKey: Self.windowKey)
            Task { await loadWindow() }
        }
    }
    private static let windowKey = "chartWindow"
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// Sensor cadence. Everything else is derived from it.
    private let sensorInterval: TimeInterval = 5 * 60
    /// Small offset so we poll just after the cloud should have the reading.
    private let pollOffset: TimeInterval = 25

    init(store: GlucoseStore? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.unitKey)
        self.unit = saved.flatMap(GlucoseUnit.init(rawValue:)) ?? .deviceDefault
        let savedWindow = UserDefaults.standard.string(forKey: Self.windowKey)
        self.chartWindow = savedWindow.flatMap(ChartWindow.init(rawValue:)) ?? .h3
        self.store = store

        if let stored = KeychainStore.load() {
            credentials = stored
            Task {
                // Show stored history immediately; do not wait on the network.
                await loadFromStore()
                await applyCredentials(stored)
                await backfillFromHealthIfDue()
            }
        }
    }

    func attach(store: GlucoseStore) {
        self.store = store
        Task { await loadFromStore() }
    }

    /// Populates the UI from disk so a cold launch shows history at once.
    private func loadFromStore() async {
        guard let store else { return }
        do {
            let cutoff = Date().addingTimeInterval(-3 * 3600)
            let history = try await store.readings(since: cutoff)
            let total = try await store.count()
            storedCount = total
            if !history.isEmpty {
                recent = history
                latest = try await store.latestLive() ?? history.first
            }
        } catch {
            log.log(.error, "Store read failed: \(error.localizedDescription)")
        }
        await loadWindow()
    }

    /// Refreshes the chart's data for the current window.
    private func loadWindow() async {
        guard let store else { return }
        do {
            let window = chartWindow
            let cutoff = Date().addingTimeInterval(-window.duration)
            let readings = try await store.readings(since: cutoff)
            windowReadings = readings
            statistics = GlucoseStatistics.compute(readings: readings,
                                                   windowDuration: window.duration)
            windowCoverage = ChartDataBuilder.coverage(readings: readings, window: window)
        } catch {
            log.log(.error, "Window read failed: \(error.localizedDescription)")
        }
    }

    // MARK: Export & restore

    func export(_ format: ExportFormat) async {
        guard let store else { return }
        exportState = .working
        do {
            let readings = try await store.allReadings()
            let backfilled = format == .json ? try await store.backfilledTimeKeys() : []
            let result = try await exporter.export(readings, format: format, backfilledKeys: backfilled)
            exportState = .ready(result)
            log.log(.info, "Exported \(result.readingCount) readings as \(format.label) (\(result.sizeDescription))")
        } catch let error as ExportError {
            exportState = .failed(error.userMessage)
            log.log(.error, "Export failed: \(error.userMessage)")
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    func restore(from url: URL) async {
        guard let store else { return }
        exportState = .working
        do {
            let document = try await exporter.readBackup(at: url)
            let result = try await store.restore(document)
            storedCount = try await store.count()
            exportState = .restored(inserted: result.inserted, total: storedCount)
            log.log(.info, "Restored \(result.inserted) new readings from backup (\(storedCount) total)")
            await loadFromStore()
        } catch let error as ExportError {
            exportState = .failed(error.userMessage)
            log.log(.error, "Restore failed: \(error.userMessage)")
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    func clearExportState() { exportState = .idle }

    // MARK: HealthKit backfill

    /// Prompts for Health access, then imports. Called from Settings.
    func importFromHealth() async {
        guard HealthKitBackfill.isAvailable else {
            backfillStatus = .unavailable
            return
        }
        do {
            try await healthKit.requestAuthorization()
            await healthKit.resetAnchor()
            await runBackfill()
        } catch let error as HealthKitError {
            backfillStatus = .failed(error.userMessage)
            log.log(.error, "Health: \(error.userMessage)")
        } catch {
            backfillStatus = .failed(error.localizedDescription)
        }
    }

    /// Daily top-up, run quietly on launch. Never prompts.
    private func backfillFromHealthIfDue() async {
        guard HealthKitBackfill.isAvailable else { return }
        guard await healthKit.isBackfillDue else { return }
        await runBackfill()
    }

    private func runBackfill() async {
        guard let store else { return }
        backfillStatus = .running
        do {
            let result = try await healthKit.backfill(into: store)
            storedCount = try await store.count()
            backfillStatus = .done(inserted: result.inserted, at: Date())
            if result.didChangeAnything {
                log.log(.info, "Health backfill: +\(result.inserted) readings from \(result.sources.joined(separator: ", ")) (\(storedCount) total)")
            } else if result.samplesRead == 0 {
                // Read denial and an empty data set are indistinguishable by
                // design, so say both rather than guessing which happened.
                log.log(.info, "Health backfill: no Dexcom samples found (access may be denied)")
            }
            await loadFromStore()
        } catch let error as HealthKitError {
            backfillStatus = .failed(error.userMessage)
            log.log(.error, "Health backfill failed: \(error.userMessage)")
        } catch {
            backfillStatus = .failed(error.localizedDescription)
            log.log(.error, "Health backfill failed: \(error.localizedDescription)")
        }
    }



    // MARK: Configuration

    func save(_ new: ShareCredentials) async -> Result<Void, ShareError> {
        await client.configure(new)
        do {
            try await client.verifyCredentials()
        } catch let error as ShareError {
            log.log(.error, "Credential check failed: \(error.userMessage)")
            status = error == .accountLocked ? .locked(error.userMessage) : .failed(error.userMessage)
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        do { try KeychainStore.save(new) } catch {
            log.log(.error, "Keychain: \(error.localizedDescription)")
        }
        credentials = new
        log.log(.info, "Credentials verified for \(new.region.displayName)")
        start()
        return .success(())
    }

    func signOut(deleteHistory: Bool = false) {
        stop()
        if deleteHistory, let store {
            Task {
                try? await store.deleteAll()
                storedCount = 0
            }
        }
        KeychainStore.clear()
        credentials = nil
        latest = nil
        recent = []
        status = .notConfigured
        Task { await client.configure(nil) }
        log.log(.info, "Signed out, credentials cleared")
    }

    private func applyCredentials(_ c: ShareCredentials) async {
        await client.configure(c)
        start()
    }

    // MARK: Polling

    func start() {
        stop()
        status = .idle
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let delay = await self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called on app activation so opening the app always shows current data.
    func refreshNow() {
        Task { await pollOnce() }
    }

    private func pollOnce() async {
        guard credentials?.isComplete == true else {
            status = .notConfigured
            return
        }
        status = .polling
        do {
            let window = await fetchWindow()
            let readings = try await client.fetchReadings(minutes: window.minutes, maxCount: window.maxCount)
            lastPollAt = Date()
            consecutiveFailures = 0

            guard let newest = readings.first else {
                status = .failed("No readings returned")
                log.log(.error, "Poll returned no readings")
                return
            }

            // Persist before publishing, so what the UI shows is what survived.
            if let store {
                do {
                    let result = try await store.upsert(readings)
                    storedCount = try await store.count()
                    if result.didChangeAnything {
                        log.log(.info, "Stored +\(result.inserted) new, \(result.updated) revised (\(storedCount) total)")
                    }
                } catch {
                    log.log(.error, "Store write failed: \(error.localizedDescription)")
                }
            }

            let isNew = newest.sampleTime != latest?.sampleTime
            latest = newest
            recent = readings
            status = .ok
            await loadWindow()

            if isNew {
                let arrow = newest.trend.arrow ?? "—"
                log.log(.reading,
                        "\(newest.displayValue(in: unit)) \(unit.label) \(arrow) | age \(Int(newest.age))s | \(newest.trend.describes)")
            }
        } catch let error as ShareError {
            consecutiveFailures += 1
            lastPollAt = Date()
            if error.isTerminal {
                status = error == .accountLocked ? .locked(error.userMessage) : .failed(error.userMessage)
                log.log(.error, "Terminal: \(error.userMessage) — polling stopped")
                stop()
            } else {
                status = .failed(error.userMessage)
                log.log(.error, "Poll failed (\(consecutiveFailures)): \(error.userMessage)")
            }
        } catch {
            consecutiveFailures += 1
            status = .failed(error.localizedDescription)
        }
    }

    /// Sizes the request to cover everything since the newest stored reading,
    /// so reopening the app after hours away fills the gap rather than
    /// fetching only the last three hours and leaving a hole in history.
    /// Clamped to Share's documented maximums (1440 minutes, 288 readings).
    private func fetchWindow() async -> (minutes: Int, maxCount: Int) {
        let defaultMinutes = 180
        guard let store, let newest = try? await store.newestSampleTime() else {
            return (defaultMinutes, 36)
        }
        let gapMinutes = Int(Date().timeIntervalSince(newest) / 60)
        // Margin absorbs clock skew and any reading published late.
        let minutes = min(1440, max(defaultMinutes, gapMinutes + 15))
        let maxCount = min(288, max(36, minutes / 5 + 6))
        return (minutes, maxCount)
    }

    /// Aligns to the sensor cadence on success; backs off on failure.
    private func nextDelay() -> TimeInterval {
        if consecutiveFailures > 0 {
            // 30s, 60s, 120s, 300s cap — transient errors only; terminal ones stop.
            let backoff = [30.0, 60.0, 120.0, 300.0]
            return backoff[min(consecutiveFailures - 1, backoff.count - 1)]
        }
        guard let latest else { return 60 }
        let due = latest.sampleTime.addingTimeInterval(sensorInterval + pollOffset)
        let interval = due.timeIntervalSinceNow
        // If we are already past due the cloud is lagging; check again shortly.
        return interval > 5 ? min(interval, sensorInterval) : 30
    }

    // MARK: Display helpers

    var ageDescription: String {
        guard let latest else { return "—" }
        let age = latest.age
        if age < 90 { return "\(Int(age))s ago" }
        return "\(Int(age / 60)) min ago"
    }

    /// Thresholds are tighter than a cloud-latency design would allow because
    /// Share adds only a minute or two on top of the sensor's own cadence.
    var freshness: Freshness {
        guard let latest else { return .none }
        switch latest.age {
        case ..<(12 * 60): return .fresh
        case ..<(30 * 60): return .stale
        default:           return .critical
        }
    }

    enum Freshness { case none, fresh, stale, critical }
}
