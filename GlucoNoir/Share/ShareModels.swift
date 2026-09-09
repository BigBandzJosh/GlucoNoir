//
//  ShareModels.swift
//  GlucoNoir
//
//  Types for the Dexcom Share API.
//
//  Endpoints, applicationId constants, and response quirks verified against
//  gagebenne/pydexcom, the maintained reference implementation. The API is
//  undocumented and Dexcom changes it without notice: treat every response as
//  untrusted and never crash on a parse failure.
//

import Foundation

// MARK: - Region

nonisolated enum ShareRegion: String, CaseIterable, Codable, Sendable {
    case us, ous, jp

    var displayName: String {
        switch self {
        case .us:  return "United States"
        case .ous: return "Outside US"
        case .jp:  return "Japan"
        }
    }

    var baseURL: URL {
        switch self {
        case .us:  return URL(string: "https://share2.dexcom.com/ShareWebServices/Services/")!
        case .ous: return URL(string: "https://shareous1.dexcom.com/ShareWebServices/Services/")!
        case .jp:  return URL(string: "https://share.dexcom.jp/ShareWebServices/Services/")!
        }
    }

    /// Well-known client identifier the Share endpoints require. Requests
    /// without it fail in ways that do not look like auth failures.
    var applicationID: String {
        switch self {
        case .us, .ous: return "d89443d2-327c-4a6f-89e5-496bbb0317db"
        case .jp:       return "d8665ade-9673-4e27-9ff6-92db4ce13d13"
        }
    }
}

// MARK: - Credentials

nonisolated struct ShareCredentials: Sendable, Equatable {
    var username: String
    var password: String
    var region: ShareRegion

    /// The Share API authenticates as the **account holder**, not a follower.
    /// A follower must merely exist for Dexcom to enable the Share service.
    var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }
}

// MARK: - Errors

nonisolated enum ShareError: Error, Sendable, Equatable {
    /// Credentials are wrong, or the account is locked. **Never retry these** —
    /// repeated attempts will lock the Dexcom account the official app depends on.
    case authenticationFailed(String)
    case accountLocked
    /// Session expired; refresh and retry once.
    case sessionExpired
    case network(String)
    case server(String)
    case malformedResponse(String)
    case notConfigured

    var isTerminal: Bool {
        switch self {
        case .authenticationFailed, .accountLocked, .notConfigured: return true
        case .sessionExpired, .network, .server, .malformedResponse:  return false
        }
    }

    var userMessage: String {
        switch self {
        case .authenticationFailed(let d): return "Sign-in failed: \(d)"
        case .accountLocked:               return "Too many sign-in attempts. Wait, then re-enter credentials in the Dexcom app first."
        case .sessionExpired:              return "Session expired"
        case .network(let d):              return "Network: \(d)"
        case .server(let d):               return "Dexcom: \(d)"
        case .malformedResponse(let d):    return "Unexpected response: \(d)"
        case .notConfigured:               return "Dexcom Share not set up"
        }
    }
}

// MARK: - Trend

nonisolated enum ShareTrend: Int, Sendable {
    case none = 0
    case doubleUp = 1
    case singleUp = 2
    case fortyFiveUp = 3
    case flat = 4
    case fortyFiveDown = 5
    case singleDown = 6
    case doubleDown = 7
    case notComputable = 8
    case rateOutOfRange = 9

    /// The API returned an Int historically and returns a String now.
    /// Both are accepted because older deployments still emit integers.
    init(apiValue: Any?) {
        if let i = apiValue as? Int, let t = ShareTrend(rawValue: i) { self = t; return }
        if let s = apiValue as? String {
            switch s.lowercased() {
            case "none":           self = .none
            case "doubleup":       self = .doubleUp
            case "singleup":       self = .singleUp
            case "fortyfiveup":    self = .fortyFiveUp
            case "flat":           self = .flat
            case "fortyfivedown":  self = .fortyFiveDown
            case "singledown":     self = .singleDown
            case "doubledown":     self = .doubleDown
            case "notcomputable":  self = .notComputable
            case "rateoutofrange": self = .rateOutOfRange
            default:
                // Some deployments send the integer as a string.
                if let i = Int(s), let t = ShareTrend(rawValue: i) { self = t } else { self = .none }
            }
            return
        }
        self = .none
    }

    /// Nil where no arrow should be drawn — a flat arrow is a claim about the
    /// data, not a stand-in for "unknown".
    var arrow: String? {
        switch self {
        case .doubleUp:      return "\u{21c8}"
        case .singleUp:      return "\u{2191}"
        case .fortyFiveUp:   return "\u{2197}"
        case .flat:          return "\u{2192}"
        case .fortyFiveDown: return "\u{2198}"
        case .singleDown:    return "\u{2193}"
        case .doubleDown:    return "\u{21ca}"
        case .none, .notComputable, .rateOutOfRange: return nil
        }
    }

    var describes: String {
        switch self {
        case .none:           return "no trend"
        case .doubleUp:       return "rising quickly"
        case .singleUp:       return "rising"
        case .fortyFiveUp:    return "rising slightly"
        case .flat:           return "steady"
        case .fortyFiveDown:  return "falling slightly"
        case .singleDown:     return "falling"
        case .doubleDown:     return "falling quickly"
        case .notComputable:  return "trend not computable"
        case .rateOutOfRange: return "rate out of range"
        }
    }
}

