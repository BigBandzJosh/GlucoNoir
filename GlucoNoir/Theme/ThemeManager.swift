//
//  ThemeManager.swift
//  GlucoNoir
//

import SwiftUI
import Combine

// MARK: - Theme selection

nonisolated enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, trueBlack, softDark, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:    return "System"
        case .trueBlack: return "True Black"
        case .softDark:  return "Soft Dark"
        case .light:     return "Light"
        }
    }

    /// `system` follows the device appearance, defaulting dark to True Black —
    /// the OLED-friendly choice, and the reason this app exists.
    func palette(systemIsDark: Bool) -> Palette {
        switch self {
        case .system:    return systemIsDark ? .trueBlack : .light
        case .trueBlack: return .trueBlack
        case .softDark:  return .softDark
        case .light:     return .light
        }
    }
}

// MARK: - Bedside schedule

nonisolated struct BedsideSchedule: Equatable, Sendable {
    var isScheduleEnabled: Bool = true
    var startHour: Int = 22
    var startMinute: Int = 0
    var endHour: Int = 7
    var endMinute: Int = 0

    private var startMinutes: Int { startHour * 60 + startMinute }
    private var endMinutes: Int { endHour * 60 + endMinute }

    /// True when `date` falls inside the window.
    ///
    /// The window normally crosses midnight (22:00 to 07:00), so it cannot be a
    /// simple range comparison — that would make the default schedule never
    /// activate, which is the whole feature failing silently.
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard isScheduleEnabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let now = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinutes == endMinutes { return false }
        if startMinutes < endMinutes {
            return now >= startMinutes && now < endMinutes
        }
        // Crosses midnight.
        return now >= startMinutes || now < endMinutes
    }

    var description: String {
        String(format: "%02d:%02d – %02d:%02d", startHour, startMinute, endHour, endMinute)
    }
}

// MARK: - Manager

@MainActor
final class ThemeManager: ObservableObject {

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// Manual override. Turning it on outside the schedule enables Bedside Mode;
    /// turning it off inside the schedule suppresses it until the window ends.
    @Published private(set) var manualBedside: Bool?

    @Published var schedule: BedsideSchedule {
        didSet { persistSchedule() }
    }

    @Published var dimming: Double {
        didSet { defaults.set(dimming, forKey: Keys.dimming) }
    }

    /// Recomputed on a timer so the schedule takes effect without the user
    /// having to reopen the app.
    @Published private(set) var now: Date = .now

    private let defaults: UserDefaults
    private var timer: AnyCancellable?

    private enum Keys {
        static let theme = "appTheme"
        static let dimming = "bedsideDimming"
        static let scheduleEnabled = "bedsideScheduleEnabled"
        static let startHour = "bedsideStartHour"
        static let startMinute = "bedsideStartMinute"
        static let endHour = "bedsideEndHour"
        static let endMinute = "bedsideEndMinute"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        self.dimming = defaults.object(forKey: Keys.dimming) as? Double ?? 0.45

        var schedule = BedsideSchedule()
        if defaults.object(forKey: Keys.startHour) != nil {
            schedule.isScheduleEnabled = defaults.bool(forKey: Keys.scheduleEnabled)
            schedule.startHour = defaults.integer(forKey: Keys.startHour)
            schedule.startMinute = defaults.integer(forKey: Keys.startMinute)
            schedule.endHour = defaults.integer(forKey: Keys.endHour)
            schedule.endMinute = defaults.integer(forKey: Keys.endMinute)
        }
        self.schedule = schedule

        timer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    /// Whether Bedside Mode is currently in effect.
    var isBedsideActive: Bool {
        if let manualBedside { return manualBedside }
        return schedule.isActive(at: now)
    }

    var isWithinSchedule: Bool { schedule.isActive(at: now) }

    func toggleBedside() {
        manualBedside = !isBedsideActive
    }

    /// Returns to schedule-driven behaviour.
    func clearManualOverride() {
        manualBedside = nil
    }

    func palette(systemIsDark: Bool) -> Palette {
        isBedsideActive
            ? .bedside(dimming: dimming)
            : theme.palette(systemIsDark: systemIsDark)
    }

    private func persistSchedule() {
        defaults.set(schedule.isScheduleEnabled, forKey: Keys.scheduleEnabled)
        defaults.set(schedule.startHour, forKey: Keys.startHour)
        defaults.set(schedule.startMinute, forKey: Keys.startMinute)
        defaults.set(schedule.endHour, forKey: Keys.endHour)
        defaults.set(schedule.endMinute, forKey: Keys.endMinute)
    }
}
