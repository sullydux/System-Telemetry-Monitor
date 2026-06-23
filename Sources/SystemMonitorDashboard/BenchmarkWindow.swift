//
//  BenchmarkWindow.swift
//  Sullybase System Telemetry Monitor
//
//  Secondary window: test type, duration, per-test parameters, controls,
//  progress, and last result.
//

import SwiftUI

struct BenchmarkWindow: View {
    @EnvironmentObject var state: AppState

    private var status: BenchmarkStatus { state.benchStatus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                TestTypePanel()
                DurationPanel()
                ParametersPanel()
                ControlsRow()
                ProgressPanel()
                LastResultPanel()
            }
            .padding(14)
        }
        .background(Theme.background.ignoresSafeArea())
        .frame(minWidth: 620, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI / STRESS BENCHMARK")
                .font(Theme.mono(15).bold())
                .tracking(2)
                .foregroundColor(Theme.primaryText)
            Text("Compute backend: \(computeLabel)")
                .font(Theme.mono(9))
                .foregroundColor(computeAvailable ? Theme.accent : Theme.warning)
        }
    }

    private var computeLabel: String { ComputeBackend.detect().label }
    private var computeAvailable: Bool { ComputeBackend.detect().available }
}

// MARK: - Test type

private struct TestTypePanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Panel(title: "TEST TYPE") {
            HStack(spacing: 6) {
                ForEach(BenchmarkTestType.allCases) { t in
                    let selected = state.benchStatus.testType == t
                    Button(action: { select(t) }) {
                        Text(t.displayName)
                            .font(Theme.mono(9).bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundColor(selected ? Theme.background : Theme.mutedText)
                            .background(selected ? Theme.accent : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(selected ? Theme.accent : Theme.panelBorder, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.benchStatus.running)
                    .opacity(state.benchStatus.running ? 0.5 : 1)
                }
            }
        }
    }

    private func select(_ t: BenchmarkTestType) {
        state.updateBenchmark { $0.testType = t }
        state.log("Selected benchmark: \(t.displayName)", .info)
    }
}

// MARK: - Duration

private struct DurationPanel: View {
    @EnvironmentObject var state: AppState
    private let presets = ["10 sec", "30 sec", "1 min", "2 min", "5 min", "10 min", "Custom"]

    var body: some View {
        Panel(title: "DURATION") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: {
                    durationLabel
                }, set: { newLabel in
                    applyLabel(newLabel)
                })) {
                    ForEach(presets, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(state.benchStatus.running)

                if isCustom {
                    Text("seconds:")
                        .font(Theme.mono(9))
                        .foregroundColor(Theme.mutedText)
                    TextField("30", value: Binding(
                        get: { Int(state.benchStatus.durationSeconds) },
                        set: { v in state.updateBenchmark { $0.durationSeconds = Double(max(1, v)) } }
                    ), formatter: NumberFormatter())
                    .textFieldStyle(.plain)
                    .font(Theme.mono(10))
                    .frame(width: 56)
                    .padding(5)
                    .background(Color(hex: 0x0d121b))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
            }
            .font(Theme.mono(9))
        }
    }

    private var durationLabel: String {
        let secs = Int(state.benchStatus.durationSeconds.rounded())
        switch secs {
        case 10: return "10 sec"
        case 30: return "30 sec"
        case 60: return "1 min"
        case 120: return "2 min"
        case 300: return "5 min"
        case 600: return "10 min"
        default: return "Custom"
        }
    }
    private var isCustom: Bool { durationLabel == "Custom" }

    private func applyLabel(_ label: String) {
        let secs: Double
        switch label {
        case "10 sec":  secs = 10
        case "30 sec":  secs = 30
        case "1 min":   secs = 60
        case "2 min":   secs = 120
        case "5 min":   secs = 300
        case "10 min":  secs = 600
        default:        secs = state.benchStatus.durationSeconds
        }
        state.updateBenchmark { $0.durationSeconds = secs }
    }
}

// MARK: - Parameters

private struct ParametersPanel: View {
    @EnvironmentObject var state: AppState
    private var s: BenchmarkStatus { state.benchStatus }

