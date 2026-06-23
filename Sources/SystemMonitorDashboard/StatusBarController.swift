//
//  StatusBarController.swift
//  Sullybase System Telemetry Monitor
//

import SwiftUI
import AppKit

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var hostingController: NSHostingController<MenubarPopover>

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        hostingController = NSHostingController(rootView: MenubarPopover())
        super.init()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 280)
        if let button = statusItem.button {
            if let img = NSImage(named: NSImage.Name("AppIcon")) {
                img.isTemplate = true
                button.image = img
            } else if let sym = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Telemetry") {
                sym.isTemplate = true
                button.image = sym
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}