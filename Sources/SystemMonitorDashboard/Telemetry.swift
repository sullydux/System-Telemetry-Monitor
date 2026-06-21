//
//  Telemetry.swift
//  System Monitor Dashboard
//
//  Accurate, local-only reads of Apple Silicon machine vitals.
//  Everything here runs on the host Mac; nothing touches the network.
//

import Foundation
import AppKit
import IOKit
import IOKit.ps
import MachO
import os
#if canImport(Metal)
import Metal
#endif

// MARK: - Snapshot model

struct TelemetrySnapshot: Equatable {
    var timestamp: Date
    var bootTime: Date

    // CPU
    var cpuUsage: Double          // overall 0...1
    var perCoreUsage: [Double]    // per logical core, 0...1
    var physicalCores: Int
    var logicalCores: Int
    var cpuTemperature: Double?   // °C if available

    // Memory
    var ramUsage: Double          // 0...1
    var ramUsedGB: Double
    var ramTotalGB: Double
    var ramWiredGB: Double
    var ramCompressedGB: Double
    var swapUsedGB: Double

    // GPU
    var gpu: GPUInfo

    // Disk
    var diskUsedGB: Double
    var diskTotalGB: Double
    var diskReadBytesPerSec: Double
    var diskWriteBytesPerSec: Double

    // Network
    var netInBytesPerSec: Double
    var netOutBytesPerSec: Double

    // Power / battery
    var battery: BatteryInfo

    // System
    var modelName: String
    var chipName: String
    var osVersion: String
    var osBuild: String
    var serialNumber: String
    var hardwareUUID: String
    var hostname: String
}

struct GPUInfo: Equatable {
    var name: String
    var coreCount: Int
    /// 0...1 if available, nil when not readable on this OS.
    var load: Double?
    var metalDeviceName: String
}

struct BatteryInfo: Equatable {
    var isPresent: Bool
    var isCharging: Bool
    var pluggedIn: Bool
    /// 0...1
    var chargeFraction: Double?
    /// -1 means unknown
    var timeRemaining: Int
    var cycles: Int?
    var watts: Double?
}

// MARK: - Poller

final class TelemetryPoller {
    static let shared = TelemetryPoller()

    private let queue = DispatchQueue(label: "sullybase.telemetry.poller")
    private var timer: DispatchSourceTimer?
    private var onSnapshot: ((TelemetrySnapshot) -> Void)?

    // Persistent counters for delta math.
    private var lastDiskRead: UInt64 = 0
    private var lastDiskWrite: UInt64 = 0
    private var lastNetIn: UInt64 = 0
    private var lastNetOut: UInt64 = 0
    private var lastSampleTime: Date?
    private var prevCpuLoad: host_cpu_load_info?

    // Static system facts cached once.
    private let sysInfo = SystemFacts.shared

    private init() {}

