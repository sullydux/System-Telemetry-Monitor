//
//  AppState.swift
//  System Monitor Dashboard
//
//  Central in-memory state shared by the main and benchmark windows.
//  All telemetry, logs, preferences, and benchmark state live here.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Log entries

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERR" }

    var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "[\(f.string(from: timestamp))] \(level.rawValue)  \(message)"
    }
}

// MARK: - Root state

final class AppState: ObservableObject {
    // Telemetry
    @Published var snapshot: TelemetrySnapshot?

    // Local config
    @Published var deviceName: String
    @Published var running: Bool = false        // polling active

    // Benchmark status
    @Published var benchStatus = BenchmarkStatus()
    @Published var history: [BenchmarkResult]

    // Log
    @Published var logEntries: [LogEntry] = []

    private let poller = TelemetryPoller.shared
    private let prefs = PreferencesStore.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        AppPaths.ensureDirectories()
        let p = PreferencesStore.shared.current
        self.deviceName = p.deviceName
        self.history = ResultsStore.shared.history

        // Hydrate log from disk for continuity.
        if let text = try? String(contentsOf: AppPaths.logFile, encoding: .utf8) {
            let lines = text.split(separator: "\n").suffix(400).map(String.init)
            for line in lines {
                logEntries.append(LogEntry(timestamp: Date(), level: .info, message: line))
            }
        }
        log("Application started — local-only telemetry", .info)
        log("Model: \(SystemFacts.shared.modelName)  Chip: \(SystemFacts.shared.chipName)", .info)
        log("RAM: \(String(format: "%.1f", Double(SystemFacts.shared.physicalRAMBytes)/1_073_741_824.0)) GB  Cores: \(SystemFacts.shared.physicalCores)P/\(SystemFacts.shared.logicalCores)L", .info)
    }

    // MARK: Polling control

    func startPolling() {
        guard !running else { return }
        running = true
        log("Telemetry polling started (1 Hz)", .info)
        poller.start { [weak self] snap in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.snapshot = snap
            }
        }
    }

    func stopPolling() {
        guard running else { return }
        running = false
        poller.stop()
        log("Telemetry polling stopped", .info)
    }

    // MARK: Logging

    func log(_ message: String, _ level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logEntries.append(entry)
            if self.logEntries.count > 1000 { self.logEntries.removeFirst(self.logEntries.count - 1000) }
            self.persistLog(entry)
        }
    }

    private func persistLog(_ entry: LogEntry) {
        let line = entry.formatted + "\n"
        DispatchQueue.global(qos: .utility).async {
            if let handle = try? FileHandle(forWritingTo: AppPaths.logFile) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            } else {
                try? line.write(to: AppPaths.logFile, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Device name

    func saveDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? SystemFacts.shared.modelName : trimmed
        deviceName = final
        prefs.update { $0.deviceName = final }
        log("Device name saved: \(final)", .info)
    }

    // MARK: Benchmark status passthrough

    func updateBenchmark(_ transform: (inout BenchmarkStatus) -> Void) {
        var copy = benchStatus
        transform(&copy)
        benchStatus = copy
    }

    func pushResult(_ result: BenchmarkResult) {
        ResultsStore.shared.add(result)
        DispatchQueue.main.async {
            self.history.insert(result, at: 0)
            if self.history.count > 200 { self.history.removeLast(self.history.count - 200) }
        }
    }
}

// MARK: - Benchmark status

struct BenchmarkStatus: Equatable {
    var running: Bool = false
    var testType: BenchmarkTestType = .cpu
    var durationSeconds: Double = 30
    var elapsedSeconds: Double = 0
    var progress: Double = 0
    var phase: String = "Idle"
    var liveMetricsText: String = ""
    var error: String? = nil
    var lastResultText: String = ""

    // Parameters
    var cpuWorkers: Int = ProcessInfo.processInfo.processorCount
    var cpuMatrixSize: Int = 1024
    var ramPercent: Int = 75
    var gpuMatrixSize: Int = 2048
    var llmPreset: String = "7B"
    var llmCustomParamsB: Int = 7
    var llmQuantization: String = "Q4_K_M"
    var llmBatchSize: Int = 512
    var llmContextLength: Int = 4096
    var llmDevice: String = "GPU (Metal)"

    var statusLabel: String {
        if running { return "Running" }
        if error != nil { return "Error" }
        return "Idle"
    }
}

enum BenchmarkTestType: String, CaseIterable, Identifiable {
    case cpu, ram, gpu, llm, suite
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cpu:   return "CPU"
        case .ram:   return "RAM"
        case .gpu:   return "GPU"
        case .llm:   return "LLM Stats"
        case .suite: return "Full Suite"
        }
    }
}
