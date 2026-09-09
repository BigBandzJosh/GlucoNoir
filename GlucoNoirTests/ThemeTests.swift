//
//  ThemeTests.swift
//  GlucoNoirTests
//

import Testing
import Foundation
import SwiftUI
@testable import GlucoNoir

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 9; c.day = 8
    c.hour = hour; c.minute = minute
    return Calendar.current.date(from: c)!
}

struct BedsideScheduleTests {

    /// The default window crosses midnight. A naive range comparison would make
    /// it never activate — the whole feature failing silently at exactly the
    /// hours it exists for.
    @Test func overnightWindowActivatesAcrossMidnight() {
        let s = BedsideSchedule()   // 22:00 – 07:00
        #expect(s.isActive(at: at(23)))
        #expect(s.isActive(at: at(2)))
        #expect(s.isActive(at: at(6, 59)))
        #expect(s.isActive(at: at(22)))
    }

    @Test func overnightWindowIsInactiveDuringTheDay() {
        let s = BedsideSchedule()
        #expect(!s.isActive(at: at(7)))
        #expect(!s.isActive(at: at(12)))
        #expect(!s.isActive(at: at(21, 59)))
    }

    @Test func sameDayWindowDoesNotWrap() {
        var s = BedsideSchedule()
        s.startHour = 13; s.endHour = 17
        #expect(s.isActive(at: at(14)))
        #expect(!s.isActive(at: at(12)))
        #expect(!s.isActive(at: at(18)))
        #expect(!s.isActive(at: at(2)), "a same-day window must not wrap midnight")
    }

    @Test func boundariesAreInclusiveOfStartExclusiveOfEnd() {
        var s = BedsideSchedule()
        s.startHour = 22; s.endHour = 7
        #expect(s.isActive(at: at(22, 0)))
        #expect(!s.isActive(at: at(7, 0)))
    }

    @Test func disabledScheduleNeverActivates() {
        var s = BedsideSchedule()
        s.isScheduleEnabled = false
        #expect(!s.isActive(at: at(2)))
    }

    @Test func zeroLengthWindowNeverActivates() {
        var s = BedsideSchedule()
        s.startHour = 22; s.startMinute = 0
        s.endHour = 22; s.endMinute = 0
        #expect(!s.isActive(at: at(22)))
    }
}

@MainActor
struct ThemeManagerTests {

    private func manager() -> ThemeManager {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return ThemeManager(defaults: defaults)
    }

    @Test func manualOverrideBeatsSchedule() {
        let m = manager()
        m.toggleBedside()
        let first = m.isBedsideActive
        m.toggleBedside()
        #expect(m.isBedsideActive != first, "manual toggle must invert the current state")
    }

    @Test func clearingOverrideReturnsToSchedule() {
        let m = manager()
        m.toggleBedside()
        #expect(m.manualBedside != nil)
        m.clearManualOverride()
        #expect(m.manualBedside == nil)
        #expect(m.isBedsideActive == m.isWithinSchedule)
    }

    @Test func bedsidePaletteOverridesThemeChoice() {
        let m = manager()
        m.theme = .light
        if !m.isBedsideActive { m.toggleBedside() }
        let palette = m.palette(systemIsDark: false)
        #expect(palette.isDark, "Bedside Mode must stay dark even when Light is selected")
        #expect(palette.dimming > 0)
        #expect(!palette.animationsEnabled)
    }

    @Test func systemThemeFollowsAppearance() {
        let m = manager()
        m.theme = .system
        if m.isBedsideActive { m.toggleBedside() }
        #expect(m.palette(systemIsDark: true) == .trueBlack)
        #expect(m.palette(systemIsDark: false) == .light)
    }

    @Test func explicitThemeIgnoresAppearance() {
        let m = manager()
        m.theme = .softDark
        if m.isBedsideActive { m.toggleBedside() }
        #expect(m.palette(systemIsDark: false) == .softDark)
        #expect(m.palette(systemIsDark: true) == .softDark)
    }

    @Test func themeChoicePersists() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        ThemeManager(defaults: defaults).theme = .softDark
        #expect(ThemeManager(defaults: defaults).theme == .softDark)
    }
}

struct PaletteTests {

    /// Bedside Mode exists to preserve dark adaptation; a blue-heavy channel
    /// would defeat the entire point.
    @Test func bedsidePaletteAvoidsBlue() throws {
        let p = Palette.bedside(dimming: 0.45)
        for colour in [p.textPrimary, p.textSecondary, p.accent, p.rangeHigh] {
            let c = try #require(UIColor(colour).cgColor.components)
            #expect(c[0] > c[2], "blue channel should never dominate in Bedside Mode")
        }
    }

    @Test func bedsideDropsHeroWeightAndDisablesAnimation() {
        let p = Palette.bedside(dimming: 0.4)
        #expect(p.heroWeight == .medium, "Bold lights more pixels and increases night glare")
        #expect(!p.animationsEnabled)
    }

    @Test func normalPalettesDoNotDim() {
        #expect(Palette.trueBlack.dimming == 0)
        #expect(Palette.softDark.dimming == 0)
        #expect(Palette.light.dimming == 0)
    }

    @Test func trueBlackIsActuallyBlack() throws {
        let c = try #require(UIColor(Palette.trueBlack.bgPrimary).cgColor.components)
        #expect(c[0] == 0 && c[1] == 0 && c[2] == 0, "OLED pixels only switch off at pure black")
    }

    @Test func everyPaletteMapsAllBands() {
        for palette in [Palette.trueBlack, .softDark, .light, .bedside(dimming: 0.4)] {
            for band in GlycemicBand.allCases {
                _ = palette.color(for: band)
            }
            #expect(palette.color(forGlucose: 100) == palette.rangeIn)
            #expect(palette.color(forGlucose: 50) == palette.rangeUrgent)
        }
    }

    @Test func lightPaletteIsNotDark() {
        #expect(!Palette.light.isDark)
        #expect(Palette.trueBlack.isDark)
        #expect(Palette.softDark.isDark)
    }
}
