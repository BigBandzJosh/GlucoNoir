//
//  GlucoNoirApp.swift
//  GlucoNoir
//

import SwiftUI
import SwiftData

@main
struct GlucoNoirApp: App {
    @State private var monitor: ShareMonitor
    @State private var storeError: String?

    init() {
        // A failed store must not take the app down: showing a live reading
        // without history is far better than showing nothing at all.
        do {
            let container = try GlucoseStoreFactory.makeContainer()
            let store = GlucoseStore(modelContainer: container)
            _monitor = State(initialValue: ShareMonitor(store: store))
        } catch {
            _monitor = State(initialValue: ShareMonitor())
            _storeError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, storeError: storeError)
        }
    }
}
