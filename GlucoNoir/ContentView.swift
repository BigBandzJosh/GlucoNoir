//
//  ContentView.swift
//  GlucoNoir
//

import SwiftUI
import Combine

struct ContentView: View {
    @ObservedObject var monitor: ShareMonitor
    @StateObject private var theme = ThemeManager()
    var storeError: String?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme

    private var palette: Palette {
        theme.palette(systemIsDark: systemColorScheme == .dark)
    }

    var body: some View {
        ZStack {
            palette.bgPrimary.ignoresSafeArea()

            Group {
                if monitor.credentials?.isComplete == true {
                    ReadingView(monitor: monitor, theme: theme, storeError: storeError)
                } else {
                    SignInView(monitor: monitor)
                }
            }

            // Bedside dimming.
            //
            // A black overlay rather than UIScreen.brightness: an app cannot set
            // brightness for its own window, only for the entire device, and that
            // change persists after the app quits — a crash would leave the phone
            // stuck dim. This dims content only and cannot outlive the view.
            if palette.dimming > 0 {
                Color.black
                    .opacity(palette.dimming)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .environment(\.palette, palette)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .animation(palette.animationsEnabled ? .default : nil, value: palette)
        .onChange(of: scenePhase) { _, phase in
            // Opening the app must always show current data, never a cached value.
            if phase == .active { monitor.refreshNow() }
        }
    }
}

// MARK: - Sign in

private struct SignInView: View {
    @ObservedObject var monitor: ShareMonitor
    @Environment(\.palette) private var palette

    @State private var username = ""
    @State private var password = ""
    @State private var region: ShareRegion = .us
    @State private var isVerifying = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dexcom Share")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)

                Text("Sign in with your own Dexcom account, not a follower's. Share must be enabled, which requires at least one follower to exist in the Dexcom app.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)

                VStack(spacing: 12) {
                    field("Username", text: $username, secure: false)
                    field("Password", text: $password, secure: true)
                    Picker("Region", selection: $region) {
                        ForEach(ShareRegion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.rangeLow)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await verify() }
                } label: {
                    HStack {
                        if isVerifying { ProgressView().tint(palette.bgPrimary) }
                        Text(isVerifying ? "Checking…" : "Connect")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSubmit ? palette.textPrimary : palette.textPrimary.opacity(0.25))
                    .foregroundStyle(palette.bgPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canSubmit || isVerifying)

                Text("Credentials are stored in the iOS Keychain on this device only. They are never sent anywhere except Dexcom.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary.opacity(0.7))
            }
            .padding(24)
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func field(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(palette.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(palette.textPrimary)
        }
    }

    private func verify() async {
        isVerifying = true
        error = nil
        let result = await monitor.save(
            ShareCredentials(username: username.trimmingCharacters(in: .whitespaces),
                             password: password, region: region)
        )
        if case .failure(let e) = result { error = e.userMessage }
        isVerifying = false
    }
}

// MARK: - Reading

private struct ReadingView: View {
    @ObservedObject var monitor: ShareMonitor
    @ObservedObject var theme: ThemeManager
    var storeError: String?

    @Environment(\.palette) private var palette
    @State private var now = Date()
    @State private var showSettings = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            chartSection
            Divider().overlay(palette.textSecondary.opacity(0.15))
            logList
        }
        .onReceive(tick) { now = $0 }
        .sheet(isPresented: $showSettings) {
            SettingsView(monitor: monitor, theme: theme)
                .environment(\.palette, palette)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Spacer()

                if theme.isBedsideActive {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.accent)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(valueText)
                    .font(.system(size: 84, weight: palette.heroWeight, design: .rounded))
                    .foregroundStyle(valueColor)
                    .contentTransition(.numericText())
                    // Deliberate gesture, not a tap: reading the screen and
                    // dismissing the mode must not be the same action, or a
                    // stray wake-tap dumps you into a bright screen at 3am.
                    .onLongPressGesture(minimumDuration: 0.5) { theme.toggleBedside() }
                if let arrow = monitor.latest?.trend.arrow {
                    Text(arrow)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(valueColor.opacity(0.9))
                }
                Spacer()
                Button {
                    monitor.unit = monitor.unit == .mmolL ? .mgdl : .mmolL
                } label: {
                    Text(monitor.unit.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.bgSecondary)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {
                Text(ageText)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(freshnessColor)
                if let t = monitor.latest?.trend {
                    Text("· \(t.describes)")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
                Text("\(monitor.storedCount) stored")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textSecondary.opacity(0.7))
            }

            if let storeError {
                Text("History unavailable: \(storeError)")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.rangeHigh)
            }

            if monitor.freshness == .critical {
                Text("Data is stale. Open the Dexcom G7 app for current readings.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.rangeHigh)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartSection: some View {
        VStack(spacing: 10) {
            Picker("Window", selection: $monitor.chartWindow) {
                ForEach(ChartWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            if monitor.windowReadings.isEmpty {
                VStack(spacing: 6) {
                    Text("No readings yet")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                    Text("History builds as readings arrive.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary.opacity(0.7))
                }
                .frame(height: 200)
            } else {
                GlucoseChartView(
                    readings: monitor.windowReadings,
                    unit: monitor.unit,
                    window: monitor.chartWindow,
                    palette: palette
                )
                .frame(height: 200)
                .padding(.horizontal, 12)

                StatisticsView(
                    stats: monitor.statistics,
                    unit: monitor.unit,
                    window: monitor.chartWindow
                )
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 12)
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(SpikeLog.shared.entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.textSecondary.opacity(0.6))
                        Text(entry.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: entry.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func color(for kind: SpikeLog.Entry.Kind) -> Color {
        switch kind {
        case .reading:    return palette.rangeIn
        case .connection: return palette.accent
        case .error:      return palette.rangeLow
        case .info:       return palette.textSecondary
        }
    }

    private var valueText: String {
        monitor.latest?.displayValue(in: monitor.unit) ?? "—"
    }

    private var valueColor: Color {
        guard let r = monitor.latest else { return palette.textPrimary }
        if monitor.freshness == .critical { return palette.textSecondary }
        return palette.color(forGlucose: r.valueMgdl)
    }

    private var ageText: String {
        _ = now
        return monitor.ageDescription
    }

    private var freshnessColor: Color {
        switch monitor.freshness {
        case .fresh:    return palette.textFreshness
        case .stale:    return palette.rangeHigh
        case .critical: return palette.rangeLow
        case .none:     return palette.textSecondary
        }
    }

    private var statusColor: Color {
        switch monitor.status {
        case .ok:             return palette.rangeIn
        case .polling, .idle: return palette.rangeHigh
        default:              return palette.rangeLow
        }
    }

    private var statusText: String {
        switch monitor.status {
        case .notConfigured: return "Not set up"
        case .idle:          return "Waiting"
        case .polling:       return "Updating…"
        case .ok:            return "Connected"
        case .failed(let m): return m
        case .locked(let m): return m
        }
    }
}

#Preview { ContentView(monitor: ShareMonitor()) }
