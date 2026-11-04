//
//  ProtocolTests.swift
//  VOFA2RemoteTests
//
//  Pure parsing / encoding checks against the samples in 协议手册.md.
//

import XCTest
@testable import VOFA2Remote

final class ProtocolTests: XCTestCase {

    func testParsesFullStateSnapshot() throws {
        let text = """
        {"t":"state","proto":1,"seq":12,"server":"调试台","version":"0.1.0",
         "groups":["默认","底盘","底盘/PID"],"pcGroup":"默认",
         "controls":[
           {"id":1000,"label":"kp","group":"默认","v":1.5,"min":0,"max":10,"step":0.01,"inc":true,"order":1},
           {"id":2000,"label":"ii","group":"底盘/PID","v":2,"min":0,"max":5,"step":0.001,"inc":false,"order":2}
         ],
         "actions":[
           {"id":3,"label":"启动","group":"默认","kind":0,"on":false},
           {"id":4,"label":"闭环","group":"默认","kind":1,"on":true}
         ],
         "conn":{"connected":true,"state":"已连接"},
         "oneclick":{"sending":false,"sent":0,"total":0,"status":"","interval":100}}
        """

        guard case .state(let snapshot)? = InboundMessage.parse(text: text) else {
            return XCTFail("state not parsed")
        }

        XCTAssertEqual(snapshot.seq, 12)
        XCTAssertEqual(snapshot.serverName, "调试台")
        XCTAssertEqual(snapshot.groups, ["默认", "底盘", "底盘/PID"])
        XCTAssertEqual(snapshot.pcGroup, "默认")
        XCTAssertEqual(snapshot.controls.count, 2)
        XCTAssertEqual(snapshot.controls[0].id, 1000)
        XCTAssertEqual(snapshot.controls[0].value, 1.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.controls[0].maximum, 10)
        XCTAssertTrue(snapshot.controls[0].includedInOneClick)
        XCTAssertFalse(snapshot.controls[1].includedInOneClick)
        XCTAssertEqual(snapshot.actions.count, 2)
        XCTAssertEqual(snapshot.actions[1].kind, .toggle)
        XCTAssertTrue(snapshot.actions[1].isOn)
        XCTAssertTrue(snapshot.conn.isConnected)
        XCTAssertEqual(snapshot.oneClick.intervalMs, 100)
    }

    func testFiltersControlsByExactGroupAndOrder() throws {
        let text = """
        {"t":"state","seq":1,"server":"s","groups":["A","A/B"],
         "controls":[
           {"id":2,"label":"b","group":"A","v":0,"min":0,"max":1,"step":0.1,"inc":true,"order":5},
           {"id":1,"label":"a","group":"A","v":0,"min":0,"max":1,"step":0.1,"inc":true,"order":1},
           {"id":3,"label":"nested","group":"A/B","v":0,"min":0,"max":1,"step":0.1,"inc":true,"order":0}
         ],
         "actions":[]}
        """
        guard case .state(let snapshot)? = InboundMessage.parse(text: text) else {
            return XCTFail("state not parsed")
        }
        XCTAssertEqual(snapshot.controls(inGroup: "A").map { $0.id }, [1, 2])
        XCTAssertEqual(snapshot.controls(inGroup: "A/B").map { $0.id }, [3])
        XCTAssertTrue(snapshot.controls(inGroup: "A/").isEmpty)
    }

    func testParsesIncrementalMessages() {
        guard case .value(let id, let value, let from)? =
                InboundMessage.parse(text: #"{"t":"value","id":1000,"v":1.5,"from":"pc"}"#) else {
            return XCTFail("value not parsed")
        }
        XCTAssertEqual(id, 1000)
        XCTAssertEqual(value, 1.5, accuracy: 0.0001)
        XCTAssertEqual(from, "pc")

        guard case .action(let actionID, let kind, let on, let source, let flash)? =
                InboundMessage.parse(text: #"{"t":"action","id":5,"kind":0,"on":false,"from":"pc","flash":true}"#) else {
            return XCTFail("action not parsed")
        }
        XCTAssertEqual(actionID, 5)
        XCTAssertEqual(kind, .button)
        XCTAssertFalse(on)
        XCTAssertEqual(source, "pc")
        XCTAssertTrue(flash)

        guard case .oneClick(let update)? =
                InboundMessage.parse(text: #"{"t":"oneclick","phase":"step","sent":2,"total":5,"status":"已发送 2/5: kp"}"#) else {
            return XCTFail("oneclick not parsed")
        }
        XCTAssertEqual(update.phase, .step)
        XCTAssertFalse(update.phase.isTerminal)
        XCTAssertTrue(OneClickUpdate.Phase.done.isTerminal)
        XCTAssertTrue(OneClickUpdate.Phase.cancel.isTerminal)
        XCTAssertTrue(OneClickUpdate.Phase.idle.isTerminal)

        guard case .error(let code, _)? =
                InboundMessage.parse(text: #"{"t":"error","code":"unknown_control","message":"控件不存在"}"#) else {
            return XCTFail("error not parsed")
        }
        XCTAssertEqual(code, "unknown_control")

        guard case .clients(let count)? = InboundMessage.parse(text: #"{"t":"clients","count":2}"#) else {
            return XCTFail("clients not parsed")
        }
        XCTAssertEqual(count, 2)

        guard case .conn(let conn)? =
                InboundMessage.parse(text: #"{"t":"conn","connected":false,"state":"未连接"}"#) else {
            return XCTFail("conn not parsed")
        }
        XCTAssertFalse(conn.isConnected)
        XCTAssertEqual(conn.text, "未连接")
    }

