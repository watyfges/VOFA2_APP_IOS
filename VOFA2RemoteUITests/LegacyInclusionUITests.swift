//
//  LegacyInclusionUITests.swift
//  VOFA2RemoteUITests
//
//  旧版 PC 不认识 {"t":"inc"}，App 要退化成「只对本次发送生效」。
//    python3 ios/tools/mock_remote_server.py --port 47930 --discovery-port 47931 --legacy
//

import XCTest

final class LegacyInclusionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-RemoteEndpoint", "127.0.0.1:47930"]
        app.launch()

        let link = app.staticTexts["status.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 15)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLegacyPCFallsBackToSessionOnlySelection() {
        app.buttons["group.chip.默认"].tap()
        app.buttons["oneclick.button"].tap()

        let hint = app.staticTexts["oneclick.sheet.hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        XCTAssertTrue(hint.label.contains("写回"), "新版服务端默认按写回提示")

        let row = app.cells["oneclick.sheet.item.kp"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // 服务端返回 bad_request 后提示要切换成「只在本次生效」。
        let fallback = NSPredicate(format: "label CONTAINS %@", "不支持写回")
        expectation(for: fallback, evaluatedWith: hint)
        waitForExpectations(timeout: 8)

        // 本地选择依然生效，只是不落盘。
        XCTAssertTrue(app.staticTexts["oneclick.sheet.count"].label.contains("已选 2 项"))
    }
}
