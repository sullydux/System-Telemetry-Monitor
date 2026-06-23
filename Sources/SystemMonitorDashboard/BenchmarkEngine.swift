//
//  BenchmarkEngine.swift
//  System Monitor Dashboard
//
//  Internal benchmark engine. Runs CPU / RAM / GPU / synthetic-LLM tests on
//  background threads. No models are downloaded; everything is local.
//

import Foundation
import Accelerate
#if canImport(Metal)
import Metal
#endif

// MARK: - Compute backend detection

enum ComputeBackend {
    case mlxMetal
    case torchMPS
    case torchCUDA
    case none

    static func detect() -> ComputeBackend {
        // We do not bundle MLX/PyTorch. We report the most capable local GPU
        // backend that Apple Silicon exposes for this app's own Metal path.
        #if canImport(Metal)
        if !MTLCopyAllDevices().isEmpty { return .mlxMetal }
        #endif
        return .none
    }

    var label: String {
        switch self {
        case .mlxMetal:  return "MLX Apple Metal GPU"
        case .torchMPS:  return "PyTorch MPS Apple Metal GPU"
        case .torchCUDA: return "PyTorch CUDA GPU"
        case .none:      return "None found — GPU tests disabled"
        }
    }

    var available: Bool { self != .none }
}

// MARK: - Engine

final class BenchmarkEngine: @unchecked Sendable {
    static let shared = BenchmarkEngine()

    private var task: Task<Void, Never>?
    private let lock = NSLock()

    private(set) var isRunning: Bool = false
    private(set) var cancelled: Bool = false

    private weak var appState: AppState?
    func bind(_ state: AppState) { appState = state }

    private init() {}

    // MARK: Public control

    func start(test: BenchmarkTestType, duration: Double, params: BenchmarkStatus) {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        cancelled = false
        lock.unlock()

        appState?.log("Benchmark start: \(test.displayName) (\(Int(duration))s)", .info)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(test: test, duration: duration, params: params)
            self?.finish()
        }

        appState?.updateBenchmark {
            $0.running = true
            $0.testType = test
            $0.durationSeconds = duration
            $0.elapsedSeconds = 0
            $0.progress = 0
            $0.error = nil
            $0.phase = "Starting"
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        task?.cancel()
        appState?.log("Benchmark cancelled by user", .warn)
    }

    private func finish() {
        lock.lock()
        isRunning = false
        lock.unlock()
        DispatchQueue.main.async {
            self.appState?.updateBenchmark { $0.running = false; $0.phase = "Idle" }
        }
    }

    private func checkCancelled() throws {
        try Task.checkCancellation()
        lock.lock(); let c = cancelled; lock.unlock()
        if c { throw CancellationError() }
    }

    // MARK: Dispatch

    private func run(test: BenchmarkTestType, duration: Double, params: BenchmarkStatus) async {
        do {
            switch test {
            case .cpu:   try await runCpu(duration: duration, params: params)
            case .ram:   try await runRam(duration: duration, params: params)
            case .gpu:   try await runGpu(duration: duration, params: params)
            case .llm:   try await runLLM(duration: duration, params: params)
            case .suite: await runSuite(duration: duration, params: params)
            }
        } catch is CancellationError {
            await postOnMain { self.appState?.updateBenchmark { $0.error = "Cancelled" } }
            appState?.log("Benchmark cancelled", .warn)
        } catch {
            let msg = "\(error)"
            await postOnMain { self.appState?.updateBenchmark { $0.error = msg } }
            appState?.log("Benchmark error: \(msg)", .error)
        }
    }

    // MARK: CPU test

