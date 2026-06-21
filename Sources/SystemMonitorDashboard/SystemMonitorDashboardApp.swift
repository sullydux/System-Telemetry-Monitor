//
//  SystemMonitorDashboardApp.swift
//  System Monitor Dashboard
//
//  SwiftUI app entry point. Owns the AppState and presents the main and
//  benchmark windows. Stops telemetry cleanly on quit.
//

import SwiftUI

extension Notification.Name {
    static let openBenchmarkSuite = Notification.Name("sullybase.openBenchmarkSuite")
}

@main
struct SystemMonitorDashboardApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Main telemetry window.
        WindowGroup("System Monitor Dashboard") {
            MainWindow()
                .environmentObject(state)
                .onAppear {
                    BenchmarkEngine.shared.bind(state)
                    state.startPolling()
                }
                .onDisappear {
                    state.stopPolling()
                }
        }
        .defaultSize(width: 900, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }  // no "New" window
            CommandGroup(after: .appSettings) {
                Button("Open Benchmark Suite") {
                    NotificationCenter.default.post(name: .openBenchmarkSuite, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
        }

        // Benchmark suite as a separate window.
        Window("AI / Stress Benchmark", id: "benchmark") {
            BenchmarkWindow()
                .environmentObject(state)
                .onReceive(NotificationCenter.default.publisher(for: .openBenchmarkSuite)) { _ in
                    // Opened by the main window button via openWindow environment.
                }
                .onDisappear {
                    if state.benchStatus.running { BenchmarkEngine.shared.cancel() }
                }
        }
        .defaultSize(width: 720, height: 640)
    }
}
