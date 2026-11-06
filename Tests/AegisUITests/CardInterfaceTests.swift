import XCTest

@MainActor
final class CardInterfaceTests: XCTestCase {
    func testAppearancePersistsAndCardFaceStaysMasked() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-vault", "--preview-cards", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.activate()
        let card = app.buttons["record-Mastercard · 借记卡"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        let edit = app.buttons["editItemButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let reset = app.buttons["resetCardAppearance"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reveal(reset, in: app)
        capture("card-compact-editor")
        XCTAssertFalse(app.staticTexts["赤铜"].exists, "The iPhone editor should describe the card, not its palette")
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        reveal(app.buttons["cardBrand-mastercard"], in: app)
        XCTAssertFalse(app.buttons["cardBrand-mastercard"].isSelected)
        reveal(app.buttons["cardType-debit"], in: app)
        XCTAssertFalse(app.buttons["cardType-debit"].isSelected)
        let amex = app.buttons["cardBrand-americanExpress"]
        reveal(amex, in: app)
        amex.tap()
        XCTAssertTrue(amex.isSelected)
        let credit = app.buttons["cardType-credit"]
        reveal(credit, in: app)
        credit.tap()
        XCTAssertTrue(credit.isSelected)
        capture("card-editor-amex-credit")
        app.buttons["saveItemButton"].tap()
        XCTAssertTrue(app.staticTexts["运通 · 信用卡"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["4242424242424242"].exists)
        let face = app.descendants(matching: .any)["bankCardPreview"].firstMatch
        XCTAssertTrue(face.exists)
        XCTAssertTrue(face.label.contains("••••"))
        XCTAssertTrue(face.label.contains("4242"))
        capture("card-detail-amex-credit")
        app.buttons["editItemButton"].tap()
        reveal(app.buttons["cardBrand-americanExpress"], in: app)
        XCTAssertTrue(app.buttons["cardBrand-americanExpress"].isSelected)
        reveal(app.buttons["cardType-credit"], in: app)
        XCTAssertTrue(app.buttons["cardType-credit"].isSelected)
    }

    func testCardNumberFiltersCountsAndRequiresValidChecksum() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-vault", "--preview-cards", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.activate()
        let add = app.buttons["addItemButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 20)); add.tap()
        app.buttons["itemKind-card"].tap()
        let title = app.textFields["itemTitle"]
        title.tap(); title.typeText("Card checksum QA")
        let hideKeyboard = app.buttons["dismissEditorKeyboard"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
        hideKeyboard.tap()
        let brand = app.buttons["cardBrand-mastercard"]
        reveal(brand, in: app); brand.tap()
        let number = app.textFields["cardNumber"]
        reveal(number, in: app)
        number.tap()
        number.typeText("4111x1111-1111 1112")
        XCTAssertEqual(number.value as? String, "4111111111111112")
        XCTAssertTrue(app.staticTexts["cardNumberCount"].label.contains("16 / 19"))
        XCTAssertFalse(app.buttons["saveItemButton"].isEnabled)
        number.typeText(XCUIKeyboardKey.delete.rawValue + "1")
        XCTAssertEqual(number.value as? String, "4111111111111111")
        XCTAssertTrue(app.buttons["saveItemButton"].isEnabled)
        capture("card-number-validation")
        app.buttons["saveItemButton"].tap()
        XCTAssertTrue(app.staticTexts["Mastercard · 借记卡"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["itemEditorScroll"]
        for _ in 0..<12 {
            if element.isHittable { return }
            let frame = scroll.frame
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
            let visibleHeight = max(100, bottom - frame.minY)
            let upward = !element.exists || element.frame.midY >= frame.minY + visibleHeight / 2
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let high = origin.withOffset(CGVector(dx: frame.width * 0.5, dy: visibleHeight * 0.3))
            let low = origin.withOffset(CGVector(dx: frame.width * 0.5, dy: visibleHeight * 0.7))
            (upward ? low : high).press(forDuration: 0.05, thenDragTo: upward ? high : low)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
