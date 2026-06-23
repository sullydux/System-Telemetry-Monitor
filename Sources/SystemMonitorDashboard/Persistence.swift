//
//  Persistence.swift
//  Sullybase System Telemetry Monitor
//
//  Local-only persistence. All app data lives under:
//      ~/Library/Application Support/Sullybase-Telemetry/
//  Nothing is written to or read from the network.
//

import Foundation

enum AppPaths {
    /// Root directory for everything this app writes.
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Sullybase-Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }()

    /// JSON file holding run results.
    static let resultsFile: URL       = supportDir.appendingPathComponent("stress-results.json")
    /// JSON file holding local preferences (device name, LLM settings, etc).
    static let preferencesFile: URL   = supportDir.appendingPathComponent("preferences.json")
    /// Plain-text connection log.
    static let logFile: URL           = supportDir.appendingPathComponent("connection.log")
    /// Folder for per-run text reports (also surfaced in-app).
    static let resultsFolder: URL     = supportDir.appendingPathComponent("stress-results", isDirectory: true)

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir,    withIntermediateDirectories: true)
        try? fm.createDirectory(at: resultsFolder, withIntermediateDirectories: true)
    }
}

// MARK: - Local preferences

struct LocalPreferences: Codable, Equatable {
    var deviceName: String
    var llmModelSizePreset: String        // "custom" or a preset label
    var llmCustomParamsB: Int             // when preset == custom
    var llmQuantization: String           // e.g. "Q4_K_M"
    var llmBatchSize: Int
    var llmContextLength: Int
    var llmDevice: String                 // "GPU (Metal)" / "CPU"

    static let defaults = LocalPreferences(
        deviceName: SystemFacts.shared.modelName,
        llmModelSizePreset: "7B",
        llmCustomParamsB: 7,
        llmQuantization: "Q4_K_M",
        llmBatchSize: 512,
        llmContextLength: 4096,
        llmDevice: "GPU (Metal)"
    )
}

final class PreferencesStore {
    static let shared = PreferencesStore()
    private(set) var current: LocalPreferences
    private let queue = DispatchQueue(label: "sullybase.prefs")

    private init() {
        current = PreferencesStore.load() ?? .defaults
        // Keep device name defaulted to detected model when blank.
        if current.deviceName.isEmpty {
            current.deviceName = LocalPreferences.defaults.deviceName
        }
    }

    func update(_ transform: (inout LocalPreferences) -> Void) {
        queue.sync {
            var copy = self.current
            transform(&copy)
            self.current = copy
            PreferencesStore.save(copy)
        }
    }

    private static func load() -> LocalPreferences? {
        guard let data = try? Data(contentsOf: AppPaths.preferencesFile) else { return nil }
        return try? JSONDecoder().decode(LocalPreferences.self, from: data)
    }

    private static func save(_ prefs: LocalPreferences) {
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: AppPaths.preferencesFile, options: .atomic)
        }
    }
}

// MARK: - Benchmark result records

struct BenchmarkResult: Codable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date
    var testType: String            // cpu | ram | gpu | llm | suite
    var durationSeconds: Double
    var summary: String             // human-readable block
    var metrics: [String: Double]   // machine-readable fields
    var error: String?

    init(id: UUID = UUID(),
         startedAt: Date,
         finishedAt: Date,
         testType: String,
         durationSeconds: Double,
         summary: String,
         metrics: [String: Double] = [:],
         error: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.testType = testType
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.metrics = metrics
        self.error = error
    }
}

final class ResultsStore {
    static let shared = ResultsStore()
    private let queue = DispatchQueue(label: "sullybase.results")
    private(set) var history: [BenchmarkResult]

    private init() {
        history = ResultsStore.load()
    }

    func add(_ result: BenchmarkResult) {
        queue.sync {
            history.insert(result, at: 0)
            if history.count > 200 { history.removeLast(history.count - 200) }
            ResultsStore.save(history)
            ResultsStore.writeReport(result)
        }
    }

    func clear() {
        queue.sync {
            history.removeAll()
            ResultsStore.save(history)
        }
    }

    private static func load() -> [BenchmarkResult] {
        guard let data = try? Data(contentsOf: AppPaths.resultsFile) else { return [] }
        return (try? JSONDecoder().decode([BenchmarkResult].self, from: data)) ?? []
    }

    private static func save(_ results: [BenchmarkResult]) {
        if let data = try? JSONEncoder().encode(results) {
            try? data.write(to: AppPaths.resultsFile, options: .atomic)
        }
    }

    private static func writeReport(_ result: BenchmarkResult) {
        let stamp = ISO8601DateFormatter().string(from: result.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let file = AppPaths.resultsFolder
            .appendingPathComponent("run-\(stamp)-\(result.testType).txt")
        let header = """
        Sullybase System Telemetry Monitor — benchmark report
        Test:       \(result.testType.uppercased())
        Started:    \(result.startedAt)
        Finished:   \(result.finishedAt)
        Duration:   \(String(format: "%.2f", result.durationSeconds)) s
        \(result.error.map { "Error:      \($0)\n" } ?? "")

        """
        try? (header + result.summary + "\n").write(to: file, atomically: true,
                                                     encoding: .utf8)
    }
}
