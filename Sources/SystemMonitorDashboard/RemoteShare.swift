import Foundation
import SwiftUI
import AppKit

final class RemoteShareManager: ObservableObject {
    static let shared = RemoteShareManager()
    @Published var key: String = ""
    @Published var generatedAt: Date = Date()

    private let file: URL = AppPaths.supportDir.appendingPathComponent("remote-share.json")

    private init() {
        // Per requirements: refresh the key on each app launch (reopened after quit).
        // Also allow refreshing after 24h while running via maybeRefreshIfExpired().
        generateNewKeyAndSave()
    }

    func generateNewKeyAndSave() {
        key = Self.randomKey()
        generatedAt = Date()
        let dict = ["key": key, "ts": ISO8601DateFormatter().string(from: generatedAt)]
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: file, options: .atomic)
        }
    }

    func maybeRefreshIfExpired() {
        if Date().timeIntervalSince(generatedAt) > 24*3600 {
            generateNewKeyAndSave()
        }
    }

    static func randomKey() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // avoid ambiguous chars
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    func copyKeyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    func copyLinkToPasteboard() {
        let url = "https://sullydux.github.io/System-Telemetry-Monitor/"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
