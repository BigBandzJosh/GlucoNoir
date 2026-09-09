//
//  SettingsView.swift
//  GlucoNoir
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var monitor: ShareMonitor
    @ObservedObject var theme: ThemeManager
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var confirmSignOut = false
    @State private var showRestorePicker = false
    @State private var confirmRestore: URL?
    @State private var shareItem: ShareItem?

    /// Wrapper so the share sheet can be presented by item.
    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Form {
                appearance
                bedside
                display
                health
                dataSection
                account
                disclaimer
            }
            .scrollContentBackground(.hidden)
            .background(palette.bgPrimary)
            // Presentation modifiers belong on the Form, not on a Section.
            // Form restructures its sections during layout, which can tear down
            // an active presentation mid-flight — the share sheet opened and
            // then immediately closed itself.
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .fileImporter(isPresented: $showRestorePicker,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    confirmRestore = url
                }
            }
            .confirmationDialog("Restore this backup?",
                                isPresented: restorePrompt,
                                titleVisibility: .visible) {
                Button("Merge into history") {
                    if let url = confirmRestore {
                        Task { await monitor.restore(from: url) }
                    }
                    confirmRestore = nil
                }
                Button("Cancel", role: .cancel) { confirmRestore = nil }
            } message: {
                Text("Readings are merged, never replaced. Nothing already stored is deleted.")
            }
            .onChange(of: monitor.exportState) { _, state in
                // Exports land in a temporary directory the Files app cannot
                // see, so the share sheet is presented on completion rather
                // than left as a step the user has to discover.
                if case .ready(let result) = state {
                    shareItem = ShareItem(url: result.url)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(palette.accent)
                }
            }
        }
        .tint(palette.accent)
    }

    private var appearance: some View {
        Section {
            Picker("Theme", selection: $theme.theme) {
                ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("True Black turns OLED pixels off entirely, which is easiest on the eyes at night and uses least power.")
        }
        .listRowBackground(palette.bgSecondary)
    }

    private var bedside: some View {
        Section {
            Toggle("Follow schedule", isOn: $theme.schedule.isScheduleEnabled)

            if theme.schedule.isScheduleEnabled {
                Stepper("Start \(String(format: "%02d:00", theme.schedule.startHour))",
                        value: $theme.schedule.startHour, in: 0...23)
                Stepper("End \(String(format: "%02d:00", theme.schedule.endHour))",
                        value: $theme.schedule.endHour, in: 0...23)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dimming")
                    Spacer()
                    Text("\(Int(theme.dimming * 100))%")
                        .foregroundStyle(palette.textSecondary)
                        .font(.system(.body, design: .monospaced))
                }
                Slider(value: $theme.dimming, in: 0...0.8)
            }

            HStack {
                Text(theme.isBedsideActive ? "Bedside Mode is on" : "Bedside Mode is off")
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button(theme.isBedsideActive ? "Turn off" : "Turn on") {
                    theme.toggleBedside()
                }
                .foregroundStyle(palette.accent)
            }

            if theme.manualBedside != nil {
                Button("Return to schedule") { theme.clearManualOverride() }
                    .foregroundStyle(palette.accent)
            }
        } header: {
            Text("Bedside Mode")
        } footer: {
            Text("Dims the screen and shifts colours toward red to preserve dark adaptation. Dimming is applied inside the app only — your device brightness is never changed.")
        }
        .listRowBackground(palette.bgSecondary)
    }

    private var display: some View {
        Section {
            Picker("Units", selection: $monitor.unit) {
                Text("mmol/L").tag(GlucoseUnit.mmolL)
                Text("mg/dL").tag(GlucoseUnit.mgdl)
            }
            .pickerStyle(.segmented)

            LabeledContent("Target range", value: GlucoseUnit.mmolL == monitor.unit
                ? monitor.unit.format(range: TargetRange.lowMgdl, high: TargetRange.highMgdl)
                : monitor.unit.format(range: TargetRange.lowMgdl, high: TargetRange.highMgdl))

            LabeledContent("Stored readings", value: "\(monitor.storedCount)")
        } header: {
            Text("Display")
        }
        .listRowBackground(palette.bgSecondary)
    }

    private var dataSection: some View {
        Section {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    Task { await monitor.export(format) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export as \(format.label)")
                        Text(format.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .foregroundStyle(palette.accent)
                .disabled(isExporting)
            }

            Button("Restore from backup") { showRestorePicker = true }
                .foregroundStyle(palette.accent)
                .disabled(isExporting)

            switch monitor.exportState {
            case .working:
                HStack { ProgressView(); Text("Working…").foregroundStyle(palette.textSecondary) }
            case .ready(let result):
                // Kept as a way to re-share without re-exporting; the sheet is
                // presented automatically on completion so the file is never
                // stranded in the temporary directory.
                Button {
                    shareItem = ShareItem(url: result.url)
                } label: {
                    Label("Share again · \(result.readingCount) readings · \(result.sizeDescription)",
                          systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(palette.accent)
            case .restored(let inserted, let total):
                Text(inserted > 0
                     ? "Restored \(inserted) new readings — \(total) total"
                     : "Backup contained nothing new — \(total) total")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.rangeIn)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.rangeLow)
            case .idle:
                EmptyView()
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Your \(monitor.storedCount) stored readings exist only on this device. Dexcom keeps 24 hours and Apple Health 90 days, so anything older lives here alone — export regularly.")
        }
        .listRowBackground(palette.bgSecondary)
    }

    /// Two-way binding for the restore prompt.
    private var restorePrompt: Binding<Bool> {
        Binding(
            get: { confirmRestore != nil },
            set: { if !$0 { confirmRestore = nil } }
        )
    }

    private var isExporting: Bool {
        if case .working = monitor.exportState { return true }
        return false
    }

    private var health: some View {
        Section {
            Button {
                Task { await monitor.importFromHealth() }
            } label: {
                HStack {
                    Text("Import history from Health")
                    Spacer()
                    if case .running = monitor.backfillStatus { ProgressView() }
                }
            }
            .foregroundStyle(palette.accent)
            .disabled(isImporting)

            switch monitor.backfillStatus {
            case .done(let inserted, let at):
                LabeledContent("Last import",
                               value: inserted > 0
                                   ? "\(inserted) added, \(at.formatted(date: .abbreviated, time: .shortened))"
                                   : "nothing new")
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.rangeLow)
            case .unavailable:
                Text("Health data isn't available on this device.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            case .idle, .running:
                EmptyView()
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Imports up to 90 days of past readings. Dexcom writes to Health on a three-hour delay, so this is used for history only — never for your current reading.")
        }
        .listRowBackground(palette.bgSecondary)
    }

    private var isImporting: Bool {
        if case .running = monitor.backfillStatus { return true }
        return false
    }

    private var account: some View {
        Section {
            if let credentials = monitor.credentials {
                LabeledContent("Account", value: credentials.username)
                LabeledContent("Region", value: credentials.region.displayName)
            }
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Dexcom Share")
        }
        .listRowBackground(palette.bgSecondary)
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out, keep history", role: .destructive) {
                monitor.signOut(deleteHistory: false)
                dismiss()
            }
            Button("Sign out and delete \(monitor.storedCount) readings", role: .destructive) {
                monitor.signOut(deleteHistory: true)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your stored history can be kept for when you sign back in.")
        }
    }

    private var disclaimer: some View {
        Section {
            Text("GlucoNoir is not a medical device and does not provide alarms. Keep the official Dexcom G7 app installed and rely on it for low and high glucose alerts — it reads the sensor directly and does not depend on a network connection.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
        }
        .listRowBackground(palette.bgSecondary)
    }
}


// MARK: - Share sheet

/// SwiftUI's ShareLink cannot be triggered programmatically, so exports use
/// UIActivityViewController directly to present on completion.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