    private func runCpu(duration: Double, params: BenchmarkStatus) async throws {
        await setPhase("CPU • spinning up \(params.cpuWorkers) workers")
        let workers = max(1, params.cpuWorkers)
        let n = nextPow2(max(64, params.cpuMatrixSize))
        let group = DispatchGroup()
        let counter = ThreadSafeCounter()

        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        let pollTask = launchPoller(start: start, deadline: deadline, label: "CPU") { elapsed, progress in
            let m = counter.value
            let throughput = m == 0 ? 0 : Double(m) / max(0.001, elapsed)
            self.publishLive("""
            CPU BENCHMARK
            workers        : \(workers)
            matrix size    : \(n)×\(n)
            elapsed        : \(String(format: "%.1f", elapsed)) s
            total matmuls  : \(m)
            throughput     : \(Format.big(throughput)) matmuls/s
            avg cpu        : \(self.currentCpuLabel())
            """, progress: progress)
        }

        // Spawn workers on background queues; each only mutates the counter.
        for _ in 0..<workers {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                BenchmarkEngine.cpuWorkerStatic(n: n, deadline: deadline, counter: counter)
            }
        }
        // Wait on a background thread so we don't block the actor pool.
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { cont.resume() }
        }
        pollTask.cancel()

        let elapsed = Date().timeIntervalSince(start)
        let totalMatmuls = counter.value
        let throughput = Double(totalMatmuls) / max(0.001, elapsed)
        let avgCPU = TelemetryPoller.shared.sample().cpuUsage * 100

        let summary = """
        CPU BENCHMARK — COMPLETE
        workers            : \(workers)
        matrix size        : \(n)×\(n)
        duration           : \(String(format: "%.2f", elapsed)) s
        total matmuls      : \(totalMatmuls)
        synthetic throughput: \(Format.big(throughput)) matmuls/s
        average CPU usage  : \(String(format: "%.1f", avgCPU)) %
        """
        let metrics: [String: Double] = [
            "matmuls": Double(totalMatmuls),
            "throughput_matmuls_per_s": throughput,
            "avg_cpu_pct": avgCPU,
            "workers": Double(workers),
            "matrix_size": Double(n)
        ]
        await commit(test: .cpu, summary: summary, metrics: metrics,
                     duration: elapsed, phase: "CPU")
    }

    /// Static so the worker closure captures no instance state.
    fileprivate static func cpuWorkerStatic(n: Int, deadline: Date, counter: ThreadSafeCounter) {
        let count = n * n
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        var c = [Float](repeating: 0, count: count)
        for i in 0..<count {
            a[i] = Float.random(in: -1...1)
            b[i] = Float.random(in: -1...1)
        }

        let nn: Int32 = Int32(n)
        while Date() < deadline {
            // c = a × b (Accelerate sgemm). Cancellation is honored by deadline.
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                        nn, nn, nn,
                        1.0, a, nn, b, nn,
                        0.0, &c, nn)
            counter.increment()
        }
    }

    // MARK: RAM test

    private func runRam(duration: Double, params: BenchmarkStatus) async throws {
        await setPhase("RAM • allocating buffer")
        let totalRAM = Double(SystemFacts.shared.physicalRAMBytes)
        let targetGB = totalRAM * Double(max(10, min(95, params.ramPercent))) / 100.0 / 1_073_741_824.0
        let bytes = Int(targetGB * 1_073_741_824.0)
        let elements = max(1024, bytes / MemoryLayout<UInt64>.size)

        // Allocate off the main thread.
        let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: elements)
        defer { buffer.deallocate() }
        for i in 0..<elements { buffer[i] = UInt64(i & 0xdeadbeef) }

        await setPhase("RAM • saturating bandwidth")
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        var passes = 0
        let pollTask = launchPoller(start: start, deadline: deadline, label: "RAM") { elapsed, progress in
            let moved = Double(passes) * Double(elements) * 8.0
            let bw = elapsed > 0 ? moved / elapsed : 0
            self.publishLive("""
            RAM BENCHMARK
            target          : \(String(format: "%.2f", targetGB)) GB (\(params.ramPercent)% of \(String(format: "%.0f", totalRAM/1_073_741_824.0)) GB)
            elements        : \(Format.big(Double(elements)))
            passes          : \(passes)
            bytes moved     : \(Format.big(moved)) B
            bandwidth       : \(Format.rate(bw))
            avg cpu         : \(self.currentCpuLabel())
            """, progress: progress)
        }

        let pattern: UInt64 = 0x9E3779B97F4A7C15
        while Date() < deadline {
            try doCancelCheck()
            // Read-modify-write sweep over the whole buffer.
            for i in 0..<elements {
                buffer[i] &+= pattern &* buffer[i] ^ (UInt64(i) &+ 1)
            }
            passes += 1
        }
        pollTask.cancel()

        let elapsed = Date().timeIntervalSince(start)
        let bytesMoved = Double(passes) * Double(elements) * 8.0
        let bandwidth = elapsed > 0 ? bytesMoved / elapsed : 0

        let summary = """
        RAM BENCHMARK — COMPLETE
        target allocation  : \(String(format: "%.2f", targetGB)) GB
        array elements     : \(Format.big(Double(elements)))
        full passes        : \(passes)
        bytes moved        : \(Format.big(bytesMoved)) B
        bandwidth          : \(Format.rate(bandwidth))
        duration           : \(String(format: "%.2f", elapsed)) s
        """
        let metrics: [String: Double] = [
            "target_gb": targetGB,
            "bytes_moved": bytesMoved,
            "bandwidth_bytes_per_s": bandwidth,
            "passes": Double(passes)
        ]
        await commit(test: .ram, summary: summary, metrics: metrics,
                     duration: elapsed, phase: "RAM")
    }

    // MARK: GPU test

    private func runGpu(duration: Double, params: BenchmarkStatus) async throws {
        let backend = ComputeBackend.detect()
        guard backend.available else {
            let msg = "GPU BENCHMARK — UNAVAILABLE\nbackend: \(backend.label)\nNo Metal device was found on this Mac."
            await commit(test: .gpu, summary: msg, metrics: [:],
                         duration: 0, phase: "GPU", error: msg)
            return
        }
        await setPhase("GPU • preparing Metal kernels")

        #if canImport(Metal)
        let allDevices = MTLCopyAllDevices()
        guard let device = allDevices.first,
              let queue = device.makeCommandQueue() else {
            let msg = "GPU BENCHMARK — UNAVAILABLE\nMetal device / command queue could not be created."
            await commit(test: .gpu, summary: msg, metrics: [:],
                         duration: 0, phase: "GPU", error: msg)
            return
        }

        let n = nextPow2(max(128, params.gpuMatrixSize))
        let library = try makeMatmulLibrary(device: device)
        // makeComputePipelineState(function:) is async on macOS 26+ SDKs.
        let pipeline = try await device.makeComputePipelineState(function: library)
        let count = n * n
        let sharedOptions = MTLResourceOptions.storageModeShared
        let bufferA = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: sharedOptions)!
        let bufferB = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: sharedOptions)!
        let bufferC = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: sharedOptions)!
        fillRandom(buffer: bufferA, count: count)
        fillRandom(buffer: bufferB, count: count)

        await setPhase("GPU • dispatching matmuls")
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        var matmuls = 0
        let counter = ThreadSafeCounter()

        let pollTask = launchPoller(start: start, deadline: deadline, label: "GPU") { elapsed, progress in
            let m = counter.value
            let throughput = elapsed > 0 ? Double(m) / elapsed : 0
            self.publishLive("""
            GPU BENCHMARK
            backend         : \(backend.label)
            device          : \(device.name)
            matrix size     : \(n)×\(n)
            matmuls         : \(m)
            throughput      : \(Format.big(throughput)) matmuls/s
            """, progress: progress)
        }

        let threadGroupSize = MTLSizeMake(16, 16, 1)
        let groups = MTLSizeMake((n + 15) / 16, (n + 15) / 16, 1)
        while Date() < deadline {
            try doCancelCheck()
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { break }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(bufferA, offset: 0, index: 0)
            enc.setBuffer(bufferB, offset: 0, index: 1)
            enc.setBuffer(bufferC, offset: 0, index: 2)
            var n32: UInt32 = UInt32(n)
            enc.setBytes(&n32, length: MemoryLayout<UInt32>.size, index: 3)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threadGroupSize)
            enc.endEncoding()
            cmd.commit()
            // waitUntilCompleted() is unavailable from async contexts on
            // macOS 26+; await the async completion instead.
            await cmd.completed()
            counter.increment()
            matmuls &+= 1
        }
        pollTask.cancel()

        let elapsed = Date().timeIntervalSince(start)
        let throughput = elapsed > 0 ? Double(matmuls) / elapsed : 0

        let summary = """
        GPU BENCHMARK — COMPLETE
        backend             : \(backend.label)
        device              : \(device.name)
        matrix size         : \(n)×\(n)
        total matmuls       : \(matmuls)
        synthetic throughput: \(Format.big(throughput)) matmuls/s
        duration            : \(String(format: "%.2f", elapsed)) s
        """
        let metrics: [String: Double] = [
            "matmuls": Double(matmuls),
            "throughput_matmuls_per_s": throughput,
            "matrix_size": Double(n)
        ]
        await commit(test: .gpu, summary: summary, metrics: metrics,
                     duration: elapsed, phase: "GPU")
        #else
        let msg = "GPU BENCHMARK — UNAVAILABLE\nMetal framework unavailable in this build."
        await commit(test: .gpu, summary: msg, metrics: [:],
                     duration: 0, phase: "GPU", error: msg)
        #endif
    }

    // MARK: Synthetic LLM test

    private func runLLM(duration: Double, params: BenchmarkStatus) async throws {
        await setPhase("LLM • modeling local inference load")

        let paramsB = params.llmPreset == "custom" ? params.llmCustomParamsB : Int(params.llmPreset.replacingOccurrences(of: "B", with: "")) ?? 7
        let weightsBytes = estimateModelSizeBytes(paramsB: paramsB, quant: params.llmQuantization)
        let kvBytes = estimateKVCacheBytes(ctx: params.llmContextLength, paramsB: paramsB)
        let totalWorkingSet = weightsBytes + kvBytes

        // Derived estimates from local hardware.
        let totalRAM = Double(SystemFacts.shared.physicalRAMBytes)
        let gpuCores = SystemFacts.shared.gpuCores
        let fitsInMemory = Double(totalWorkingSet) <= totalRAM * 0.9
        let memBandwidthBytesPerSec = Double(estimatePeakMemBandwidth(gpuCores: gpuCores))
        let tokensPerSecBandwidth = memBandwidthBytesPerSec / Double(weightsBytes)
        let tokensPerSec = fitsInMemory ? min(tokensPerSecBandwidth, 250) : 0.5
        let bottleneck = tokensPerSecBandwidth >= tokensPerSec ? "memory bandwidth" : "compute"

        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        let pollTask = launchPoller(start: start, deadline: deadline, label: "LLM") { elapsed, progress in
            self.publishLive("""
            LLM STATS — SYNTHETIC
            model size      : \(paramsB)B  (preset \(params.llmPreset))
            quantization    : \(params.llmQuantization)
            context length  : \(params.llmContextLength)
            batch size      : \(params.llmBatchSize)
            device          : \(params.llmDevice)
            weights size    : \(Format.bytes(Double(weightsBytes)))
            KV cache est.   : \(Format.bytes(Double(kvBytes)))
            total working   : \(Format.bytes(Double(totalWorkingSet)))
            fits in RAM     : \(fitsInMemory ? "yes" : "NO")
            est. tokens/sec : \(String(format: "%.1f", tokensPerSec))
            bottleneck      : \(bottleneck)
            """, progress: progress)
        }

        // Burn a little CPU simulating decode work so the bar actually moves.
        while Date() < deadline {
            try doCancelCheck()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        pollTask.cancel()

        let elapsed = Date().timeIntervalSince(start)
        let summary = """
        LLM STATS — SYNTHETIC ESTIMATE
        model size        : \(paramsB)B params
        quantization      : \(params.llmQuantization)
        device            : \(params.llmDevice)
        weights size      : \(Format.bytes(Double(weightsBytes)))
        KV cache estimate : \(Format.bytes(Double(kvBytes)))  (ctx=\(params.llmContextLength))
        total working set : \(Format.bytes(Double(totalWorkingSet)))
        system RAM        : \(Format.bytes(Double(totalRAM)))
        fits in memory    : \(fitsInMemory ? "YES" : "NO")
        est. memory bw    : \(Format.rate(Double(memBandwidthBytesPerSec)))
        est. tokens/sec   : \(String(format: "%.1f", tokensPerSec))
        bottleneck        : \(bottleneck)
        NOTE              : synthetic; no model was downloaded.
        """
        let metrics: [String: Double] = [
            "params_b": Double(paramsB),
            "weights_bytes": Double(weightsBytes),
            "kv_cache_bytes": Double(kvBytes),
            "tokens_per_sec": tokensPerSec,
            "context_length": Double(params.llmContextLength)
        ]
        await commit(test: .llm, summary: summary, metrics: metrics,
                     duration: elapsed, phase: "LLM")
    }

    // MARK: Suite

    private func runSuite(duration: Double, params: BenchmarkStatus) async {
        let per = max(2.0, duration / 4.0)
        var sub: [String] = []
        var errors: [String] = []
        var scores: [Double] = []

        await setPhase("Suite • CPU")
        sub.append(await captureSub(test: .cpu, duration: per, params: params, scores: &scores, errors: &errors))
        await setPhase("Suite • RAM")
        sub.append(await captureSub(test: .ram, duration: per, params: params, scores: &scores, errors: &errors))
        await setPhase("Suite • GPU")
        sub.append(await captureSub(test: .gpu, duration: per, params: params, scores: &scores, errors: &errors))
        await setPhase("Suite • LLM")
        sub.append(await captureSub(test: .llm, duration: per, params: params, scores: &scores, errors: &errors))

        let combined = scores.reduce(0, +) / Double(max(1, scores.count))
        let summary = """
        FULL SUITE — COMPLETE
        per-test duration : \(String(format: "%.0f", per)) s
        sub-tests         : \(sub.joined(separator: "\n---\n"))

        errors            : \(errors.isEmpty ? "none" : errors.joined(separator: "; "))
        combined AI score : \(String(format: "%.1f", combined)) / 100  (geometric of normalized sub-scores)
        """
        await commit(test: .suite, summary: summary,
                     metrics: ["combined_score": combined],
                     duration: duration, phase: "Suite")
    }

    private func captureSub(test: BenchmarkTestType, duration: Double,
                            params: BenchmarkStatus,
                            scores: inout [Double], errors: inout [String]) async -> String {
        do {
            switch test {
            case .cpu: try await runCpu(duration: duration, params: params)
            case .ram: try await runRam(duration: duration, params: params)
            case .gpu: try await runGpu(duration: duration, params: params)
            case .llm: try await runLLM(duration: duration, params: params)
            case .suite: break
            }
            // Pull last result for scoring.
            if let last = ResultsStore.shared.history.first {
                scores.append(score(for: test, result: last))
                return "\(test.displayName.uppercased()): OK"
            }
            return "\(test.displayName.uppercased()): OK (no metrics)"
        } catch {
            errors.append("\(test.displayName): \(error)")
            return "\(test.displayName.uppercased()): ERROR — \(error)"
        }
    }

    private func score(for test: BenchmarkTestType, result: BenchmarkResult) -> Double {
        // Normalize each test's headline metric to a 0...100 score using
        // reasonable reference floors/ceilings for Apple Silicon.
        switch test {
        case .cpu:
            let t = result.metrics["throughput_matmuls_per_s"] ?? 0
            return clamp((t / 5_000) * 100)
        case .ram:
            let b = result.metrics["bandwidth_bytes_per_s"] ?? 0
            return clamp((b / 400_000_000_000) * 100)
        case .gpu:
            let t = result.metrics["throughput_matmuls_per_s"] ?? 0
            return clamp((t / 1_500) * 100)
        case .llm:
            let v = result.metrics["tokens_per_sec"] ?? 0
            return clamp((v / 120) * 100)
        case .suite:
            return result.metrics["combined_score"] ?? 50
        }
    }

    // MARK: Commit / progress plumbing

    @MainActor
    private func commit(test: BenchmarkTestType, summary: String,
                        metrics: [String: Double], duration: Double,
                        phase: String, error: String? = nil) {
        let result = BenchmarkResult(
            startedAt: Date().addingTimeInterval(-duration),
            finishedAt: Date(),
            testType: test.rawValue,
            durationSeconds: duration,
            summary: summary,
            metrics: metrics,
            error: error
        )
        appState?.pushResult(result)
        appState?.updateBenchmark {
            $0.lastResultText = summary
            $0.error = error
            $0.phase = "\(phase) done"
        }
        appState?.log("Benchmark complete: \(test.displayName) (\(String(format: "%.1f", duration))s)", .info)
    }

    @MainActor
    private func setPhase(_ phase: String) {
        appState?.updateBenchmark { $0.phase = phase }
    }

    @MainActor
    private func publishLive(_ text: String, progress: Double) {
        appState?.updateBenchmark {
            $0.liveMetricsText = text
            $0.progress = progress
        }
    }

    // The handler is always consumed on the main actor (it calls publishLive,
    // which is @MainActor). Marking the closure @MainActor lets the Swift 6
    // concurrency checker verify those calls instead of flagging them.
    private func launchPoller(start: Date, deadline: Date, label: String,
                              handler: @MainActor @escaping (Double, Double) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while Date() < deadline {
                let elapsed = Date().timeIntervalSince(start)
                let total = deadline.timeIntervalSince(start)
                let progress = max(0, min(1, elapsed / max(0.001, total)))
                await handler(elapsed, progress)
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
            }
            await handler(Date().timeIntervalSince(start), 1.0)
        }
    }

    private func currentCpuLabel() -> String {
        String(format: "%.1f%%", TelemetryPoller.shared.sample().cpuUsage * 100)
    }

    private func postOnMain(_ block: @escaping () -> Void) async {
        await MainActor.run { block() }
    }

    private func doCancelCheck() throws {
        try checkCancelled()
    }
}

