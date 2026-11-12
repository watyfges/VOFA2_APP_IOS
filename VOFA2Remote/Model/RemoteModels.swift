//
//  RemoteModels.swift
//  VOFA2Remote
//
//  Data model mirroring the VOFA2 remote tuning protocol (v1).
//

import Foundation

/// One server announced by a UDP discovery reply.
struct ServerOffer: Equatable {
    let name: String
    let host: String
    let port: Int
    let requiresPin: Bool
    let version: String
    let fallbackHosts: [String]

    var endpointText: String { "\(host):\(port)" }

    var websocketURL: URL? {
        URL(string: "ws://\(host):\(port)/")
    }
}

/// A slider in the PC command panel.
struct ControlItem: Equatable {
    let id: Int
    let label: String
    let group: String
    var value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let includedInOneClick: Bool
    let order: Int

    /// Clamps a value into the slider range, keeping NaN/infinite inputs out.
    func clamped(_ raw: Double) -> Double {
        guard raw.isFinite else { return value }
        let lower = Swift.min(minimum, maximum)
        let upper = Swift.max(minimum, maximum)
        if raw < lower { return lower }
        if raw > upper { return upper }
        return raw
    }

    /// Formats the value the way the PC spin box would, honouring the step size.
    func formatted(_ raw: Double) -> String {
        let decimals = ControlItem.decimals(forStep: step)
        return String(format: "%.\(decimals)f", raw)
    }

    static func decimals(forStep step: Double) -> Int {
        guard step.isFinite, step > 0, step < 1 else { return step >= 1 ? 0 : 2 }
        var decimals = 0
        var scaled = step
        while scaled < 1 && decimals < 6 {
            scaled *= 10
            decimals += 1
        }
        // Guard against binary float noise such as 0.010000000000000002.
        let rounded = (step * pow(10, Double(decimals))).rounded()
        if abs(rounded - step * pow(10, Double(decimals))) > 0.0001 && decimals > 0 {
            decimals -= 1
        }
        return decimals
    }
}

/// A button or switch in the PC command panel.
struct ActionItem: Equatable {
    enum Kind: Int {
        case button = 0
        case toggle = 1
    }

    let id: Int
    let label: String
    let group: String
    let kind: Kind
    var isOn: Bool
}

/// PC serial / TCP link state, read only.
struct ConnState: Equatable {
    var isConnected: Bool
    var text: String

    static let unknown = ConnState(isConnected: false, text: "")
}

/// PC 连接面板状态（协议 `state.link` / `link` 消息），手机据此开关 PC 的连接。
struct PCLinkState: Equatable {
    static let kindTitles = ["串口", "TCP 客户端", "TCP 服务端", "UDP", "演示"]

    var kind: Int = 0
    var isConnected: Bool = false
    var text: String = ""
    var ports: [String] = []
    var serialPort: String = ""
    var baud: Int = 115200
    var tcpHost: String = "127.0.0.1"
    var tcpClientPort: Int = 1346
    var tcpServerPort: Int = 1347
    var tcpClients: Int = 0
    var udpHost: String = "127.0.0.1"
    var udpRemotePort: Int = 1346
    var udpLocalPort: Int = 1347

    static let unknown = PCLinkState()

    var kindTitle: String {
        Self.kindTitles.indices.contains(kind) ? Self.kindTitles[kind] : "未知"
    }

    var statusText: String {
        guard isConnected else { return "未连接" }
        return text.isEmpty ? "已连接 · \(kindTitle)" : "已连接 · \(text)"
    }
}

/// One-click send progress.
struct OneClickState: Equatable {
    var isSending: Bool
    var sent: Int
    var total: Int
    var status: String
    var intervalMs: Int

    static let idle = OneClickState(isSending: false, sent: 0, total: 0, status: "", intervalMs: 100)

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Swift.min(1, Double(sent) / Double(total))
    }
}

/// Full `state` snapshot pushed by the server.
struct RemoteSnapshot: Equatable {
    var seq: Int
    var serverName: String
    var version: String
    var groups: [String]
    var pcGroup: String
    var controls: [ControlItem]
    var actions: [ActionItem]
    var conn: ConnState
    var link: PCLinkState
    var oneClick: OneClickState

    func controls(inGroup group: String) -> [ControlItem] {
        controls.filter { $0.group == group }.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }
    }

    func actions(inGroup group: String) -> [ActionItem] {
        actions.filter { $0.group == group }
    }

    func control(id: Int) -> ControlItem? { controls.first { $0.id == id } }
    func action(id: Int) -> ActionItem? { actions.first { $0.id == id } }
}

/// `welcome` reply.
struct WelcomeInfo: Equatable {
    var proto: Int
    var session: Int
    var serverName: String
    var version: String
    var requiresPin: Bool
    var maxClients: Int
}

/// One node of the `/` separated group hierarchy, used by the group picker.
struct GroupNode: Equatable {
    let path: String
    let title: String
    let depth: Int
    var children: [GroupNode]

    /// Builds a forest from flat paths such as `["默认", "底盘", "底盘/PID"]`.
    static func forest(from paths: [String]) -> [GroupNode] {
        var roots: [GroupNode] = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            insert(components: components, prefix: "", depth: 0, into: &roots, fullPath: path)
        }
        return roots
    }

    private static func insert(components: [String],
                               prefix: String,
                               depth: Int,
                               into nodes: inout [GroupNode],
                               fullPath: String) {
        guard let head = components.first else { return }
        let path = prefix.isEmpty ? head : prefix + "/" + head
        let index = nodes.firstIndex { $0.title == head }
        if let index = index {
            if components.count > 1 {
                var child = nodes[index]
                insert(components: Array(components.dropFirst()),
                       prefix: path,
                       depth: depth + 1,
                       into: &child.children,
                       fullPath: fullPath)
                nodes[index] = child
            }
        } else {
            var node = GroupNode(path: fullPath, title: head, depth: depth, children: [])
            if components.count > 1 {
                insert(components: Array(components.dropFirst()),
                       prefix: path,
                       depth: depth + 1,
                       into: &node.children,
                       fullPath: fullPath)
            }
            nodes.append(node)
        }
    }
}
