//
//  OneClickOfflineUITests.swift
//  VOFA2RemoteUITests
//
//  PC 端没连设备时一键发送必须立刻失败并把按钮解禁。
//  需要额外起一个离线 mock：
//    python3 ios/tools/mock_remote_server.py --port 47920 --discovery-port 47921 --offline
//

import XCTest

final class OneClickOfflineUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-RemoteEndpoint", "127.0.0.1:47920"]
        app.launch()

        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Whole-group send goes through the server: it must answer `not_connected`
    /// and unlock the button instead of leaving the sheet stuck on "发送中…".
    func testServerRefusesWhenPCOffline() {
        app.buttons["group.chip.默认"].tap()
        app.buttons["oneclick.button"].tap()

        XCTAssertTrue(app.staticTexts["oneclick.sheet.warning"].waitForExistence(timeout: 5),
                      "sheet should warn that the PC is offline")

        let sendButton = app.buttons["oneclick.sheet.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.tap()

        let status = app.staticTexts["oneclick.sheet.status"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "连接"), evaluatedWith: status)
        waitForExpectations(timeout: 10)

        let unlocked = NSPredicate(format: "isEnabled == true")
        expectation(for: unlocked, evaluatedWith: sendButton)
        waitForExpectations(timeout: 6)
    }

    /// A custom selection is sent by the phone itself, so it has no server guard
    /// and must be blocked locally.
    func testCustomSelectionIsBlockedLocally() {
        app.buttons["group.chip.默认"].tap()
        app.buttons["oneclick.button"].tap()

        let sendButton = app.buttons["oneclick.sheet.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        app.buttons["oneclick.sheet.selectNone"].tap()
        let row = app.cells["oneclick.sheet.item.kp"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        sendButton.tap()

        let status = app.staticTexts["oneclick.sheet.status"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "未连接"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
    }
}
