import XCTest

@MainActor
final class InterfaceTests: XCTestCase {
    private var app: XCUIApplication!

    private func launchVault() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview-vault", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.activate()
        unlockIfNeeded()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 20))
    }

    func testBrowseEditAndPreviewMarkdown() throws {
        launchVault()
        unlockIfNeeded()
        let apple = app.buttons["record-Apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 10))
        apple.tap()
        let edit = app.buttons["editItemButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let title = app.textFields["itemTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(" QA")
        let notes = app.textViews["markdownNotes"]
        reveal(notes)
        notes.tap()
        notes.typeText("# Markdown QA\n\n- [x] Ready\n- [ ] Review")
        let preview = app.buttons["预览"]
        reveal(preview)
        preview.tap()
        XCTAssertTrue(app.staticTexts["Markdown QA"].waitForExistence(timeout: 5))
        app.buttons["saveItemButton"].tap()
        XCTAssertTrue(app.buttons["editItemButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Markdown QA"].exists)
        capture("05-saved-note")
    }

    func testUtilitiesAndOrientation() throws {
        launchVault()
        let generator = app.buttons["密码生成器"]
        XCTAssertTrue(generator.waitForExistence(timeout: 5))
        generator.tap()
        XCTAssertTrue(app.buttons["复制密码"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["复制密码"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["安全"].waitForExistence(timeout: 5))
        capture("08-settings")
    }

    func testExpandedMarkdownEditorReturnsDraftAndSaves() throws {
        launchVault()
        app.buttons["record-Apple"].tap()
        XCTAssertTrue(app.buttons["editItemButton"].waitForExistence(timeout: 5))
        app.buttons["editItemButton"].tap()
        let expand = app.buttons["expandMarkdownEditor"]
        reveal(expand)
        expand.tap()
        let editor = app.textViews["expandedMarkdownNotes"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("# Expanded draft\n\n")
        app.buttons["expanded-markdownFormat-task"].tap()
        editor.typeText("Keep this task")
        XCTAssertTrue((editor.value as? String)?.contains("- [ ] Keep this task") == true)
        capture("10-fullscreen-writing")
        app.buttons["expanded-composerMode-preview"].tap()
        XCTAssertTrue(app.staticTexts["Expanded draft"].waitForExistence(timeout: 5))
        capture("11-fullscreen-preview")
        app.buttons["doneExpandedMarkdown"].tap()
        let compact = app.textViews["markdownNotes"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue((compact.value as? String)?.contains("Keep this task") == true)
        app.buttons["saveItemButton"].tap()
        XCTAssertTrue(app.buttons["editItemButton"].waitForExistence(timeout: 5))
        app.buttons["editItemButton"].tap()
        reveal(app.textViews["markdownNotes"])
        XCTAssertTrue((app.textViews["markdownNotes"].value as? String)?.contains("Expanded draft") == true)
        capture("09-expanded-editor-return")
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func unlockIfNeeded() {
        let master = app.secureTextFields["masterPassword"]
        if master.waitForExistence(timeout: 2) {
            master.tap()
            master.typeText("Aegis preview fixture only")
            app.buttons["unlockButton"].tap()
        }
    }
    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
