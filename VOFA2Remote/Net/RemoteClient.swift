//
//  RemoteClient.swift
//  VOFA2Remote
//
//  WebSocket control channel for the VOFA2 remote tuning server.
//

import Foundation

/// Connection state shown in the UI.
enum LinkState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int, delay: TimeInterval)
    case closed(reason: String, canRetry: Bool)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Something the view controller should react to.
enum RemoteEvent {
    case stateChanged(LinkState)
    case welcome(WelcomeInfo)
    case snapshot(RemoteSnapshot)
    case value(id: Int, value: Double, from: String?)
    case action(id: Int, kind: ActionItem.Kind, on: Bool, from: String?, flash: Bool)
    case oneClick(OneClickUpdate)
    case conn(ConnState)
    case clients(Int)
    case serverError(code: String, message: String)
    case terminated(code: Int, reason: String)
}

final class RemoteClient {

    // MARK: - Configuration

    /// Frames are merged above ~30 Hz per control, matching the PC side.
    private static let valueInterval: TimeInterval = 0.033
    /// Server drops a silent client after 45 s; we ping well inside that window.
    private static let pingInterval: TimeInterval = 20
    private static let silenceLimit: TimeInterval = 45
    private static let maxReconnectAttempts = 5
    private static let retryDelays: [TimeInterval] = [1, 2, 5, 5, 5]

    let host: String
    let port: Int
    let displayName: String
    private(set) var pin: String?

    private let clientId: String
    private let queue = DispatchQueue(label: "vofa.remote.client")
    private let session: URLSession

    var onEvent: ((RemoteEvent) -> Void)?

    // MARK: - State (touched on `queue` only)

    private var task: URLSessionWebSocketTask?
    private var state: LinkState = .idle
    private var welcome: WelcomeInfo?
    private var userClosed = false
    private var reconnectAttempt = 0
    private var lastInbound = Date()
    private var awaitingSnapshot = false
    private var syncDeadlineWork: DispatchWorkItem?

    private var pendingValues: [Int: Double] = [:]
    private var scheduledFlush: Set<Int> = []
    private var lastValueSent: [Int: Date] = [:]

    private var heartbeatTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

    // MARK: - Init

    init(host: String, port: Int, pin: String?, displayName: String, clientId: String) {
        self.host = host
        self.port = port
        self.pin = pin
        self.displayName = displayName
        self.clientId = clientId

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        heartbeatTimer?.cancel()
        watchdogTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    var currentState: LinkState {
        queue.sync { state }
    }

    var serverSession: Int? {
        queue.sync { welcome?.session }
    }

    // MARK: - Lifecycle

    func connect(withPin pin: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let pin = pin { self.pin = pin }
            self.userClosed = false
            self.reconnectAttempt = 0
            self.openSocket()
        }
    }