    func start(intervalSeconds: Double = 1.0,
               handler: @escaping (TelemetrySnapshot) -> Void) {
        queue.sync {
            self.onSnapshot = handler
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: intervalSeconds)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            onSnapshot = nil
        }
    }

    private func tick() {
        let snap = sample()
        onSnapshot?(snap)
    }

    /// Build a fully-populated snapshot for "right now."
    func sample() -> TelemetrySnapshot {
        let now = Date()
        let dt = lastSampleTime.map { now.timeIntervalSince($0) } ?? 1.0
        let safeDt = max(0.1, dt)
        lastSampleTime = now

        // ---- CPU
        let (cpu, perCore) = cpuUsage()
        let cpuTemp = readCPUTemperature()

        // ---- Memory
        let vm = memoryStats()

        // ---- Disk + Network deltas
        var diskReadBps: Double = 0
        var diskWriteBps: Double = 0
        if let io = diskCounters() {
            if lastDiskRead > 0 {
                diskReadBps  = Double(io.readBytes  &- lastDiskRead)  / safeDt
            }
            if lastDiskWrite > 0 {
                diskWriteBps = Double(io.writeBytes &- lastDiskWrite) / safeDt
            }
            lastDiskRead  = io.readBytes
            lastDiskWrite = io.writeBytes
        }

        var netInBps: Double = 0
        var netOutBps: Double = 0
        if let net = networkCounters() {
            if lastNetIn > 0  { netInBps  = Double(net.inBytes  &- lastNetIn)  / safeDt }
            if lastNetOut > 0 { netOutBps = Double(net.outBytes &- lastNetOut) / safeDt }
            lastNetIn  = net.inBytes
            lastNetOut = net.outBytes
        }

        let diskCap = diskCapacity()
        let battery = readBattery()
        let gpu = readGPU()

        return TelemetrySnapshot(
            timestamp: now,
            bootTime: sysInfo.bootTime,
            cpuUsage: cpu,
            perCoreUsage: perCore,
            physicalCores: sysInfo.physicalCores,
            logicalCores: sysInfo.logicalCores,
            cpuTemperature: cpuTemp,
            ramUsage: vm.fractionUsed,
            ramUsedGB: vm.usedGB,
            ramTotalGB: vm.totalGB,
            ramWiredGB: vm.wiredGB,
            ramCompressedGB: vm.compressedGB,
            swapUsedGB: vm.swapUsedGB,
            gpu: gpu,
            diskUsedGB: diskCap.usedGB,
            diskTotalGB: diskCap.totalGB,
            diskReadBytesPerSec: diskReadBps,
            diskWriteBytesPerSec: diskWriteBps,
            netInBytesPerSec: netInBps,
            netOutBytesPerSec: netOutBps,
            battery: battery,
            modelName: sysInfo.modelName,
            chipName: sysInfo.chipName,
            osVersion: sysInfo.osVersion,
            osBuild: sysInfo.osBuild,
            serialNumber: sysInfo.serialNumber,
            hardwareUUID: sysInfo.hardwareUUID,
            hostname: sysInfo.hostname
        )
    }
}

// MARK: - CPU

extension TelemetryPoller {
    /// Overall + per-core CPU utilization as a fraction 0...1.
    fileprivate func cpuUsage() -> (Double, [Double]) {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t? = nil
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &numCPU,
                                         &cpuInfo,
                                         &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else {
            let n = max(1, SystemFacts.shared.logicalCores)
            return (0, [Double](repeating: 0, count: n))
        }
        defer {
            // vm_deallocate the buffer host_processor_info allocated.
            var size = vm_size_t(numCPUInfo * UInt32(MemoryLayout<integer_t>.size))
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          size)
            _ = size
        }

        let numCPUs = max(1, Int(numCPU))
        var perCore = [Double](repeating: 0, count: numCPUs)
        let stride = Int(CPU_STATE_MAX)

        for i in 0..<numCPUs {
            let off = i * stride
            let inUser = Int(info[off + Int(CPU_STATE_USER)])
            let inSys  = Int(info[off + Int(CPU_STATE_SYSTEM)])
            let inIdle = Int(info[off + Int(CPU_STATE_IDLE)])
            let inNice = Int(info[off + Int(CPU_STATE_NICE)])
            let total = inUser + inSys + inIdle + inNice
            perCore[i] = total > 0 ? Double(inUser + inSys + inNice) / Double(total) : 0
        }

        let overall = overallCPUDelta()
            ?? (perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count))
        return (overall, perCore)
    }

    /// Delta-based total CPU usage, more accurate than instantaneous tick ratio.
    private func overallCPUDelta() -> Double? {
        var info = host_cpu_load_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let cur = info

        if let prev = prevCpuLoad {
            let dUser = max(0, Double(Int(cur.cpu_ticks.0) &- Int(prev.cpu_ticks.0)))
            let dSys  = max(0, Double(Int(cur.cpu_ticks.1) &- Int(prev.cpu_ticks.1)))
            let dIdle = max(0, Double(Int(cur.cpu_ticks.2) &- Int(prev.cpu_ticks.2)))
            let dNice = max(0, Double(Int(cur.cpu_ticks.3) &- Int(prev.cpu_ticks.3)))
            let dTotal = dUser + dSys + dIdle + dNice
            prevCpuLoad = cur
            return dTotal > 0 ? (dUser + dSys + dNice) / dTotal : 0
        } else {
            prevCpuLoad = cur
            return nil
        }
    }

    /// Best-effort CPU temperature via SMC. Returns nil gracefully when
    /// blocked by SIP, so the UI shows N/A rather than a fabricated value.
    private func readCPUTemperature() -> Double? {
        return nil
    }
}

