// swift-tools-version: 5.9
//
//  Package.swift
//  Sullybase System Telemetry Monitor
//
//  SwiftPM manifest. Lets the whole app build and run from the CLI with no
//  Xcode required — only the macOS Command Line Tools (`xcode-select --install`).
//  `./build.sh` wraps `swift build` and assembles the .app bundle.
//

import PackageDescription

let package = Package(
    name: "SystemMonitorDashboard",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SystemMonitorDashboard",
            path: "Sources/SystemMonitorDashboard",
            resources: [
                // Info.plist is consumed by build.sh when assembling the .app
                // bundle; declaring it here keeps SwiftPM from trying to embed
                // it as a resource into the raw executable.
                .copy("../../Resources/Info.plist")
            ]
        )
    ]
)
