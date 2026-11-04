//
//  DiscoveryService.swift
//  VOFA2Remote
//
//  LAN discovery for VOFA2 remote tuning servers.
//
//  Sends `{"t":"discover","proto":1}` to UDP 47901 three times (300 ms apart) on
//  the global broadcast address plus every interface's directed broadcast
//  address, then collects the unicast `offer` replies.
//

import Foundation

final class DiscoveryService {

    /// Port the PC side always listens on for probes (fixed by the protocol).
    static let discoveryPort: UInt16 = 47901

    private struct SeenEntry {
        var offer: ServerOffer
        var lastSeen: Date
    }

    private let queue = DispatchQueue(label: "vofa.discovery")
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var probeTimer: DispatchSourceTimer?
    private var probesLeft = 0
    private var seen: [String: SeenEntry] = [:]
    private var started = false

    /// Called on the main queue whenever the visible server list changes.
    var onServersChanged: (([ServerOffer]) -> Void)?
    /// Called on the main queue with a user facing hint (permission problems, etc.).
    var onHint: ((String) -> Void)?

    private(set) var servers: [ServerOffer] = []

    deinit {
        closeSocket()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in
            self?.openSocket()
            self?.beginProbing()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        probeTimer?.cancel()
        probeTimer = nil
        queue.async { [weak self] in
            self?.closeSocket()
        }
    }

    /// Clears the list and probes again.
    func refresh() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.seen.removeAll()
            self.publish()
            self.beginProbing()
        }
    }

    // MARK: - Socket

    private func openSocket() {
        guard socketFD < 0 else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            notifyHint("无法创建 UDP 套接字，请确认已允许「本地网络」访问")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            notifyHint("UDP 端口绑定失败，请检查「本地网络」权限")
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        socketFD = fd
        observeReads(on: fd)
    }

    private func closeSocket() {
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func observeReads(on fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainReplies()
        }
        source.setCancelHandler { [weak self] in
            guard let self = self, self.socketFD >= 0 else { return }
            Darwin.close(self.socketFD)
            self.socketFD = -1
        }
        source.resume()
        readSource = source
    }

    // MARK: - Probing

    private func beginProbing() {
        guard socketFD >= 0 else { return }
        probesLeft = 3
        sendProbe()

        probeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.probesLeft > 0 else {
                self.probeTimer?.cancel()
                self.probeTimer = nil
                return
            }
            self.sendProbe()
        }
        timer.resume()
        probeTimer = timer
    }

    private func sendProbe() {
        guard probesLeft > 0, socketFD >= 0 else { return }
        probesLeft -= 1

        let payload = Array(#"{"t":"discover","proto":1}"#.utf8)
        for target in DiscoveryService.broadcastTargets() {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = DiscoveryService.discoveryPort.bigEndian
            address.sin_addr.s_addr = target

            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer -> Int in
                    payload.withUnsafeBytes { buffer -> Int in
                        sendto(socketFD,
                               buffer.baseAddress,
                               buffer.count,
                               0,
                               sockaddrPointer,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// Every IPv4 broadcast address worth poking: the limited broadcast plus one
    /// directed broadcast per active, non-loopback interface.
    static func broadcastTargets() -> [in_addr_t] {
        var targets: Set<in_addr_t> = [in_addr_t(0xFFFF_FFFF).bigEndian]

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return Array(targets)
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let sockaddrPointer = entry.pointee.ifa_addr,
                  sockaddrPointer.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0 else { continue }

            let address = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UInt32(bigEndian: address.sin_addr.s_addr)

            var mask: UInt32 = 0xFFFF_FFFF
            if let netmaskPointer = entry.pointee.ifa_netmask,
               netmaskPointer.pointee.sa_family == UInt8(AF_INET) {
                let netmask = netmaskPointer
                    .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    .sin_addr.s_addr
                mask = UInt32(bigEndian: netmask)
            }
            // A /32 (or missing mask) has no usable directed broadcast.
            guard mask != 0xFFFF_FFFF else { continue }
            let broadcast = (ip & mask) | ~mask
            targets.insert(in_addr_t(broadcast).bigEndian)
        }
        return Array(targets)
    }

    // MARK: - Replies

    private func drainReplies() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var changed = false

        while true {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &sender) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(socketFD, &buffer, buffer.count, 0, sockaddrPointer, &senderLength)
                }
            }
            if received <= 0 { break }

            let data = Data(buffer[0..<received])
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (object["t"] as? String) == "offer",
                  let port = object["port"] as? Int else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var rawAddress = sender.sin_addr
            guard inet_ntop(AF_INET, &rawAddress, &hostBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: hostBuffer)

            let fallbackHosts = (object["ips"] as? [Any])?.compactMap { $0 as? String } ?? []
            let offer = ServerOffer(
                name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host,
                host: host,
                port: port,
                requiresPin: (object["pin"] as? Bool) ?? ((object["pin"] as? Int) ?? 0 != 0),
                version: (object["version"] as? String) ?? "",
                fallbackHosts: fallbackHosts.filter { $0 != host }
            )

            let key = "\(host):\(port)"
            seen[key] = SeenEntry(offer: offer, lastSeen: Date())
            changed = true
        }

        if changed { publish() }
    }

    private func publish() {
        let cutoff = Date().addingTimeInterval(-30)
        var kept: [String: SeenEntry] = [:]
        for (key, entry) in seen where entry.lastSeen > cutoff {
            kept[key] = entry
        }
        seen = kept

        let offers: [ServerOffer] = kept.values.map { entry -> ServerOffer in entry.offer }
        let list: [ServerOffer] = offers.sorted { (lhs: ServerOffer, rhs: ServerOffer) -> Bool in
            if lhs.name == rhs.name {
                return lhs.host < rhs.host
            }
            return lhs.name < rhs.name
        }
        servers = list
        DispatchQueue.main.async { [weak self] in
            self?.onServersChanged?(list)
        }
    }

    private func notifyHint(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onHint?(text)
        }
    }
}