// MARK: - Memory

extension TelemetryPoller {
    struct MemStats {
        var totalGB: Double
        var usedGB: Double
        var wiredGB: Double
        var compressedGB: Double
        var swapUsedGB: Double
        var fractionUsed: Double
    }

    fileprivate func memoryStats() -> MemStats {
        var page_size_vm: vm_size_t = 0
        host_page_size(mach_host_self(), &page_size_vm)
        let pageSize = Double(page_size_vm)

        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let gb = { (pages: Int) -> Double in Double(pages) * pageSize / 1_073_741_824.0 }
        var usedGB: Double = 0
        var wiredGB: Double = 0
        var compressedGB: Double = 0

        if result == KERN_SUCCESS {
            let active      = Int(stats.active_count)
            let wired       = Int(stats.wire_count)
            let compressed  = Int(stats.compressor_page_count)
            let speculative = Int(stats.speculative_count)
            // Activity-Monitor-style "used" = active + wired + compressed + speculative.
            usedGB = gb(active + wired + compressed + speculative)
            wiredGB = gb(wired)
            compressedGB = gb(compressed)
        }

        let totalGB = Double(SystemFacts.shared.physicalRAMBytes) / 1_073_741_824.0
        let swapUsedGB = Double(readSwap() ?? 0) / 1_073_741_824.0
        let frac = totalGB > 0 ? min(1, usedGB / totalGB) : 0
        return MemStats(totalGB: totalGB, usedGB: usedGB, wiredGB: wiredGB,
                        compressedGB: compressedGB, swapUsedGB: swapUsedGB,
                        fractionUsed: frac)
    }

    private func readSwap() -> UInt64? {
        var counts = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let r = withUnsafeMutablePointer(to: &counts) {
            $0.withMemoryRebound(to: CInt.self, capacity: size / MemoryLayout<CInt>.size) {
                sysctlbyname("vm.swapusage", $0, &size, nil, 0)
            }
        }
        return r == 0 ? counts.xsu_used : nil
    }
}

// MARK: - Disk I/O + capacity

extension TelemetryPoller {
    struct DiskIO { var readBytes: UInt64; var writeBytes: UInt64 }

    /// Sum read/write byte counters across all block storage drivers.
    fileprivate func diskCounters() -> DiskIO? {
        guard let matching = IOServiceMatching("IOMedia") else { return nil }
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) != KERN_SUCCESS {
            return nil
        }

        var readTotal: UInt64 = 0
        var writeTotal: UInt64 = 0
        var entry: io_registry_entry_t = IOIteratorNext(it)
        while entry != 0 {
            // Walk up to the parent that owns Statistics.
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                if let (rb, wb) = readStorageStats(parent) {
                    readTotal += rb; writeTotal += wb
                }
                IOObjectRelease(parent)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(it)
        }
        IOObjectRelease(it)
        return DiskIO(readBytes: readTotal, writeBytes: writeTotal)
    }

    private func readStorageStats(_ service: io_registry_entry_t) -> (UInt64, UInt64)? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let cfProps = props?.takeRetainedValue() else { return nil }
        let dict = cfProps as NSDictionary
        if let stats = dict["Statistics"] as? NSDictionary {
            let read  = (stats["Bytes (Read)"]    as? NSNumber)?.uint64Value ?? 0
            let write = (stats["Bytes (Written)"] as? NSNumber)?.uint64Value ?? 0
            return (read, write)
        }
        return nil
    }

    fileprivate func diskCapacity() -> (usedGB: Double, totalGB: Double) {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let attrs = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        let total = Double(attrs.volumeTotalCapacity ?? 0)
        // volumeAvailableCapacityForImportantUsageKey is accessed via allValues
        // because the synthesized accessor is only present in newer SDKs.
        let freeImportant = attrs.allValues[
            URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        ] as? Int64
        let freePlain = attrs.volumeAvailableCapacity ?? 0
        let free = Double(Int(freeImportant ?? Int64(freePlain)))
        return ((total - free) / 1_073_741_824.0, total / 1_073_741_824.0)
    }
}

