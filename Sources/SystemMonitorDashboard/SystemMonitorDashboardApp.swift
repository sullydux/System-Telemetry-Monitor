//
//  SystemMonitorDashboardApp.swift
//  Sullybase System Telemetry Monitor
//
//  SwiftUI app entry point. Owns the AppState and presents the main and
//  benchmark windows. Stops telemetry cleanly on quit.
//

import SwiftUI
import AppKit

extension Notification.Name {
    static let openBenchmarkSuite = Notification.Name("sullybase.openBenchmarkSuite")
}

@main
struct SystemMonitorDashboardApp: App {
    @StateObject private var state = AppState()
    @State private var statusBar: StatusBarController? = nil

    var body: some Scene {
        // Main telemetry window.
        WindowGroup("Sullybase System Telemetry Monitor") {
            MainWindow()
                .environmentObject(state)
                .onAppear {
                    BenchmarkEngine.shared.bind(state)
                    state.startPolling()
                    if statusBar == nil { statusBar = StatusBarController() }
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

        // Remote share link window
        Window("Remote View Link", id: "remote-share") {
            RemoteShareWindow()
                .environmentObject(state)
        }
        .defaultSize(width: 520, height: 220)
    }
}
