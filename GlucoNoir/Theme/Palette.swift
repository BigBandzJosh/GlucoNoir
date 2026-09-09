//
//  Palette.swift
//  GlucoNoir
//
//  Design tokens (PRD §5.1).
//
//  Every colour the app draws comes from here. Nothing hardcodes a hex value at
//  the call site, so Bedside Mode can replace the whole palette at once rather
//  than needing every view to know about it.
//

import SwiftUI

nonisolated struct Palette: Equatable, Sendable {
    let bgPrimary: Color
    let bgSecondary: Color
    let textPrimary: Color
    let textSecondary: Color
    /// Data-age text specifically. Brighter than textSecondary because it is
    /// the most safety-relevant string on the screen and was previously
    /// rendering at 13pt in the dimmest colour in the system.
    let textFreshness: Color
    let accent: Color

    let rangeIn: Color
    let rangeLow: Color
    let rangeHigh: Color
    /// Applied as a filled background with white text, never as a text colour.
    /// Urgent and low are near-identical hues, so the distinction is carried by
    /// fill-versus-text rather than by chasing a distinguishable red.
    let rangeUrgent: Color

    let isDark: Bool
    /// Bedside Mode drops the hero from Bold to Medium: fewer lit pixels, less
    /// glare at 3am. Bold remains correct for legibility in normal use.
    let heroWeight: Font.Weight
    /// Opacity of the black dimming overlay. Zero outside Bedside Mode.
    let dimming: Double
    let animationsEnabled: Bool

    func color(for band: GlycemicBand) -> Color {
        switch band {
        case .veryLow, .veryHigh: return rangeUrgent
        case .low:                return rangeLow
        case .inRange:            return rangeIn
        case .high:               return rangeHigh
        }
    }

    func color(forGlucose mgdl: Int) -> Color {
        color(for: GlycemicBand.band(for: mgdl))
    }
}

// MARK: - Concrete palettes

extension Palette {

    static let trueBlack = Palette(
        bgPrimary: .hex(0x000000),
        bgSecondary: .hex(0x0A0A0A),
        textPrimary: .hex(0xFFFFFF),
        textSecondary: .hex(0x8E8E93),
        textFreshness: .hex(0xC7C7CC),
        accent: .hex(0x0A84FF),
        rangeIn: .hex(0x30D158),
        rangeLow: .hex(0xFF453A),
        rangeHigh: .hex(0xFFD60A),
        rangeUrgent: .hex(0xFF375F),
        isDark: true,
        heroWeight: .bold,
        dimming: 0,
        animationsEnabled: true
    )

    static let softDark = Palette(
        bgPrimary: .hex(0x1C1C1E),
        bgSecondary: .hex(0x2C2C2E),
        textPrimary: .hex(0xFFFFFF),
        textSecondary: .hex(0x8E8E93),
        textFreshness: .hex(0xC7C7CC),
        accent: .hex(0x0A84FF),
        rangeIn: .hex(0x30D158),
        rangeLow: .hex(0xFF453A),
        rangeHigh: .hex(0xFFD60A),
        rangeUrgent: .hex(0xFF375F),
        isDark: true,
        heroWeight: .bold,
        dimming: 0,
        animationsEnabled: true
    )

    static let light = Palette(
        bgPrimary: .hex(0xFFFFFF),
        bgSecondary: .hex(0xF2F2F7),
        textPrimary: .hex(0x000000),
        textSecondary: .hex(0x3C3C43),
        textFreshness: .hex(0x1C1C1E),
        accent: .hex(0x007AFF),
        rangeIn: .hex(0x34C759),
        rangeLow: .hex(0xFF3B30),
        rangeHigh: .hex(0xFFCC00),
        rangeUrgent: .hex(0xFF2D55),
        isDark: false,
        heroWeight: .bold,
        dimming: 0,
        animationsEnabled: true
    )

    /// Nighttime palette. Everything shifts toward the red end of the spectrum
    /// to preserve dark adaptation — blue light is what actually costs you your
    /// night vision and your sleep, so nothing here is blue.
    static func bedside(dimming: Double) -> Palette {
        Palette(
            bgPrimary: .hex(0x000000),
            bgSecondary: .hex(0x0A0505),
            textPrimary: .hex(0xFF6B6B),
            textSecondary: .hex(0x8C4A4A),
            textFreshness: .hex(0xC98080),
            accent: .hex(0xFF9F43),
            rangeIn: .hex(0xFF6B6B),
            rangeLow: .hex(0xFF3B30),
            rangeHigh: .hex(0xFF9F43),
            rangeUrgent: .hex(0xFF2D55),
            isDark: true,
            heroWeight: .medium,
            dimming: dimming,
            animationsEnabled: false
        )
    }
}

// MARK: - Hex

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

// MARK: - Environment

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.trueBlack
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
