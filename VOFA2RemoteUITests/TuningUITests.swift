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

        let status = app.staticTexts["oneclick.status"]
        let finished = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "完成", "已发送")
        expectation(for: finished, evaluatedWith: status)
        waitForExpectations(timeout: 12)
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
