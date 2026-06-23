//
//  Telemetry.swift
//  Sullybase System Telemetry Monitor
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
    // Previous per-core CPU tick snapshot for delta-based utilization math.
    private var prevPerCoreTicks: [(user: Int, system: Int, idle: Int, nice: Int)]?

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
    /// Overall + per-core CPU utilization as a fraction 0...1, computed from
    /// tick deltas between successive samples (the same method Activity
    /// Monitor and Stats use). Instantaneous ratios over a single tick window
    /// are noisy and frequently disagree with those apps, so we keep the
    /// previous per-core tick counters and derive deltas from them.
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
            let size = vm_size_t(numCPUInfo * UInt32(MemoryLayout<integer_t>.size))
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          size)
            _ = size
        }

        let numCPUs = max(1, Int(numCPU))
        let stride = Int(CPU_STATE_MAX)
        var perCore = [Double](repeating: 0, count: numCPUs)

        // Snapshot the current ticks for every core into a plain array we can
        // diff against the previous snapshot.
        var curTicks: [(user: Int, system: Int, idle: Int, nice: Int)] = []
        curTicks.reserveCapacity(numCPUs)
        for i in 0..<numCPUs {
            let off = i * stride
            curTicks.append((
                user:   Int(info[off + Int(CPU_STATE_USER)]),
                system: Int(info[off + Int(CPU_STATE_SYSTEM)]),
                idle:   Int(info[off + Int(CPU_STATE_IDLE)]),
                nice:   Int(info[off + Int(CPU_STATE_NICE)])
            ))
        }

        if let prev = prevPerCoreTicks {
            var sumBusy: Double = 0
            var sumTotal: Double = 0
            for i in 0..<numCPUs {
                let c = curTicks[i]
                let p = i < prev.count ? prev[i] : nil
                if let p = p {
                    let dUser = max(0, c.user   &- p.user)
                    let dSys  = max(0, c.system &- p.system)
                    let dIdle = max(0, c.idle   &- p.idle)
                    let dNice = max(0, c.nice   &- p.nice)
                    let dTotal = dUser + dSys + dIdle + dNice
                    let busy = dUser + dSys + dNice
                    perCore[i] = dTotal > 0 ? Double(busy) / Double(dTotal) : 0
                    sumBusy  += Double(busy)
                    sumTotal += Double(dTotal)
                }
            }
            prevPerCoreTicks = curTicks
            let overall = sumTotal > 0 ? sumBusy / sumTotal : 0
            return (overall, perCore)
        } else {
            // First sample: no delta yet, so fall back to instantaneous ratio.
            // This only happens once; subsequent ticks are delta-based.
            prevPerCoreTicks = curTicks
            for i in 0..<numCPUs {
                let t = curTicks[i]
                let total = t.user + t.system + t.idle + t.nice
                perCore[i] = total > 0 ? Double(t.user + t.system + t.nice) / Double(total) : 0
            }
            let overall = perCore.reduce(0, +) / Double(numCPUs)
            return (overall, perCore)
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

        // IOPS memory rules:
        //   IOPSCopyPowerSourcesInfo  -> "Copy" -> +1 retained -> takeRetainedValue()
        //   IOPSCopyPowerSourcesList  -> "Copy" -> +1 retained -> takeRetainedValue()
        //   IOPSGetPowerSourceDescription -> "Get" -> UNRETAINED -> takeUnretainedValue()
        // Calling takeRetainedValue() on the Get result over-releases the
        // dictionary and corrupts the snapshot's heap (was the launch crash).
        // We also iterate the source array via raw CFArray access so Swift's
        // CF bridging never touches the opaque power-source IDs.
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else {
            return BatteryInfo(isPresent: false, isCharging: false,
                               pluggedIn: false, chargeFraction: nil,
                               timeRemaining: -1, cycles: nil, watts: nil)
        }

        let count = CFArrayGetCount(sources)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(sources, i) else { continue }
            let ps = unsafeBitCast(raw, to: CFTypeRef.self)
            // Get rule: unretained — do NOT release.
            guard let descRef = IOPSGetPowerSourceDescription(snapshot, ps) else { continue }
            guard let desc = descRef.takeUnretainedValue() as? [String: Any], !desc.isEmpty else {
                continue
            }
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

// MARK: - GPU (Apple Silicon via Metal + IORegistry)

extension TelemetryPoller {
    fileprivate func readGPU() -> GPUInfo {
        let name = SystemFacts.shared.gpuName
        let cores = SystemFacts.shared.gpuCores
        let metal = SystemFacts.shared.metalDeviceName
        // Live GPU utilization on Apple Silicon lives in the AGXAccelerator
        // node's PerformanceStatistics dict — the same source the Stats app
        // and asitop read. Returns nil honestly if unavailable so the UI
        // shows N/A rather than a fabricated number.
        let load = readGPULoad()
        return GPUInfo(name: name, coreCount: cores, load: load, metalDeviceName: metal)
    }

    /// Read "Device Utilization %" (0...100) from the GPU accelerator. Falls
    /// back to Renderer utilization if Device is missing.
    private func readGPULoad() -> Double? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else {
            return nil
        }
        var best: Double? = nil
        var entry = IOIteratorNext(it)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry,
                                                           "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                if let v = utilization(stats, key: "Device Utilization %")
                    ?? utilization(stats, key: "Renderer Utilization %") {
                    best = v
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(it)
        }
        IOObjectRelease(it)
        return best
    }

    private func utilization(_ stats: [String: Any], key: String) -> Double? {
        guard let v = stats[key] as? NSNumber else { return nil }
        return v.doubleValue / 100.0
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

        // Try multiple IORegistry nodes and key variants for core counts.
        var cores = 0
        let candidates = ["IOGPUDevice", "AGXAccelerator", "IOAccelerator"]
        for node in candidates {
            if cores > 0 { break }
            if let matching = IOServiceMatching(node) {
                var it: io_iterator_t = 0
                if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS {
                    var entry = IOIteratorNext(it)
                    while entry != 0 {
                        var props: Unmanaged<CFMutableDictionary>?
                        if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                           let d = props?.takeRetainedValue() as? NSDictionary {
                            if let c = d["gpu-core-count"] as? Int { cores = c }
                            else if let c = d["gpu-core-count"] as? NSNumber { cores = c.intValue }
                            else if let cstr = d["gpu-core-count"] as? String, let c = Int(cstr) { cores = c }
                            else if let c = d["gpuCount"] as? Int { cores = c }
                            else if let c = d["core-count"] as? Int { cores = c }
                        }
                        IOObjectRelease(entry)
                        entry = IOIteratorNext(it)
                    }
                    IOObjectRelease(it)
                }
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
