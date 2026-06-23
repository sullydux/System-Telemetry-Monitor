//
//  Format.swift
//  Sullybase System Telemetry Monitor
//
//  Small formatting helpers for telemetry values.
//

import Foundation

enum Format {
    static func pct(_ v: Double) -> String {
        String(format: "%5.1f%%", min(999, max(0, v * 100)))
    }

    static func pctPlain(_ v: Double) -> String {
        String(format: "%.1f%%", min(999, max(0, v * 100)))
    }

    static func bytes(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary)
    }

    /// Human-readable rate (bytes/sec) suitable for disk/network throughput.
    static func rate(_ bytesPerSec: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var v = bytesPerSec
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }

    static func gb(_ v: Double) -> String {
        String(format: "%.2f GB", v)
    }

    static func temp(_ v: Double?) -> String {
        guard let v = v else { return "N/A" }
        return String(format: "%.0f °C", v)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 0 { return "—" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        if m > 0 { return String(format: "%dm %ds", m, s) }
        return String(format: "%ds", s)
    }
}
