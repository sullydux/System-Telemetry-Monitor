import AppKit

final class WindowRegistry {
    static let shared = WindowRegistry()
    private init() {}

    weak var mainWindow: NSWindow?
}

// Helper to capture NSWindow from SwiftUI views
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let win = v.window {
                WindowRegistry.shared.mainWindow = win
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let win = nsView.window {
                WindowRegistry.shared.mainWindow = win
            }
        }
    }
}