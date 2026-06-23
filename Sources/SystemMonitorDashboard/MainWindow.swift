//
//  MainWindow.swift
//  Sullybase System Telemetry Monitor
//
//  Primary window: header, VITALS, DEVICE NAME, LIVE LOCAL PREVIEW,
//  AI STRESS BENCHMARK, CONNECTION LOG, and footer.
//

import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                VitalsPanel()
                HStack(alignment: .top, spacing: 12) {
                    DeviceNamePanel()
                }
                BenchmarkPanel()
                LogPanel()
                footer
            }
            .padding(14)
        }
        .background(Theme.background.ignoresSafeArea())
        .frame(minWidth: 760, minHeight: 560)
        .navigationSubtitle("Local only • Apple Silicon")
        .background(WindowAccessor())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SYSTEM MONITOR DASHBOARD")
                    .font(Theme.mono(Theme.FontSize.huge).bold())
                    .tracking(2)
                    .foregroundColor(Theme.primaryText)
                Text("on-host telemetry • no network")
                    .font(Theme.mono(Theme.FontSize.body))
                    .foregroundColor(Theme.mutedText)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: { openWindow(id: "remote-share") }) { Image(systemName: "network") }
                    .buttonStyle(PlainButtonStyle())
                    .help("Share view")
                HStack(spacing: 6) {
                    StatusDot(running: state.running)
                    Text(state.running ? "Running" : "Stopped")
                        .font(Theme.mono(Theme.FontSize.body).bold())
                        .foregroundColor(state.running ? Theme.accent : Theme.mutedText)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Read-only • Local only")
                .font(Theme.mono(Theme.FontSize.microLabel))
                .foregroundColor(Theme.mutedText)
            Spacer()
            if state.benchStatus.running {
                Text("benchmark running: \(state.benchStatus.testType.displayName)")
                    .font(Theme.mono(Theme.FontSize.finePrint))
                    .foregroundColor(Theme.warning)
                Button("Stop Test") { BenchmarkEngine.shared.cancel() }
                    .buttonStyle(FlatButton(tint: Theme.danger))
            } else if state.running {
                Button("Stop Polling") { state.stopPolling() }
                    .buttonStyle(FlatButton(tint: Theme.mutedText))
            } else {
                Button("Start Polling") { state.startPolling() }
                    .buttonStyle(FlatButton())
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Vitals

private struct VitalsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Panel(title: "VITALS") {
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .topLeading),
                GridItem(.flexible(), alignment: .topLeading),
            ], alignment: .leading, spacing: 12) {
                cpuCard
                ramCard
                gpuCard
                coresCard
                diskCard
                networkCard
                powerCard
                sysInfoCard
            }
        }
    }

    private var snap: TelemetrySnapshot { state.snapshot ?? TelemetryPoller.shared.sample() }

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader("CPU", value: Format.pct(snap.cpuUsage))
            TelemetryBar(value: snap.cpuUsage)
            KV("Temp", Format.temp(snap.cpuTemperature))
            KV("Cores", "\(snap.physicalCores)P / \(snap.logicalCores)L")
        }
        .cardStyle()
    }

    private var ramCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader("MEMORY", value: Format.pct(snap.ramUsage))
            TelemetryBar(value: snap.ramUsage)
            KV("Used",  "\(Format.gb(snap.ramUsedGB)) / \(Format.gb(snap.ramTotalGB))")
            KV("Wired", Format.gb(snap.ramWiredGB))
            KV("Compressed", Format.gb(snap.ramCompressedGB))
            KV("Swap", Format.gb(snap.swapUsedGB))
        }
        .cardStyle()
    }

    private var gpuCard: some View {
        let load = snap.gpu.load
        return VStack(alignment: .leading, spacing: 6) {
            cardHeader("GPU", value: load.map(Format.pct) ?? "N/A")
            TelemetryBar(value: load ?? 0, enabled: load != nil)
            KV("Device", snap.gpu.metalDeviceName)
            KV("Cores", snap.gpu.coreCount > 0 ? "\(snap.gpu.coreCount)" : "—")
        }
        .cardStyle()
    }

    private var coresCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader("CORES", value: "\(snap.logicalCores)")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 6),
                      spacing: 5) {
                ForEach(Array(snap.perCoreUsage.enumerated()), id: \.offset) { _, v in
                    Rectangle()
                        .fill(barTint(v))
                        .frame(height: 18)
                        .overlay(
                            Text("\(Int((v * 100).rounded()))")
                                .font(Theme.mono(Theme.FontSize.finePrint))
                                .foregroundColor(Theme.background)
                        )
                        .help("\(Int((v * 100).rounded()))%")
                }
            }
        }
        .cardStyle()
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader("DISK", value: "\(Format.gb(snap.diskUsedGB)) / \(Format.gb(snap.diskTotalGB))")
            TelemetryBar(value: snap.diskTotalGB > 0 ? snap.diskUsedGB / snap.diskTotalGB : 0)
            KV("Read",  Format.rate(snap.diskReadBytesPerSec))
            KV("Write", Format.rate(snap.diskWriteBytesPerSec))
        }
        .cardStyle()
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader("NETWORK", value: "↓ \(Format.rate(snap.netInBytesPerSec))")
            KV("Down", Format.rate(snap.netInBytesPerSec))
            KV("Up",   Format.rate(snap.netOutBytesPerSec))
            KV("Host", snap.hostname)
        }
        .cardStyle()
    }

    private var powerCard: some View {
        let b = snap.battery
        return VStack(alignment: .leading, spacing: 6) {
            cardHeader("POWER", value: b.isPresent
                       ? (b.chargeFraction.map { Format.pctPlain($0) } ?? "—")
                       : "No battery")
            if b.isPresent, let f = b.chargeFraction {
                TelemetryBar(value: f,
                             forcedTint: b.isCharging ? Theme.accent : nil)
                KV("State", b.pluggedIn ? (b.isCharging ? "Charging" : "AC") : "Battery")
                KV("Time",  Format.duration(b.timeRemaining))
                if let cycles = b.cycles { KV("Cycles", "\(cycles)") }
                if let w = b.watts { KV("Power", String(format: "%.2f W", w)) }
            } else {
                KV("Source", "AC / Desktop")
            }
        }
        .cardStyle()
    }

    private var sysInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader("SYSTEM", value: snap.modelName)
            KV("Chip",    snap.chipName)
            KV("OS",      snap.osVersion)
            KV("Build",   snap.osBuild)
            KV("Serial",  snap.serialNumber)
            KV("UUID",    String(snap.hardwareUUID.prefix(13)) + "…")
            KV("Uptime",  Format.uptime(from: snap.bootTime))
        }
        .cardStyle()
    }

    private func cardHeader(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .font(Theme.mono(Theme.FontSize.cardTitle).bold())
                .tracking(1.5)
                .foregroundColor(Theme.mutedText)
            Spacer()
            Text(value)
                .font(Theme.mono(Theme.FontSize.value).bold())
                .foregroundColor(Theme.primaryText)
        }
    }

    private func barTint(_ v: Double) -> Color {
        if v >= 0.90 { return Theme.danger }
        if v >= 0.70 { return Theme.warning }
        return Theme.accent
    }
}