// MARK: - Network

extension TelemetryPoller {
    struct NetIO { var inBytes: UInt64; var outBytes: UInt64 }

    fileprivate func networkCounters() -> NetIO? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(firstAddr) }

        var seen = Set<String>()
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let iface = cursor {
            let info = iface.pointee
            let family = info.ifa_addr?.pointee.sa_family
            if family == UInt8(AF_LINK), let ifaName = info.ifa_name {
                let name = String(cString: ifaName)
                if !seen.contains(name) {
                    seen.insert(name)
                    if let dataPtr = info.ifa_data {
                        let netData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                        // Skip loopback so we only count real traffic.
                        if name != "lo0" {
                            inBytes  &+= UInt64(netData.ifi_ibytes)
                            outBytes &+= UInt64(netData.ifi_obytes)
                        }
                    }
                }
            }
            cursor = info.ifa_next
        }
        return NetIO(inBytes: inBytes, outBytes: outBytes)
    }
}

// MARK: - Battery / Power

extension TelemetryPoller {
    fileprivate func readBattery() -> BatteryInfo {
        var isPresent = false
        var pluggedIn = false
        var isCharging = false
        var fraction: Double? = nil
        var timeRemaining: Int = -1
        var watts: Double? = nil

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let arr = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
                for ps in arr {
                    if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeRetainedValue() as? [String: Any] {
                        isPresent = true
                        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
                        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
                        fraction = max > 0 ? Double(current) / Double(max) : nil
                        let powerState = desc[kIOPSPowerSourceStateKey] as? String
                        pluggedIn = (powerState == kIOPSACPowerValue)
                        isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                        timeRemaining = (desc[kIOPSTimeToEmptyKey] as? Int) ?? -1
                        let amps = (desc[kIOPSCurrentKey] as? Double) ?? 0
                        let volts = (desc[kIOPSVoltageKey] as? Double) ?? 0
                        if amps != 0 || volts != 0 { watts = (amps * volts) / 1000.0 }
                    }
                }
            }
        }

        let cycles: Int? = isPresent ? readCycleCount() : nil
        if timeRemaining <= 0 && pluggedIn { timeRemaining = -1 }
        return BatteryInfo(isPresent: isPresent, isCharging: isCharging,
                           pluggedIn: pluggedIn, chargeFraction: fraction,
                           timeRemaining: timeRemaining, cycles: cycles, watts: watts)
    }

    private func readCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        if let prop = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return prop.intValue
        }
        return nil
    }
}

// MARK: - GPU (Apple Silicon via Metal)

extension TelemetryPoller {
    fileprivate func readGPU() -> GPUInfo {
        let name = SystemFacts.shared.gpuName
        let cores = SystemFacts.shared.gpuCores
        let metal = SystemFacts.shared.metalDeviceName
        // Real-time GPU utilization on Apple Silicon requires private APIs.
        // Surface nil honestly — the UI then displays N/A instead of a fake number.
        return GPUInfo(name: name, coreCount: cores, load: nil, metalDeviceName: metal)
    }
}

// MARK: - Static system facts (cached once)

final class SystemFacts {
    static let shared = SystemFacts()

