//
//  PinFlowUITests.swift
//  VOFA2RemoteUITests
//
//  Access-code flow against a pin-protected mock server
//  (python3 ios/tools/mock_remote_server.py --port 47910 --discovery-port 47911 --pin 1234).
//

import XCTest

final class PinFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-RemoteEndpoint", "127.0.0.1:47910", "-RemotePin", "0000"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testBadPinPromptsAndCorrectPinConnects() {
        // Wrong code from the launch argument: the server closes with 4003 and the
        // app asks for the access code again.
        let alert = app.alerts["需要访问码"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "bad PIN should raise the prompt")

        // The code field is secure, so it shows up as a secure text field.
        let field = alert.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "PIN field should exist")
        field.tap()
        field.typeText("1234")
        alert.buttons["重连"].tap()

        let link = app.staticTexts["status.link"]
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: link)
        waitForExpectations(timeout: 20)

        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 10),
                      "after re-auth the controls should render")
    }
}
