//
//  RemoteClientTests.swift
//  VOFA2RemoteTests
//
//  End-to-end checks against ios/tools/mock_remote_server.py.
//  Start it first:  python3 ios/tools/mock_remote_server.py
//

import XCTest
@testable import VOFA2Remote

final class RemoteClientTests: XCTestCase {

    private let host = "127.0.0.1"
    private var port: Int {
        Int(ProcessInfo.processInfo.environment["VOFA_MOCK_PORT"] ?? "") ?? 47900
    }

    private func mockServerReachable(on targetPort: Int? = nil) -> Bool {
        let targetPort = targetPort ?? port
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(targetPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func makeClient() -> RemoteClient {
        RemoteClient(host: host, port: port, pin: nil,
                     displayName: "XCTest", clientId: "ios-xctest")
    }

    // MARK: - Handshake

    func testHandshakeDeliversWelcomeAndSnapshot() throws {
        try XCTSkipUnless(mockServerReachable(), "mock server not running on 127.0.0.1:\(port)")

        let client = makeClient()
        let welcome = expectation(description: "welcome")
        let snapshot = expectation(description: "snapshot")
        let connected = expectation(description: "connected")
        var captured: RemoteSnapshot?

        client.onEvent = { event in
            switch event {
            case .welcome(let info):
                XCTAssertFalse(info.serverName.isEmpty)
                XCTAssertGreaterThan(info.session, 0)
                welcome.fulfill()
            case .snapshot(let value):
                captured = value
                snapshot.fulfill()
            case .stateChanged(let state):
                if state.isConnected { connected.fulfill() }
            default:
                break
            }
        }

        client.connect()
        wait(for: [welcome, snapshot, connected], timeout: 10)
        client.disconnect()

        let snapshotValue = try XCTUnwrap(captured)
        XCTAssertFalse(snapshotValue.groups.isEmpty)
        XCTAssertFalse(snapshotValue.controls.isEmpty, "mock server should provide sliders")
        XCTAssertEqual(snapshotValue.controls.first?.group.isEmpty, false)
        XCTAssertTrue(snapshotValue.controls(inGroup: "底盘/PID").count >= 2)
    }

    // MARK: - Control round trip

    func testValueCommitSwitchButtonAndOneClick() throws {
        try XCTSkipUnless(mockServerReachable(), "mock server not running on 127.0.0.1:\(port)")

        let client = makeClient()
        var echoedValue: Double?
        var echoedSwitch: Bool?
        var sawFlash = false
        var oneClickPhases: [OneClickUpdate.Phase] = []
        var gotValueEcho = false
        var gotSwitchEcho = false

        let valueEcho = expectation(description: "value echo")
        let switchEcho = expectation(description: "switch echo")
        let flashEcho = expectation(description: "button flash")
        let sendDone = expectation(description: "oneclick done")

        client.onEvent = { event in
            switch event {
            case .value(let id, let value, let from):
                if id == 1000, from?.hasPrefix("c") == true,
                   abs(value - 4.5) < 0.001, !gotValueEcho {
                    gotValueEcho = true
                    echoedValue = value
                    valueEcho.fulfill()
                }
            case .action(_, let kind, let on, _, let flash):
                if kind == .toggle, !gotSwitchEcho {
                    gotSwitchEcho = true
                    echoedSwitch = on
                    switchEcho.fulfill()
                }
                if kind == .button, flash, !sawFlash {
                    sawFlash = true
                    flashEcho.fulfill()
                }
            case .oneClick(let update):
                oneClickPhases.append(update.phase)
                if update.phase == .done { sendDone.fulfill() }
            default:
                break
            }
        }

        client.connect()

        // Give the server a moment to finish the handshake before writing.
        let handshake = expectation(description: "connected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { handshake.fulfill() }
        wait(for: [handshake], timeout: 6)

        client.sendValue(id: 1000, value: 3.25)
        client.commit(id: 1000, value: 4.5, exact: false)
        client.setSwitch(id: 4, on: false)
        client.triggerButton(id: 3)

        wait(for: [valueEcho, switchEcho, flashEcho], timeout: 8)
        XCTAssertEqual(echoedValue ?? -1, 4.5, accuracy: 0.001, "commit echo should win over the drag sample")
        XCTAssertEqual(echoedSwitch, false)
        XCTAssertTrue(sawFlash)

        client.startOneClick(group: "底盘/PID", intervalMs: 20)
        wait(for: [sendDone], timeout: 15)
        XCTAssertTrue(oneClickPhases.contains(.start))
        XCTAssertTrue(oneClickPhases.contains(.step))
        XCTAssertEqual(oneClickPhases.last, .done)

        client.disconnect()
    }

    // MARK: - Access code

    private let pinPort = 47910

    func testWrongPinIsRejectedWith4003() throws {
        try XCTSkipUnless(mockServerReachable(on: pinPort),
                          "pin mock server not running on 127.0.0.1:\(pinPort)")

        let client = RemoteClient(host: host, port: pinPort, pin: "0000",
                                  displayName: "XCTest", clientId: "ios-xctest-pin")
        let rejected = expectation(description: "terminated 4003")
        let closed = expectation(description: "closed state")
        rejected.assertForOverFulfill = false
        closed.assertForOverFulfill = false

        client.onEvent = { event in
            if case .terminated(let code, _) = event {
                XCTAssertEqual(code, 4003)
                rejected.fulfill()
            }
            if case .stateChanged(let state) = event {
                if case .closed(_, let canRetry) = state {
                    XCTAssertTrue(canRetry, "a bad PIN should allow a retry")
                    closed.fulfill()
                }
            }
        }

        client.connect()
        wait(for: [rejected, closed], timeout: 10)
    }

    func testCorrectPinConnects() throws {
        try XCTSkipUnless(mockServerReachable(on: pinPort),
                          "pin mock server not running on 127.0.0.1:\(pinPort)")

        let client = RemoteClient(host: host, port: pinPort, pin: "1234",
                                  displayName: "XCTest", clientId: "ios-xctest-pin")
        let welcome = expectation(description: "welcome")
        let snapshot = expectation(description: "snapshot")

        client.onEvent = { event in
            if case .welcome(let info) = event {
                XCTAssertTrue(info.requiresPin)
                welcome.fulfill()
            }
            if case .snapshot = event {
                snapshot.fulfill()
            }
        }

        client.connect()
        wait(for: [welcome, snapshot], timeout: 10)
        client.disconnect()
    }

    // MARK: - Discovery
    func testDiscoveryFindsMockServer() throws {
        try XCTSkipUnless(mockServerReachable(), "mock server not running on 127.0.0.1:\(port)")

        let discovery = DiscoveryService()
        let found = expectation(description: "offer received")
        found.assertForOverFulfill = false
        var offers: [ServerOffer] = []

        discovery.onServersChanged = { list in
            if !list.isEmpty {
                offers = list
                found.fulfill()
            }
        }
        discovery.start()
        discovery.refresh()

        wait(for: [found], timeout: 12)
        discovery.stop()

        XCTAssertFalse(offers.isEmpty)
        XCTAssertTrue(offers.contains { $0.port == port })
        XCTAssertTrue(offers.allSatisfy { !$0.name.isEmpty })
    }
}
