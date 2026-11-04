//
//  TuningUITests.swift
//  VOFA2RemoteUITests
//
//  Drives the real UI against ios/tools/mock_remote_server.py.
//  Start the mock first:  python3 ios/tools/mock_remote_server.py
//

import XCTest

final class TuningUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-RemoteEndpoint", "127.0.0.1:47900"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testConnectsAndShowsControls() {
        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), "status label should exist")

        let connected = NSPredicate(format: "label == %@", "已连接")
        expectation(for: connected, evaluatedWith: link)
        waitForExpectations(timeout: 15)

        // Group chips come from `state.groups`.
        XCTAssertTrue(app.buttons["group.chip.默认"].exists)
        XCTAssertTrue(app.buttons["group.chip.底盘/PID"].exists)

        // Default group has actions and sliders.
        app.buttons["group.chip.默认"].tap()
        XCTAssertTrue(app.sliders["control.slider.kp"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["action.switch.闭环"].exists)
    }

    func testSwitchAndSliderWriteBack() {
        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)

        app.buttons["group.chip.默认"].tap()

        // Toggle: read the current state first, the mock keeps state between runs.
        let toggle = app.switches["action.switch.闭环"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.value as? String ?? "1"
        toggle.tap()

        let expected = before == "1" ? "0" : "1"
        let switched = NSPredicate(format: "value == %@", expected)
        expectation(for: switched, evaluatedWith: toggle)
        waitForExpectations(timeout: 6)

        // Slider drag must update the value box and commit to the server.
        let slider = app.sliders["control.slider.kp"]
        let field = app.textFields["control.field.kp"]
        let beforeDrag = field.value as? String ?? ""
        slider.adjust(toNormalizedSliderPosition: 0.8)
        let changed = NSPredicate(format: "value != %@", beforeDrag)
        expectation(for: changed, evaluatedWith: field)
        waitForExpectations(timeout: 6)
        let typed = field.value as? String ?? ""
        XCTAssertNotNil(Double(typed.replacingOccurrences(of: ",", with: ".")),
                        "value box should hold a number, got \(typed)")
    }

    func testOneClickSendsWholeGroup() {
        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)

        app.buttons["group.chip.默认"].tap()
        let button = app.buttons["oneclick.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        // The PC-style sheet, pre-filled from the PC's `inc` ticks.
        let sendButton = app.buttons["oneclick.sheet.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "one-click sheet should open")
        // 勾选是 PC 的持久状态，其它用例可能改过；先全选再断言。
        app.buttons["oneclick.sheet.selectAll"].tap()
        XCTAssertTrue(app.staticTexts["oneclick.sheet.count"].label.contains("已选 3 项"))
        sendButton.tap()

        let status = app.staticTexts["oneclick.sheet.status"]
        let finished = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "完成", "已发送")
        expectation(for: finished, evaluatedWith: status)
        waitForExpectations(timeout: 12)
    }

    /// Deselecting everything and ticking a single slider must send only that one.
    func testOneClickSendsOnlyChosenSliders() {
        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)

        app.buttons["group.chip.默认"].tap()
        app.buttons["oneclick.button"].tap()

        let sendButton = app.buttons["oneclick.sheet.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        app.buttons["oneclick.sheet.selectNone"].tap()
        XCTAssertTrue(app.staticTexts["oneclick.sheet.count"].label.contains("已选 0 项"))
        XCTAssertFalse(sendButton.isEnabled, "nothing selected means nothing to send")

        let row = app.cells["oneclick.sheet.item.kp"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "slider rows should be listed")
        row.tap()
        XCTAssertTrue(app.staticTexts["oneclick.sheet.count"].label.contains("已选 1 项"))

        sendButton.tap()
        let status = app.staticTexts["oneclick.sheet.status"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "完成 1 项"), evaluatedWith: status)
        waitForExpectations(timeout: 10)

        // 勾选会写回 PC，收尾时恢复成全选，避免影响其它用例。
        app.buttons["oneclick.sheet.selectAll"].tap()
        app.buttons["oneclick.sheet.close"].tap()
    }

    /// 勾选改动要写回 PC（`{"t":"inc"}`），主界面的「一键」标签随之变化。
    /// 勾选是 PC 的持久状态，所以用例先读当前状态，翻转一次再翻回去。
    func testTogglingCheckboxWritesBackToPC() {
        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)

        app.buttons["group.chip.默认"].tap()
        let tag = app.staticTexts["control.oneclick.kp"]
        _ = tag.waitForExistence(timeout: 5)
        let startedIncluded = tag.exists

        // 翻转一次：取消勾选 -> 写回 PC -> state 回传后标签消失
        app.buttons["oneclick.button"].tap()
        let row = app.cells["oneclick.sheet.item.kp"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["oneclick.sheet.close"].tap()

        let afterToggle = startedIncluded ? "exists == false" : "exists == true"
        expectation(for: NSPredicate(format: afterToggle), evaluatedWith: tag)
        waitForExpectations(timeout: 8)

        // 再翻回去，保持 PC 的初始勾选。
        app.buttons["oneclick.button"].tap()
        let rowAgain = app.cells["oneclick.sheet.item.kp"].firstMatch
        XCTAssertTrue(rowAgain.waitForExistence(timeout: 5))
        rowAgain.tap()
        app.buttons["oneclick.sheet.close"].tap()

        let restored = startedIncluded ? "exists == true" : "exists == false"
        expectation(for: NSPredicate(format: restored), evaluatedWith: tag)
        waitForExpectations(timeout: 8)
    }

    func testSwitchingGroupsChangesVisibleControls() {
        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)

        app.buttons["group.chip.视觉/曝光"].tap()
        XCTAssertTrue(app.sliders["control.slider.曝光时间"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["control.slider.kp"].exists,
                       "controls from other groups must stay hidden")

        app.buttons["group.chip.底盘"].tap()
        XCTAssertTrue(app.sliders["control.slider.目标速度"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["action.button.急停"].exists)
    }
}
