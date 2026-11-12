//
//  RemoteMessage.swift
//  VOFA2Remote
//
//  Parsing of inbound server messages and building of outbound client messages.
//

import Foundation

// MARK: - JSON helpers

private extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? { self[key] as? String }
    func num(_ key: String) -> Double? {
        guard let value = self[key] else { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
    func integer(_ key: String) -> Int? {
        guard let value = self[key] else { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double, double.rounded() == double { return Int(double) }
        return nil
    }
    func boolean(_ key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        return nil
    }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func list(_ key: String) -> [Any]? { self[key] as? [Any] }
}

// MARK: - Inbound

/// Progress update pushed by `{"t":"oneclick"}`.
struct OneClickUpdate: Equatable {
    enum Phase: String {
        case start, step, done, cancel, idle

        /// Phases after which the send button becomes usable again.
        var isTerminal: Bool {
            switch self {
            case .done, .cancel, .idle: return true
            case .start, .step: return false
            }
        }
    }

    var phase: Phase
    var sent: Int
    var total: Int
    var status: String
}

/// A parsed server frame.
enum InboundMessage {
    case welcome(WelcomeInfo)
    case state(RemoteSnapshot)
    case value(id: Int, value: Double, from: String?)
    case action(id: Int, kind: ActionItem.Kind, on: Bool, from: String?, flash: Bool)
    case oneClick(OneClickUpdate)
    case conn(ConnState)
    case link(PCLinkState)
    case clients(Int)
    case error(code: String, message: String)
    case pong
    case unsupported(type: String)

    /// Returns `nil` when the payload is not valid JSON or has no `t` field.
    static func parse(text: String) -> InboundMessage? {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let type = object.str("t") else {
            return nil
        }

        switch type {
        case "welcome":
            let info = WelcomeInfo(
                proto: object.integer("proto") ?? 1,
                session: object.integer("session") ?? 0,
                serverName: object.str("name") ?? "VOFA2",
                version: object.str("version") ?? "",
                requiresPin: object.boolean("pin") ?? false,
                maxClients: object.integer("maxClients") ?? 16
            )
            return .welcome(info)

        case "state":
            return .state(SnapshotParser.parse(object))

        case "value":
            guard let id = object.integer("id"), let value = object.num("v") else { return nil }
            return .value(id: id, value: value, from: object.str("from"))

        case "action":
            guard let id = object.integer("id") else { return nil }
            let kind = ActionItem.Kind(rawValue: object.integer("kind") ?? 0) ?? .button
            return .action(id: id,
                           kind: kind,
                           on: object.boolean("on") ?? false,
                           from: object.str("from"),
                           flash: object.boolean("flash") ?? false)

        case "oneclick":
            let phase = OneClickUpdate.Phase(rawValue: object.str("phase") ?? "") ?? .step
            return .oneClick(OneClickUpdate(phase: phase,
                                            sent: object.integer("sent") ?? 0,
                                            total: object.integer("total") ?? 0,
                                            status: object.str("status") ?? ""))

        case "conn":
            return .conn(ConnState(isConnected: object.boolean("connected") ?? false,
                                   text: object.str("state") ?? ""))

        case "link":
            return .link(LinkStateParser.parse(object))

        case "clients":
            return .clients(object.integer("count") ?? 0)

        case "error":
            return .error(code: object.str("code") ?? "unknown",
                          message: object.str("message") ?? "")

        case "pong":
            return .pong

        default:
            return .unsupported(type: type)
        }
    }
}

/// `state.link` 与 `{"t":"link"}` 共用同一套字段。
private enum LinkStateParser {
    static func parse(_ object: [String: Any]) -> PCLinkState {
        var state = PCLinkState()
        state.kind = object.integer("kind") ?? 0
        state.isConnected = object.boolean("connected") ?? false
        state.text = object.str("state") ?? ""
        state.ports = (object.list("ports") ?? []).compactMap { $0 as? String }
        state.serialPort = object.str("serialPort") ?? ""
        state.baud = object.integer("baud") ?? 115200
        state.tcpHost = object.str("tcpHost") ?? "127.0.0.1"
        state.tcpClientPort = object.integer("tcpClientPort") ?? 1346
        state.tcpServerPort = object.integer("tcpServerPort") ?? 1347
        state.tcpClients = object.integer("tcpClients") ?? 0
        state.udpHost = object.str("udpHost") ?? "127.0.0.1"
        state.udpRemotePort = object.integer("udpRemotePort") ?? 1346
        state.udpLocalPort = object.integer("udpLocalPort") ?? 1347
        return state
    }
}

private enum SnapshotParser {    static func parse(_ object: [String: Any]) -> RemoteSnapshot {
        let groups = (object.list("groups") ?? []).compactMap { $0 as? String }

        let controls: [ControlItem] = (object.list("controls") ?? []).compactMap { element in
            guard let item = element as? [String: Any],
                  let id = item.integer("id") else { return nil }
            return ControlItem(
                id: id,
                label: item.str("label") ?? "#\(id)",
                group: item.str("group") ?? "",
                value: item.num("v") ?? 0,
                minimum: item.num("min") ?? 0,
                maximum: item.num("max") ?? 1,
                step: item.num("step") ?? 0.01,
                includedInOneClick: item.boolean("inc") ?? false,
                order: item.integer("order") ?? 0
            )
        }

        let actions: [ActionItem] = (object.list("actions") ?? []).compactMap { element in
            guard let item = element as? [String: Any],
                  let id = item.integer("id") else { return nil }
            return ActionItem(
                id: id,
                label: item.str("label") ?? "#\(id)",
                group: item.str("group") ?? "",
                kind: ActionItem.Kind(rawValue: item.integer("kind") ?? 0) ?? .button,
                isOn: item.boolean("on") ?? false
            )
        }

        let connObject = object.object("conn")
        let conn = ConnState(isConnected: connObject?.boolean("connected") ?? false,
                             text: connObject?.str("state") ?? "")
        let link = object.object("link").map(LinkStateParser.parse) ?? .unknown

        let oneClickObject = object.object("oneclick")
        var oneClick = OneClickState.idle
        if let oneClickObject = oneClickObject {
            oneClick.isSending = oneClickObject.boolean("sending") ?? false
            oneClick.sent = oneClickObject.integer("sent") ?? 0
            oneClick.total = oneClickObject.integer("total") ?? 0
            oneClick.status = oneClickObject.str("status") ?? ""
            oneClick.intervalMs = oneClickObject.integer("interval") ?? 100
        }

        return RemoteSnapshot(
            seq: object.integer("seq") ?? 0,
            serverName: object.str("server") ?? "",
            version: object.str("version") ?? "",
            groups: groups,
            pcGroup: object.str("pcGroup") ?? "",
            controls: controls,
            actions: actions,
            conn: conn,
            link: link,
            oneClick: oneClick
        )
    }
}

// MARK: - Outbound

/// Builds the compact JSON frames the server expects.
enum OutboundMessage {
    static func hello(proto: Int = 1, clientId: String, name: String, pin: String?) -> String {
        var payload: [String: Any] = ["t": "hello", "proto": proto]
        payload["clientId"] = clientId
        payload["name"] = name
        if let pin = pin, !pin.isEmpty {
            payload["pin"] = pin
        }
        return encode(payload)
    }

    /// Live drag sample; may be dropped by the throttle.
    static func value(id: Int, value: Double) -> String {
        encode(["t": "value", "id": id, "v": sanitized(value)])
    }

    /// Final value on release or typed entry. `exact` skips the min/max clamp.
    static func commit(id: Int, value: Double, exact: Bool) -> String {
        var payload: [String: Any] = ["t": "commit", "id": id, "v": sanitized(value)]
        if exact { payload["exact"] = true }
        return encode(payload)
    }

    /// Switches are set to a target state, never toggled blindly.
    static func action(id: Int, on: Bool) -> String {
        encode(["t": "action", "id": id, "on": on])
    }

    static func action(id: Int, trigger: Bool) -> String {
        encode(["t": "action", "id": id, "trigger": trigger])
    }

    static func oneClick(group: String, intervalMs: Int?) -> String {
        var payload: [String: Any] = ["t": "oneclick", "group": group]
        if let intervalMs = intervalMs { payload["intervalMs"] = intervalMs }
        return encode(payload)
    }

    static func oneClickStop() -> String {
        encode(["t": "oneclick.stop"])
    }

    /// Toggles 「参与一键发送数据」 on the PC (`controls[].inc`).
    static func inclusion(id: Int, included: Bool) -> String {
        encode(["t": "inc", "id": id, "inc": included])
    }

    /// 打开 PC 连接。`kind`: 0 串口 / 1 TCP 客户端 / 2 TCP 服务端 / 3 UDP / 4 演示。
    static func linkOpen(kind: Int,
                         port: String? = nil,
                         baud: Int? = nil,
                         host: String? = nil,
                         tcpPort: Int? = nil,
                         remotePort: Int? = nil,
                         localPort: Int? = nil) -> String {
        var payload: [String: Any] = ["t": "link", "cmd": "open", "kind": kind]
        if let port = port, !port.isEmpty { payload["port"] = port }
        if let baud = baud, baud > 0 { payload["baud"] = baud }
        if let host = host, !host.isEmpty { payload["host"] = host }
        if let tcpPort = tcpPort, tcpPort > 0 { payload["port"] = tcpPort }
        if let remotePort = remotePort, remotePort > 0 { payload["remotePort"] = remotePort }
        if let localPort = localPort, localPort > 0 { payload["localPort"] = localPort }
        return encode(payload)
    }

    static func linkClose() -> String {
        encode(["t": "link", "cmd": "close"])
    }

    static func linkRefresh() -> String {
        encode(["t": "link", "cmd": "refresh"])
    }

    static func sync() -> String { "{\"t\":\"sync\"}" }
    static func ping() -> String { "{\"t\":\"ping\"}" }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    static func encode(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
