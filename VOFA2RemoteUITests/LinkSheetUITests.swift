//
//  LinkSheetUITests.swift
//  VOFA2RemoteUITests
//
//  手机端控制 PC 连接：打开「连接」面板、选演示、连接、断开。
//  需要 mock：python3 ios/tools/mock_remote_server.py --port 47900
//

import XCTest

final class LinkSheetUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-RemoteEndpoint", "127.0.0.1:47900"]
        app.launch()

        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testOpenAndCloseDemoLink() {
        let openButton = app.navigationBars.buttons["连接"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5), "导航栏应有连接按钮")
        openButton.tap()

        let status = app.staticTexts["link.sheet.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "连接面板应打开")
        XCTAssertTrue(status.label.contains("未连接"), "初始应为未连接：\(status.label)")

        let demo = app.buttons["link.sheet.kind.4"]
        XCTAssertTrue(demo.waitForExistence(timeout: 3))
        demo.tap()

        let action = app.buttons["link.sheet.action"]
        XCTAssertEqual(action.label, "连接")
        action.tap()

        expectation(for: NSPredicate(format: "label CONTAINS %@", "已连接"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(status.label.contains("演示"), "应显示演示连接：\(status.label)")

        // 断开后回到未连接
        action.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "未连接"), evaluatedWith: status)
        waitForExpectations(timeout: 10)

        app.buttons["link.sheet.close"].tap()
    }
}
