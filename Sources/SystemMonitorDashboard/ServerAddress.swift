import Foundation
import AppKit

// Provides a best-effort local server address and helper to copy it to the pasteboard.
final class ServerAddressManager: ObservableObject {
    static let shared = ServerAddressManager()
    @Published var address: String = "https://127.0.0.1:8765"
    let port: Int = 8765

    private init() {
        updateAddress()
    }

    func updateAddress() {
        if let ip = Self.getLocalIPAddress() {
            address = "https://\(ip):\(port)"
        } else {
            address = "https://127.0.0.1:\(port)"
        }
    }

    static func getLocalIPAddress() -> String? {
        // Use getifaddrs to find the first non-loopback IPv4 address (e.g. the Wi-Fi address).
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                guard let ifa = ptr?.pointee else { break }
                let sa = ifa.ifa_addr.pointee
                if sa.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    // skip loopback
                    if name == "lo0" { ptr = ifa.ifa_next; continue }
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifa.ifa_addr, socklen_t(sa.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    address = ip
                    break
                }
                ptr = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    func copyServerAddressToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }
}