// MARK: - Units

/// Values are stored canonically as integer mg/dL and converted only for
/// display, so switching units is lossless.
nonisolated enum GlucoseUnit: String, CaseIterable, Codable, Sendable {
    case mgdl
    case mmolL

    /// Dexcom's own conversion divisor. The more precise molar mass (18.01559)
    /// disagrees at boundary values — 100 mg/dL renders as 5.6 rather than the
    /// 5.5 the official app shows — so match Dexcom rather than chemistry.
    static let mmolDivisor = 18.0182

    var label: String {
        switch self {
        case .mgdl:  return "mg/dL"
        case .mmolL: return "mmol/L"
        }
    }

    /// Sensible default for the user's region; overridable in the app.
    static var deviceDefault: GlucoseUnit {
        Locale.current.region?.identifier == "US" ? .mgdl : .mmolL
    }

    func format(_ mgdl: Int) -> String {
        switch self {
        case .mgdl:  return String(mgdl)
        case .mmolL: return String(format: "%.1f", Double(mgdl) / Self.mmolDivisor)
        }
    }

    /// Threshold rendering, e.g. for target-range labels.
    func format(range low: Int, high: Int) -> String {
        "\(format(low))–\(format(high)) \(label)"
    }
}

// MARK: - Reading

nonisolated struct ShareGlucoseReading: Sendable, Equatable, Identifiable {
    /// Sensor sample time. Canonical key for deduplication and persistence.
    let sampleTime: Date
    /// mg/dL, stored canonically. Conversion happens at display time only.
    let valueMgdl: Int
    let trend: ShareTrend

    var id: Date { sampleTime }

    /// G7 reports only 40–400; values at the rails are sentinels, not measurements.
    var isBelowRange: Bool { valueMgdl < 40 }
    var isAboveRange: Bool { valueMgdl > 400 }

    var mmolL: Double { (Double(valueMgdl) / GlucoseUnit.mmolDivisor).rounded(toPlaces: 1) }

    var age: TimeInterval { Date().timeIntervalSince(sampleTime) }

    /// Rail sentinels render as words; a number here would present an unknown
    /// value as a measured one.
    func displayValue(in unit: GlucoseUnit) -> String {
        if isBelowRange { return "LOW" }
        if isAboveRange { return "HIGH" }
        return unit.format(valueMgdl)
    }

    /// Dexcom returns Microsoft JSON dates: `/Date(1747051200000+0000)/`.
    /// ISO8601 parsing fails silently on these, which is a classic source of
    /// readings that are hours off.
    static func parseMicrosoftDate(_ raw: String) -> Date? {
        guard let match = raw.firstMatch(of: /Date\((?<ms>-?\d+)(?<tz>[+-]\d{4})?\)/) else { return nil }
        guard let ms = Double(match.output.ms) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    init?(json: [String: Any]) {
        guard let value = json["Value"] as? Int else { return nil }
        // WT is wall time; prefer it, fall back to ST then DT.
        let raw = (json["WT"] as? String) ?? (json["ST"] as? String) ?? (json["DT"] as? String)
        guard let raw, let date = Self.parseMicrosoftDate(raw) else { return nil }

        self.sampleTime = date
        self.valueMgdl = value
        self.trend = ShareTrend(apiValue: json["Trend"])
    }

    init(sampleTime: Date, valueMgdl: Int, trend: ShareTrend) {
        self.sampleTime = sampleTime
        self.valueMgdl = valueMgdl
        self.trend = trend
    }
}

nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let d = pow(10.0, Double(places))
        return (self * d).rounded() / d
    }
}