    func disconnect(notifyUser: Bool = false) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.userClosed = true
            self.syncDeadlineWork?.cancel()
            self.stopTimers()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.setState(notifyUser ? .closed(reason: "已断开连接", canRetry: true) : .idle)
        }
    }

    /// Reconnect manually after the automatic retries were exhausted.
    func retry() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.userClosed = false
            self.reconnectAttempt = 0
            self.openSocket()
        }
    }

    // MARK: - Socket

    private func openSocket() {
        guard let url = URL(string: "ws://\(host):\(port)/") else { return }
        syncDeadlineWork?.cancel()
        stopTimers()

        setState(reconnectAttempt > 0
                 ? .reconnecting(attempt: reconnectAttempt, delay: 0)
                 : .connecting)

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1 << 20
        task = socket
        lastInbound = Date()
        awaitingSnapshot = true
        socket.resume()

        // `hello` must arrive within 5 s of the handshake.
        send(OutboundMessage.hello(clientId: clientId, name: displayName, pin: pin))
        receiveLoop()
        startTimers()

        // If the server does not push a snapshot on its own, ask once.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.awaitingSnapshot, self.state.isConnected else { return }
            self.send(OutboundMessage.sync())
        }
        syncDeadlineWork = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func receiveLoop() {
        guard let socket = task else { return }
        socket.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard self.task === socket else { return }
                switch result {
                case .failure(let error):
                    self.handleDisconnect(error: error)
                case .success(let message):
                    self.lastInbound = Date()
                    switch message {
                    case .string(let text):
                        self.handle(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handle(text: text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    private func send(_ text: String) {
        guard let socket = task else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error = error else { return }
            self?.queue.async {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func handleDisconnect(error: Error?) {
        guard task != nil else { return }
        let closeCode = task?.closeCode.rawValue ?? 0
        let closeReason = task?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        syncDeadlineWork?.cancel()
        stopTimers()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        awaitingSnapshot = false
        pendingValues.removeAll()
        scheduledFlush.removeAll()
        lastValueSent.removeAll()

        if userClosed {
            setState(.closed(reason: "已断开连接", canRetry: true))
            return
        }

        switch closeCode {
        case 4001:
            setState(.closed(reason: "PC 端已断开这台设备", canRetry: false))
            emit(.terminated(code: 4001, reason: "PC 端已断开这台设备"))
        case 4003:
            setState(.closed(reason: "访问码错误", canRetry: true))
            emit(.terminated(code: 4003, reason: "访问码错误"))
        case 1011:
            scheduleReconnect(hint: "服务端发送积压，连接被关闭")
        default:
            let detail = closeReason.isEmpty
                ? (error?.localizedDescription ?? "连接中断")
                : closeReason
            scheduleReconnect(hint: detail)
        }
    }

    private func scheduleReconnect(hint: String) {
        reconnectAttempt += 1
        guard reconnectAttempt <= RemoteClient.maxReconnectAttempts else {
            setState(.closed(reason: "重连失败：\(hint)", canRetry: true))
            return
        }
        let delay = RemoteClient.retryDelays[min(reconnectAttempt - 1, RemoteClient.retryDelays.count - 1)]
        setState(.reconnecting(attempt: reconnectAttempt, delay: delay))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.userClosed else { return }
            self.openSocket()
        }
    }

    // MARK: - Timers

    private func startTimers() {
        heartbeatTimer?.cancel()
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(deadline: .now() + RemoteClient.pingInterval,
                           repeating: RemoteClient.pingInterval)
        heartbeat.setEventHandler { [weak self] in
            guard let self = self, self.state.isConnected else { return }
            self.send(OutboundMessage.ping())
        }
        heartbeat.resume()
        heartbeatTimer = heartbeat

        watchdogTimer?.cancel()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler { [weak self] in
            guard let self = self, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastInbound) > RemoteClient.silenceLimit {
                self.handleDisconnect(error: nil)
            }
        }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    private func stopTimers() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - Inbound

    private func handle(text: String) {
        guard let message = InboundMessage.parse(text: text) else { return }

        switch message {
        case .welcome(let info):
            welcome = info
            reconnectAttempt = 0
            setState(.connected)
            emit(.welcome(info))

        case .state(let snapshot):
            awaitingSnapshot = false
            syncDeadlineWork?.cancel()
            setState(.connected)
            emit(.snapshot(snapshot))

        case .value(let id, let value, let from):
            emit(.value(id: id, value: value, from: from))

        case .action(let id, let kind, let on, let from, let flash):
            emit(.action(id: id, kind: kind, on: on, from: from, flash: flash))

        case .oneClick(let update):
            emit(.oneClick(update))

        case .conn(let conn):
            emit(.conn(conn))

        case .clients(let count):
            emit(.clients(count))

        case .error(let code, let message):
            if code == "unknown_control" || code == "unknown_group" {
                send(OutboundMessage.sync())
            }
            emit(.serverError(code: code, message: message))

        case .pong:
            break

        case .unsupported(let type):
            emit(.serverError(code: "unsupported", message: "未知消息类型 \(type)"))
        }
    }

    // MARK: - Outbound API

    /// Live drag sample. Coalesced to one frame per 33 ms per control.
    func sendValue(id: Int, value: Double) {
        queue.async { [weak self] in
            guard let self = self, self.state.isConnected else { return }
            let now = Date()
            if let last = self.lastValueSent[id],
               now.timeIntervalSince(last) < RemoteClient.valueInterval {
                self.pendingValues[id] = value
                guard !self.scheduledFlush.contains(id) else { return }
                self.scheduledFlush.insert(id)
                let wait = RemoteClient.valueInterval - now.timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self = self else { return }
                    self.scheduledFlush.remove(id)
                    guard let pending = self.pendingValues.removeValue(forKey: id) else { return }
                    self.lastValueSent[id] = Date()
                    self.send(OutboundMessage.value(id: id, value: pending))
                }
                return
            }
            self.lastValueSent[id] = now
            self.send(OutboundMessage.value(id: id, value: value))
        }
    }

    /// Final value; always sent once, never coalesced away.
    func commit(id: Int, value: Double, exact: Bool) {
        queue.async { [weak self] in
            guard let self = self, self.state.isConnected else { return }
            self.pendingValues.removeValue(forKey: id)
            self.lastValueSent[id] = Date()
            self.send(OutboundMessage.commit(id: id, value: value, exact: exact))
        }
    }

    func setSwitch(id: Int, on: Bool) {
        queue.async { [weak self] in
            self?.send(OutboundMessage.action(id: id, on: on))
        }
    }

    func triggerButton(id: Int) {
        queue.async { [weak self] in
            self?.send(OutboundMessage.action(id: id, trigger: true))
        }
    }

    func startOneClick(group: String, intervalMs: Int? = nil) {
        queue.async { [weak self] in
            self?.send(OutboundMessage.oneClick(group: group, intervalMs: intervalMs))
        }
    }

    func stopOneClick() {
        queue.async { [weak self] in
            self?.send(OutboundMessage.oneClickStop())
        }
    }

    /// Writes 「参与一键发送数据」 back to the PC. Older servers answer
    /// `bad_request` ("未知消息类型"), which the UI turns into local-only mode.
    func setIncluded(id: Int, included: Bool) {
        queue.async { [weak self] in
            self?.send(OutboundMessage.inclusion(id: id, included: included))
        }
    }

    func requestSync() {
        queue.async { [weak self] in
            self?.send(OutboundMessage.sync())
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: LinkState) {
        guard newState != state else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: RemoteEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