    func testIgnoresGarbage() {
        XCTAssertNil(InboundMessage.parse(text: "not json"))
        XCTAssertNil(InboundMessage.parse(text: #"{"x":1}"#))
        if case .unsupported(let type)? = InboundMessage.parse(text: #"{"t":"nope"}"#) {
            XCTAssertEqual(type, "nope")
        } else {
            XCTFail("unknown type should be reported as unsupported")
        }
    }

    func testOutboundFrames() throws {
        func object(_ text: String) throws -> [String: Any] {
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let hello = try object(OutboundMessage.hello(clientId: "ios-1", name: "iPhone", pin: "1234"))
        XCTAssertEqual(hello["t"] as? String, "hello")
        XCTAssertEqual(hello["clientId"] as? String, "ios-1")
        XCTAssertEqual(hello["pin"] as? String, "1234")
        XCTAssertEqual(hello["proto"] as? Int, 1)

        let helloNoPin = try object(OutboundMessage.hello(clientId: "ios-1", name: "iPhone", pin: nil))
        XCTAssertNil(helloNoPin["pin"])

        let value = try object(OutboundMessage.value(id: 1000, value: 1.234))
        XCTAssertEqual(value["t"] as? String, "value")
        XCTAssertEqual(value["id"] as? Int, 1000)
        XCTAssertEqual(value["v"] as? Double, 1.234)

        let exact = try object(OutboundMessage.commit(id: 1000, value: 999, exact: true))
        XCTAssertEqual(exact["t"] as? String, "commit")
        XCTAssertEqual(exact["exact"] as? Bool, true)

        let plain = try object(OutboundMessage.commit(id: 1000, value: 2, exact: false))
        XCTAssertNil(plain["exact"])

        let toggle = try object(OutboundMessage.action(id: 4, on: true))
        XCTAssertEqual(toggle["on"] as? Bool, true)
        XCTAssertNil(toggle["trigger"])

        let trigger = try object(OutboundMessage.action(id: 3, trigger: true))
        XCTAssertEqual(trigger["trigger"] as? Bool, true)

        let oneClick = try object(OutboundMessage.oneClick(group: "底盘/PID", intervalMs: 100))
        XCTAssertEqual(oneClick["group"] as? String, "底盘/PID")
        XCTAssertEqual(oneClick["intervalMs"] as? Int, 100)

        XCTAssertEqual(try object(OutboundMessage.oneClickStop())["t"] as? String, "oneclick.stop")
        XCTAssertEqual(try object(OutboundMessage.sync())["t"] as? String, "sync")
        XCTAssertEqual(try object(OutboundMessage.ping())["t"] as? String, "ping")
    }

    func testNonFiniteValuesAreSanitised() throws {
        let text = OutboundMessage.value(id: 1, value: .nan)
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Double, 0)
    }

    func testClampingAndFormatting() {
        let control = ControlItem(id: 1, label: "kp", group: "g", value: 1,
                                  minimum: 0, maximum: 10, step: 0.01,
                                  includedInOneClick: true, order: 0)
        XCTAssertEqual(control.clamped(-5), 0)
        XCTAssertEqual(control.clamped(50), 10)
        XCTAssertEqual(control.clamped(3.5), 3.5)
        XCTAssertEqual(control.clamped(.nan), 1)
        XCTAssertEqual(control.formatted(1.5), "1.50")
        XCTAssertEqual(ControlItem.decimals(forStep: 1), 0)
        XCTAssertEqual(ControlItem.decimals(forStep: 0.1), 1)
        XCTAssertEqual(ControlItem.decimals(forStep: 0.001), 3)
    }

    func testGroupForestNestsPaths() {
        let forest = GroupNode.forest(from: ["默认", "底盘", "底盘/PID", "底盘/PID/内环"])
        XCTAssertEqual(forest.count, 2)
        XCTAssertEqual(forest[1].title, "底盘")
        XCTAssertEqual(forest[1].children.count, 1)
        XCTAssertEqual(forest[1].children[0].path, "底盘/PID")
        XCTAssertEqual(forest[1].children[0].depth, 1)
        XCTAssertEqual(forest[1].children[0].children.first?.path, "底盘/PID/内环")
    }

    func testEndpointParser() {
        XCTAssertEqual(EndpointParser.parse("192.168.1.23:47900")?.host, "192.168.1.23")
        XCTAssertEqual(EndpointParser.parse("192.168.1.23:47900")?.port, 47900)
        XCTAssertEqual(EndpointParser.parse(" ws://192.168.1.23:48000/ ")?.port, 48000)
        XCTAssertEqual(EndpointParser.parse("192.168.1.23")?.port, 47900)
        XCTAssertNil(EndpointParser.parse(""))
        XCTAssertNil(EndpointParser.parse(":47900"))
        XCTAssertNil(EndpointParser.parse("host:abc"))
        XCTAssertNil(EndpointParser.parse("host:99999"))
    }

    func testDiscoveryBroadcastTargetsIncludeLimitedBroadcast() {
        let targets = DiscoveryService.broadcastTargets()
        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.contains(in_addr_t(0xFFFF_FFFF).bigEndian))
    }
}