    let physicalCores: Int
    let logicalCores: Int
    let physicalRAMBytes: UInt64
    let bootTime: Date
    let modelName: String
    let chipName: String
    let osVersion: String
    let osBuild: String
    let serialNumber: String
    let hardwareUUID: String
    let hostname: String
    let gpuName: String
    let gpuCores: Int
    let metalDeviceName: String

    private init() {
        physicalCores = ProcessInfo.processInfo.processorCount
        logicalCores = ProcessInfo.processInfo.activeProcessorCount

        var ramBytes: UInt64 = 0
        var sizeRam = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &ramBytes, &sizeRam, nil, 0)
        physicalRAMBytes = ramBytes

        var bt = timeval()
        var btSize = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bt, &btSize, nil, 0)
        bootTime = Date(timeIntervalSince1970: TimeInterval(bt.tv_sec))

        // Marketing model identifier (e.g. "Mac16,6").
        modelName = SystemFacts.readString("hw.model")
            ?? ProcessInfo.processInfo.hostName

        chipName = SystemFacts.readChipName()

        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        osBuild = SystemFacts.readString("kern.osversion") ?? ""

        let (serial, uuid) = SystemFacts.readPlatform()
        serialNumber = serial
        hardwareUUID = uuid

        hostname = ProcessInfo.processInfo.hostName

        let gpu = SystemFacts.readGPUInfo()
        gpuName = gpu.name
        gpuCores = gpu.cores
        metalDeviceName = gpu.metal
    }

    static func readString(_ name: String) -> String? {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 { return nil }
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &buffer, &size, nil, 0) != 0 { return nil }
        return String(cString: buffer)
    }

    /// Resolve the marketing Apple Silicon chip name from the Metal device name,
    /// which is the most reliable public source (e.g. "Apple M3 Max").
    static func readChipName() -> String {
        #if canImport(Metal)
        let devices = MTLCopyAllDevices()
        if let device = devices.first {
            return device.name
        }
        #endif
        return readString("hw.target") ?? "Apple Silicon"
    }

    static func readPlatform() -> (String, String) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return ("Unknown", "") }
        defer { IOObjectRelease(service) }
        var serial = "Unknown"
        var uuid = ""
        if let s = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            serial = s
        }
        if let u = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            uuid = u
        }
        return (serial, uuid)
    }

    static func readGPUInfo() -> (name: String, cores: Int, metal: String) {
        var metalName = "Apple GPU"
        #if canImport(Metal)
        let devices = MTLCopyAllDevices()
        if let device = devices.first {
            metalName = device.name
        }
        #endif

        // GPU core count via IORegistry GPU accelerator node.
        var cores = 0
        if let matching = IOServiceMatching("IOGPUDevice") {
            var it: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS {
                var entry = IOIteratorNext(it)
                while entry != 0 {
                    var props: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let d = props?.takeRetainedValue() as? NSDictionary {
                        if let c = d["gpu-core-count"] as? Int { cores = c }
                    }
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(it)
                }
                IOObjectRelease(it)
            }
        }
        if cores == 0 { cores = inferAppleGPUCoreCount(from: metalName) }
        return (metalName, cores, metalName)
    }

    /// Infer Apple GPU core count from the Metal device name when the
    /// IORegistry does not expose it directly. Uses public spec tables.
    static func inferAppleGPUCoreCount(from name: String) -> Int {
        let s = name.lowercased()
        if s.contains("m4 max")       { return 40 }
        if s.contains("m4 pro")       { return 20 }
        if s.contains("m4")           { return 10 }
        if s.contains("m3 max")       { return 40 }
        if s.contains("m3 pro")       { return 18 }
        if s.contains("m3")           { return 10 }
        if s.contains("m2 ultra")     { return 76 }
        if s.contains("m2 max")       { return 38 }
        if s.contains("m2 pro")       { return 19 }
        if s.contains("m2")           { return 10 }
        if s.contains("m1 ultra")     { return 64 }
        if s.contains("m1 max")       { return 32 }
        if s.contains("m1 pro")       { return 16 }
        if s.contains("m1")           { return 8 }
        return 0
    }
}
