import Foundation
import Network
import Security

final class LocalHTTPServer {
    static let shared = LocalHTTPServer()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sullybase.localhttp")
    private let port: NWEndpoint.Port = NWEndpoint.Port(integerLiteral: 8765)

    private init() {}

    func start() {
        stop()

        // Attempt to load PKCS#12 identity from AppPaths.supportDir/server.p12 (password: changeit)
        let p12URL = AppPaths.supportDir.appendingPathComponent("server.p12")
        var useTLS = false
        var tlsOptions: NWProtocolTLS.Options? = nil

        if FileManager.default.fileExists(atPath: p12URL.path) {
            if let data = try? Data(contentsOf: p12URL) {
                let options: [String: Any] = [kSecImportExportPassphrase as String: "changeit"]
                var items: CFArray?
                let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
                if status == errSecSuccess, let arr = items as? [[String: Any]], let dict = arr.first {
                    // Extract identity from import result
                    if let raw = dict[kSecImportItemIdentity as String] {
                        // Create NW TLS options and set local identity
                        let tls = NWProtocolTLS.Options()
                        let identity = raw as! SecIdentity
                        let secIdentity = unsafeBitCast(identity, to: sec_identity_t.self)
                        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
                        tlsOptions = tls
                        useTLS = true
                        print("LocalHTTPServer: loaded TLS identity from \(p12URL.path)")
                    } else {
                        print("LocalHTTPServer: PKCS12 imported but identity missing")
                    }
                } else {
                    print("LocalHTTPServer: failed to import PKCS12: status=\(status)")
                }
            }
        } else {
            print("LocalHTTPServer: no PKCS12 found at \(p12URL.path)")
        }

        do {
            let params: NWParameters
            if useTLS, let tls = tlsOptions {
                let tcp = NWProtocolTCP.Options()
                params = NWParameters(tls: tls, tcp: tcp)
            } else {
                params = NWParameters.tcp
            }
            listener = try NWListener(using: params, on: port)
        } catch {
            print("LocalHTTPServer: failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { newState in
            print("LocalHTTPServer: state -> \(newState)")
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        listener?.start(queue: queue)
        print("LocalHTTPServer: listening on port \(port) (TLS: \(useTLS))")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveNext(on: conn, accumulated: Data())
    }

    private func receiveNext(on conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let err = error {
                print("LocalHTTPServer: connection error: \(err)")
                conn.cancel()
                return
            }
            var acc = accumulated
            if let d = data { acc.append(d) }

            if let str = String(data: acc, encoding: .utf8), let range = str.range(of: "\r\n\r\n") {
                // We have full headers (ignore body parsing for simplicity)
                let headerPart = String(str[..<range.upperBound])
                self.handleRequest(headerPart: headerPart, on: conn)
            } else if isComplete {
                // Try to handle whatever we have
                if let s = String(data: acc, encoding: .utf8) {
                    self.handleRequest(headerPart: s, on: conn)
                } else {
                    conn.cancel()
                }
            } else {
                // Need more data
                self.receiveNext(on: conn, accumulated: acc)
            }
        }
    }

    private func handleRequest(headerPart: String, on conn: NWConnection) {
        // Very small parser for the request line
        let lines = headerPart.split(separator: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let comps = requestLine.split(separator: " ")
        guard comps.count >= 2 else { conn.cancel(); return }
        let method = String(comps[0])
        let target = String(comps[1])

        // Parse path and query
        var path = target
        var query: String? = nil
        if let qidx = target.firstIndex(of: "?") {
            path = String(target[..<qidx])
            let qstart = target.index(after: qidx)
            query = String(target[qstart...])
        }

        if method == "GET" && path == "/api/stats" {
            let params = Self.parseQuery(query)
            let provided = params["key"] ?? ""
            if provided != RemoteShareManager.shared.key {
                sendSimpleResponse(conn: conn, status: 401, body: "Unauthorized")
                return
            }
            // Produce JSON from telemetry snapshot
            let snap = TelemetryPoller.shared.sample()
            let json = Self.jsonForSnapshot(snap)
            if let d = try? JSONSerialization.data(withJSONObject: json, options: []) {
                sendJSON(conn: conn, data: d)
            } else {
                sendSimpleResponse(conn: conn, status: 500, body: "Internal error")
            }
            return
        }

        // For other paths, respond with a tiny HTML landing that points to GitHub page.
        if method == "GET" && (path == "/" || path == "/index.html") {
            let body = "<html><body><p>Open the viewer at https://sullydux.github.io/System-Telemetry-Monitor/</p></body></html>"
            sendSimpleResponse(conn: conn, status: 200, body: body, contentType: "text/html")
            return
        }

        sendSimpleResponse(conn: conn, status: 404, body: "Not found")
    }

    private func sendJSON(conn: NWConnection, data: Data) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var out = Data(headers.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed({ _ in conn.cancel() }))
    }

    private func sendSimpleResponse(conn: NWConnection, status: Int, body: String, contentType: String = "text/plain") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\nContent-Type: \(contentType); charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var out = Data(headers.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed({ _ in conn.cancel() }))
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return ""
        }
    }

    private static func parseQuery(_ q: String?) -> [String: String] {
        guard let q = q else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let p = pair.split(separator: "=", maxSplits: 1).map { String($0) }
            if p.count == 2 {
                out[p[0]] = p[1].removingPercentEncoding ?? p[1]
            }
        }
        return out
    }

    private static func jsonForSnapshot(_ snap: TelemetrySnapshot) -> [String: Any] {
        var cpu: [String: Any] = [:]
        cpu["percent"] = Int((snap.cpuUsage * 100).rounded())
        cpu["core_count"] = snap.logicalCores
        cpu["physical_cores"] = snap.physicalCores
        cpu["per_core"] = snap.perCoreUsage.map { Double((($0 * 100).rounded())) }

        var ram: [String: Any] = [:]
        ram["percent"] = Int((snap.ramUsage * 100).rounded())
        ram["used_gb"] = Double(round(snap.ramUsedGB * 10) / 10)
        ram["total_gb"] = Double(round(snap.ramTotalGB * 10) / 10)
        ram["available_gb"] = max(0.0, Double(round((snap.ramTotalGB - snap.ramUsedGB) * 10) / 10))
        ram["wired_gb"] = Double(round(snap.ramWiredGB * 10) / 10)
        ram["compressed_gb"] = Double(round(snap.ramCompressedGB * 10) / 10)
        // Swap totals come from vm.swapusage (same sysctl the reference uses).
        ram["swap_used_gb"] = Double(round(snap.swapUsedGB * 10) / 10)
        ram["swap_total_gb"] = Double(round(snap.swapTotalGB * 10) / 10)

        var disk: [String: Any] = [:]
        let diskPercent = snap.diskTotalGB > 0 ? Int((snap.diskUsedGB / snap.diskTotalGB * 100).rounded()) : 0
        disk["percent"] = diskPercent
        disk["used_gb"] = Double(round(snap.diskUsedGB * 10) / 10)
        disk["total_gb"] = Double(round(snap.diskTotalGB * 10) / 10)
        disk["free_gb"] = max(0.0, Double(round((snap.diskTotalGB - snap.diskUsedGB) * 10) / 10))
        // Bytes/sec → MiB/s (1,048,576). The HTML reads disk.io.read_mbps/write_mbps.
        var io: [String: Any] = [:]
        io["read_mbps"] = Double(round(snap.diskReadBytesPerSec / 1_048_576.0 * 10) / 10)
        io["write_mbps"] = Double(round(snap.diskWriteBytesPerSec / 1_048_576.0 * 10) / 10)
        disk["io"] = io

        var gpuArr: [[String: Any]] = []
        var g: [String: Any] = ["name": snap.gpu.name, "core_count": snap.gpu.coreCount]
        if let load = snap.gpu.load { g["load_percent"] = Int((load * 100).rounded()) }
        gpuArr.append(g)

        // Network throughput is sampled as a rate (bytes/sec) from getifaddrs
        // deltas — there are no cumulative totals in the snapshot, so we don't
        // fabricate them. The HTML headline uses up_kbps/down_kbps.
        var net: [String: Any] = [:]
        net["up_kbps"] = Int((snap.netOutBytesPerSec / 1024).rounded())
        net["down_kbps"] = Int((snap.netInBytesPerSec / 1024).rounded())
        net["up_mbps"] = Double(round(snap.netOutBytesPerSec / 1_048_576.0 * 10) / 10)
        net["down_mbps"] = Double(round(snap.netInBytesPerSec / 1_048_576.0 * 10) / 10)

        var battery: [String: Any] = [:]
        battery["percent"] = snap.battery.chargeFraction.map { Int(($0 * 100).rounded()) } ?? NSNull()
        battery["plugged_in"] = snap.battery.pluggedIn
        battery["minutes_remaining"] = snap.battery.timeRemaining

        var sys: [String: Any] = [:]
        sys["os"] = snap.osVersion
        sys["os_version"] = snap.osBuild
        sys["arch"] = snap.chipName
        sys["current_user"] = NSUserName()
        sys["process_count"] = 0
        sys["apple_silicon"] = snap.chipName.lowercased().contains("apple")

        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)

        var out: [String: Any] = [:]
        out["device_name"] = snap.modelName
        out["hostname"] = snap.hostname
        out["timestamp"] = timestampMs
        out["uptime_seconds"] = Int(Date().timeIntervalSince(snap.bootTime))
        out["cpu"] = cpu
        out["ram"] = ram
        out["disk"] = disk
        out["gpu"] = gpuArr
        out["network"] = net
        out["battery"] = battery
        out["system"] = sys
        out["top_processes"] = []
        out["ollama"] = ["running": false, "loaded_models": []]
        out["stress_test"] = ["running": false]
        return out
    }
}