    var body: some View {
        Panel(title: "PARAMETERS") {
            switch s.testType {
            case .cpu:   cpuParams
            case .ram:   ramParams
            case .gpu:   gpuParams
            case .llm:   llmParams
            case .suite:
                Text("Full Suite runs CPU, RAM, GPU, and LLM Stats back to back. Per-test parameters are reused from their panels.")
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cpuParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepperRow("Worker threads", value: Binding(
                get: { s.cpuWorkers },
                set: { v in state.updateBenchmark { $0.cpuWorkers = max(1, v) } }
            ), range: 1...64)
            stepperRow("Matrix size", value: Binding(
                get: { s.cpuMatrixSize },
                set: { v in state.updateBenchmark { $0.cpuMatrixSize = max(64, v) } }
            ), range: 64...4096, step: 64)
        }
    }

    private var ramParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepperRow("RAM to allocate (%)", value: Binding(
                get: { s.ramPercent },
                set: { v in state.updateBenchmark { $0.ramPercent = max(10, min(95, v)) } }
            ), range: 10...95, step: 5)
            Text("Will target roughly \(Format.gb(ramTargetGB)).")
                .font(Theme.mono(8))
                .foregroundColor(Theme.mutedText)
        }
    }

    private var ramTargetGB: Double {
        Double(SystemFacts.shared.physicalRAMBytes) * Double(s.ramPercent) / 100.0 / 1_073_741_824.0
    }

    private var gpuParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepperRow("Matrix size", value: Binding(
                get: { s.gpuMatrixSize },
                set: { v in state.updateBenchmark { $0.gpuMatrixSize = max(128, v) } }
            ), range: 128...8192, step: 128)
            if !ComputeBackend.detect().available {
                Text("No Metal GPU backend detected — GPU test will report unavailable.")
                    .font(Theme.mono(8))
                    .foregroundColor(Theme.warning)
            }
        }
    }

    private var llmParams: some View {
        let presets = ["1.5B", "3B", "7B", "13B", "30B", "70B", "custom"]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model size")
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.mutedText)
                Picker("", selection: Binding(
                    get: { s.llmPreset },
                    set: { v in state.updateBenchmark { $0.llmPreset = v } }
                )) {
                    ForEach(presets, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
                .frame(width: 120)
                if s.llmPreset == "custom" {
                    TextField("params (B)", value: Binding(
                        get: { s.llmCustomParamsB },
                        set: { v in state.updateBenchmark { $0.llmCustomParamsB = max(1, v) } }
                    ), formatter: NumberFormatter())
                    .textFieldStyle(.plain)
                    .font(Theme.mono(10))
                    .frame(width: 80)
                    .padding(5)
                    .background(Color(hex: 0x0d121b))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
            }
            pickerRow("Quantization", value: Binding(
                get: { s.llmQuantization },
                set: { v in state.updateBenchmark { $0.llmQuantization = v } }
            ), options: ["F16", "Q8_0", "Q6_K", "Q5_K_M", "Q4_K_M", "Q4_0", "Q3_K_M", "Q2_K"])
            stepperRow("Batch size", value: Binding(
                get: { s.llmBatchSize },
                set: { v in state.updateBenchmark { $0.llmBatchSize = max(1, v) } }
            ), range: 1...8192, step: 64)
            stepperRow("Context length", value: Binding(
                get: { s.llmContextLength },
                set: { v in state.updateBenchmark { $0.llmContextLength = max(128, v) } }
            ), range: 128...131072, step: 512)
            pickerRow("Device", value: Binding(
                get: { s.llmDevice },
                set: { v in state.updateBenchmark { $0.llmDevice = v } }
            ), options: ["GPU (Metal)", "CPU"])
        }
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack {
            Text(label).font(Theme.mono(9)).foregroundColor(Theme.mutedText)
            Spacer()
            HStack(spacing: 4) {
                Button("−") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) }
                    .buttonStyle(.plain).foregroundColor(Theme.accent)
                    .font(Theme.mono(11).bold()).frame(width: 18)
                Text("\(value.wrappedValue)")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.primaryText)
                    .frame(minWidth: 50)
                Button("+") { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) }
                    .buttonStyle(.plain).foregroundColor(Theme.accent)
                    .font(Theme.mono(11).bold()).frame(width: 18)
            }
        }
    }

    private func pickerRow(_ label: String, value: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label).font(Theme.mono(9)).foregroundColor(Theme.mutedText)
            Spacer()
            Picker("", selection: value) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
            .frame(width: 140)
        }
    }
}

// MARK: - Controls row

private struct ControlsRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Button(action: start) {
                if state.benchStatus.running { Text("Running…") } else { Text("Start Test") }
            }
            .buttonStyle(FlatButton())
            .disabled(state.benchStatus.running)

            Button("Cancel") { BenchmarkEngine.shared.cancel() }
                .buttonStyle(FlatButton(tint: Theme.warning))
                .disabled(!state.benchStatus.running)

            Button("Open Results Folder") { openResults() }
                .buttonStyle(FlatButton(tint: Theme.mutedText))

            Spacer()
        }
    }

    private func start() {
        let s = state.benchStatus
        BenchmarkEngine.shared.start(test: s.testType,
                                     duration: s.durationSeconds,
                                     params: s)
    }

    private func openResults() {
        NSWorkspace.shared.open(AppPaths.resultsFolder)
    }
}

// MARK: - Progress

private struct ProgressPanel: View {
    @EnvironmentObject var state: AppState
    private var s: BenchmarkStatus { state.benchStatus }

    var body: some View {
        Panel(title: "PROGRESS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Status")
                        .font(Theme.mono(9))
                        .foregroundColor(Theme.mutedText)
                    Text(s.statusLabel)
                        .font(Theme.mono(9).bold())
                        .foregroundColor(statusColor)
                    Spacer()
                    Text("\(s.testType.displayName) • \(s.phase)")
                        .font(Theme.mono(9))
                        .foregroundColor(Theme.mutedText)
                }
                TelemetryBar(value: s.progress,
                             forcedTint: s.error != nil ? Theme.danger : Theme.accent)
                Text(String(format: "%.0f%%  •  %.1fs / %.0fs",
                            s.progress * 100, s.elapsedSeconds, s.durationSeconds))
                    .font(Theme.mono(8))
                    .foregroundColor(Theme.mutedText)

                Text(s.liveMetricsText.isEmpty ? "(no live metrics yet)" : s.liveMetricsText)
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.primaryText.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(hex: 0x0a0e14))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
            }
        }
        .onAppear { startElapsedTicker() }
    }

    private var statusColor: Color {
        if s.running { return Theme.accent }
        if s.error != nil { return Theme.danger }
        return Theme.mutedText
    }

    @State private var ticker: Timer?

    private func startElapsedTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard state.benchStatus.running else { return }
            // Recompute elapsed from progress to keep it in sync.
            state.updateBenchmark {
                $0.elapsedSeconds = $0.progress * $0.durationSeconds
            }
        }
    }
}

// MARK: - Last result

private struct LastResultPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Panel(title: "LAST RESULT") {
            ScrollView {
                Text(state.benchStatus.lastResultText.isEmpty
                     ? "(no completed run yet)"
                     : state.benchStatus.lastResultText)
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.primaryText.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 220)
        }
    }
}