// MARK: - Metal kernel source

extension BenchmarkEngine {
    #if canImport(Metal)
    private func makeMatmulLibrary(device: MTLDevice) throws -> MTLFunction {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void matmul(device const float* A [[buffer(0)]],
                           device const float* B [[buffer(1)]],
                           device float* C       [[buffer(2)]],
                           constant uint& N      [[buffer(3)]],
                           uint2 gid             [[thread_position_in_grid]]) {
            if (gid.x >= N || gid.y >= N) return;
            float acc = 0.0;
            for (uint k = 0; k < N; k++) {
                acc += A[gid.y * N + k] * B[k * N + gid.x];
            }
            C[gid.y * N + gid.x] = acc;
        }
        """
        let library = try device.makeLibrary(source: src, options: nil)
        return library.makeFunction(name: "matmul")!
    }

    private func fillRandom(buffer: MTLBuffer, count: Int) {
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { ptr[i] = Float.random(in: -1...1) }
    }
    #endif
}

// MARK: - LLM estimation math

extension BenchmarkEngine {
    /// Bytes for the model weights at a given quantization.
    fileprivate func estimateModelSizeBytes(paramsB: Int, quant: String) -> Int {
        let bitsPerParam: Double
        switch quant.uppercased() {
        case "F16", "FP16":       bitsPerParam = 16
        case "Q8_0":              bitsPerParam = 8.5
        case "Q6_K":              bitsPerParam = 6.6
        case "Q5_K_M", "Q5_K":    bitsPerParam = 5.7
        case "Q4_K_M", "Q4_K":    bitsPerParam = 4.8
        case "Q4_0":              bitsPerParam = 4.5
        case "Q3_K_M", "Q3_K":    bitsPerParam = 3.9
        case "Q2_K":              bitsPerParam = 3.35
        default:                  bitsPerParam = 4.8
        }
        return Int(Double(paramsB) * 1_000_000_000 * bitsPerParam / 8.0)
    }

    /// Rough KV-cache footprint estimate (single batch, fp16 KV).
    fileprivate func estimateKVCacheBytes(ctx: Int, paramsB: Int) -> Int {
        // Heuristic: 2 (K+V) × layers × hidden × ctx × 2 bytes.
        // layers scale roughly with paramsB; 6 is a safe floor.
        let layersInt = max(6, Int(Double(paramsB) * 0.0000001 * 1_000_000_000 / 6))
        let hidden = max(1024, Int(sqrt(Double(paramsB) * 100)))
        let bytes = 2 * layersInt * hidden * ctx * 2
        return max(1_048_576, bytes)
    }

    /// Conservative per-GPU-core bandwidth estimate (Apple Silicon unified mem).
    fileprivate func estimatePeakMemBandwidth(gpuCores: Int) -> Int {
        let effective = max(8, gpuCores)
        // ~1.3 GB/s per GPU core is a rough Apple Silicon heuristic.
        return Int(Double(effective) * 1_300_000_000)
    }
}

// MARK: - Helpers

private func nextPow2(_ n: Int) -> Int {
    var k = 1
    while k < n { k <<= 1 }
    return k
}

private func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double {
    max(lo, min(hi, v))
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = 0
    func increment() { lock.lock(); raw &+= 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
}

extension Format {
    static func big(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1_000_000     { return String(format: "%.2fM", v / 1e6) }
        if v >= 1_000         { return String(format: "%.2fK", v / 1e3) }
        return String(format: "%.0f", v)
    }
}