private struct KV: View {
    let k: String
    let v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k)
                .font(Theme.mono(Theme.FontSize.body))
                .foregroundColor(Theme.mutedText)
            Spacer()
            Text(v)
                .font(Theme.mono(Theme.FontSize.body))
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x0d121b))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Device name

private struct DeviceNamePanel: View {
    @EnvironmentObject var state: AppState
    @State private var draft: String = ""
    @State private var saved: Bool = false

    var body: some View {
        Panel(title: "DEVICE NAME") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Friendly name for this Mac, stored locally only.")
                    .font(Theme.mono(Theme.FontSize.body))
                    .foregroundColor(Theme.mutedText)
                TextField("Device name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(Theme.FontSize.value))
                    .padding(8)
                    .background(Color(hex: 0x0d121b))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onAppear { draft = state.deviceName }

                HStack {
                    Button(action: save) {
                        Text(saved ? "Saved" : "Save")
                    }
                    .buttonStyle(FlatButton())
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft == state.deviceName)

                    if saved {
                        Text("local preference updated")
                            .font(Theme.mono(Theme.FontSize.finePrint))
                            .foregroundColor(Theme.accent)
                    }
                    Spacer()
                }
            }
        }
    }

    private func save() {
        state.saveDeviceName(draft)
        withAnimation(.easeOut(duration: 0.2)) { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.4)) { saved = false }
        }
    }
}


// MARK: - Benchmark panel

private struct BenchmarkPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Panel(title: "AI STRESS BENCHMARK") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Built-in CPU, RAM, and GPU stress tests plus a synthetic local-LLM estimator. No models are downloaded — everything runs on this Mac.")
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    benchmarkBadge("CPU",  "matrix multiply",   state.snapshot != nil)
                    benchmarkBadge("RAM",  "bandwidth stress",   state.snapshot != nil)
                    benchmarkBadge("GPU",  computeBackendLabel,  state.snapshot != nil)
                    benchmarkBadge("LLM",  "synthetic estimate", state.snapshot != nil)
                }

                HStack {
                    Button("Open Benchmark Suite") { openWindow(id: "benchmark") }
                        .buttonStyle(FlatButton())
                    if state.benchStatus.running {
                        Text("\(state.benchStatus.testType.displayName) • \(state.benchStatus.phase) • \(Int(state.benchStatus.progress * 100))%")
                            .font(Theme.mono(9))
                            .foregroundColor(Theme.warning)
                    }
                    Spacer()
                    if state.benchStatus.running {
                        Button("Cancel") { BenchmarkEngine.shared.cancel() }
                            .buttonStyle(FlatButton(tint: Theme.danger))
                    }
                }
            }
        }
    }

    private var computeBackendLabel: String {
        ComputeBackend.detect().label
    }

    private func benchmarkBadge(_ label: String, _ sub: String, _ available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.mono(9).bold())
                .foregroundColor(available ? Theme.accent : Theme.mutedText)
            Text(sub)
                .font(Theme.mono(7))
                .foregroundColor(Theme.mutedText)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.panelBorder, lineWidth: 1))
    }
}

// MARK: - Connection log

private struct LogPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Panel(title: "CONNECTION LOG") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(state.logEntries) { entry in
                            Text(entry.formatted)
                                .font(Theme.mono(9))
                                .foregroundColor(color(for: entry.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 120, maxHeight: 200)
                .background(Color(hex: 0x0a0e14))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onChange(of: state.logEntries.count) { _ in
                    if let last = state.logEntries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:  return Theme.primaryText.opacity(0.85)
        case .warn:  return Theme.warning
        case .error: return Theme.danger
        }
    }
}

// MARK: - Uptime helper

extension Format {
    static func uptime(from boot: Date) -> String {
        let s = Int(Date().timeIntervalSince(boot))
        if s < 0 { return "—" }
        let d = s / 86_400
        let h = (s % 86_400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
