import SwiftUI
import AppKit

struct MenubarPopover: View {
    @State private var snapshot = TelemetryPoller.shared.sample()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Quick View")
                    .font(.headline)
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(BorderlessButtonStyle())
            }
            // Remote share server address (copyable)
            HStack {
                Text("Server:")
                    .font(.caption)
                    .foregroundColor(Theme.mutedText)
                Spacer()
                Text(ServerAddressManager.shared.address)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button(action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ServerAddressManager.shared.address, forType: .string) }) {
                    Image(systemName: "link")
                }.buttonStyle(BorderlessButtonStyle())
            }

            // Remote share key (copyable)
            HStack {
                Text("Share key:")
                    .font(.caption)
                    .foregroundColor(Theme.mutedText)
                Spacer()
                Text(RemoteShareManager.shared.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button(action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(RemoteShareManager.shared.key, forType: .string) }) {
                    Image(systemName: "doc.on.doc")
                }.buttonStyle(BorderlessButtonStyle())
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("CPU").font(.caption)
                    TelemetryMiniBar(value: snapshot.cpuUsage)
                }
                VStack(alignment: .leading) {
                    Text("RAM").font(.caption)
                    TelemetryMiniBar(value: snapshot.ramUsage)
                }
                VStack(alignment: .leading) {
                    Text("GPU").font(.caption)
                    TelemetryMiniBar(value: snapshot.gpu.load ?? 0, enabled: snapshot.gpu.load != nil)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Network:"); Spacer(); Text("↓ \(Format.rate(snapshot.netInBytesPerSec)) • ↑ \(Format.rate(snapshot.netOutBytesPerSec))").font(.caption) }
                HStack { Text("Disk:"); Spacer(); Text("\(Format.gb(snapshot.diskUsedGB)) / \(Format.gb(snapshot.diskTotalGB))").font(.caption) }
                HStack { Text("Power:"); Spacer(); Text(snapshot.battery.isPresent ? (snapshot.battery.chargeFraction.map(Format.pctPlain) ?? "—") : "AC").font(.caption) }
            }
            HStack {
                Button("Open App") { openApp() }
                    .buttonStyle(PlainButtonStyle())
                Spacer()
                Button("Off") { NSApp.terminate(nil) }
                    .foregroundColor(.red)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func refresh() {
        snapshot = TelemetryPoller.shared.sample()
    }

    private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = WindowRegistry.shared.mainWindow {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Prefer windows containing the main title fragments observed at runtime.
        if let main = NSApp.windows.first(where: {
            let t = $0.title.lowercased()
            return t.contains("sullybase system telemetry monitor") || t.contains("local only") || t.contains("system monitor dashboard")
        }) {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Avoid the benchmark window specifically; choose any non-benchmark window.
        if let nonBench = NSApp.windows.first(where: { !$0.title.lowercased().contains("benchmark") }) {
            if nonBench.isMiniaturized { nonBench.deminiaturize(nil) }
            nonBench.makeKeyAndOrderFront(nil)
            return
        }
        for w in NSApp.windows {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }
}

private struct TelemetryMiniBar: View {
    var value: Double
    var enabled: Bool = true
    var body: some View {
        GeometryReader { g in
            let pct = max(0, min(1, value))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2)).frame(height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: g.size.width * CGFloat(pct), height: 10)
            }
        }
        .frame(height: 12)
    }
}