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

    func testOnboardingRequiresMatchingPasswordAndRecoveryConfirmation() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.activate()
        let create = app.buttons["unlockButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        XCTAssertFalse(create.isEnabled)

        let master = app.secureTextFields["masterPassword"]
        let confirmation = app.secureTextFields["confirmPassword"]
        master.tap()
        master.typeText("short")
        confirmation.tap()
        confirmation.typeText("short")
        XCTAssertFalse(create.isEnabled, "A matching but short password must remain disabled")

        master.tap()
        master.typeText(XCUIKeyboardKey.delete.rawValue.repeated(5) + "Aegis onboarding test passphrase")
        confirmation.tap()
        confirmation.typeText(XCUIKeyboardKey.delete.rawValue.repeated(5) + "Aegis onboarding test")
        XCTAssertFalse(create.isEnabled, "Different passwords must remain disabled")
        confirmation.typeText(" passphrase")
        XCTAssertTrue(create.isEnabled)
        create.tap()

        let enter = app.buttons["enterVaultButton"]
        XCTAssertTrue(enter.waitForExistence(timeout: 20))
        reveal(enter)
        XCTAssertFalse(enter.isEnabled)
        captureElement(enter, name: "recovery-button-disabled")
        XCTAssertTrue(app.staticTexts["请先确认已妥善保存恢复密钥，再进入保险库。"].exists)
        let acknowledgement = app.switches["recoveryAcknowledgement"]
        XCTAssertTrue(acknowledgement.exists)
        acknowledgement.tap()
        XCTAssertTrue(enter.isEnabled)
        captureElement(enter, name: "recovery-button-enabled")
        acknowledgement.tap()
        XCTAssertFalse(enter.isEnabled, "Unchecking must disable entry again")
        acknowledgement.tap()
        enter.tap()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 8))
    }

    func testUnnamedRecordCannotSaveAndGeneratorLimitIsDisabled() throws {
        launchVault()
        app.buttons["addItemButton"].tap()
        let save = app.buttons["saveItemButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        captureElement(save, name: "record-save-disabled")
        let title = app.textFields["itemTitle"]
        title.tap()
        title.typeText("  ")
        XCTAssertFalse(save.isEnabled)
        title.typeText("Draft")
        XCTAssertTrue(save.isEnabled)
        app.buttons["取消"].tap()
        app.buttons["放弃修改"].tap()

        app.buttons["密码生成器"].tap()
        let decrease = app.buttons["decreasePasswordLength"]
        XCTAssertTrue(decrease.waitForExistence(timeout: 5))
        var decrements = 0
        defer {
            for _ in 0..<decrements { app.buttons["increasePasswordLength"].tap() }
        }
        for _ in 0..<64 {
            if !decrease.isEnabled { break }
            decrease.tap()
            decrements += 1
        }
        XCTAssertFalse(decrease.isEnabled)
        XCTAssertTrue(app.buttons["increasePasswordLength"].isEnabled)
        captureElement(decrease, name: "generator-limit-disabled")
    }


    func testDraftSurvivesCloseLockUnlockAndSave() throws {
        launchVault()
        app.buttons["record-Apple"].tap()
        app.buttons["editItemButton"].tap()
        let notes = app.textViews["markdownNotes"]
        reveal(notes); notes.tap(); notes.typeText("Retained draft after lock")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["保留草稿并关闭"].waitForExistence(timeout: 5))
        app.buttons["保留草稿并关闭"].tap()
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["锁定保险库"].waitForExistence(timeout: 5))
        app.buttons["锁定保险库"].tap()
        unlockIfNeeded()
        let drafts = app.buttons["resumeDrafts"]
        XCTAssertTrue(drafts.waitForExistence(timeout: 5))
        drafts.tap()
        app.buttons["Apple"].tap()
        reveal(notes)
        XCTAssertTrue((notes.value as? String ?? "").contains("Retained draft after lock"))
        app.buttons["saveItemButton"].tap()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeDrafts"].exists)
        app.buttons["record-Apple"].tap()
        XCTAssertTrue(app.staticTexts["Retained draft after lock"].waitForExistence(timeout: 5))
    }

    func testFormattingIsNotReplayedByPreviewSwitches() throws {
        launchVault()
        app.buttons["record-Apple"].tap()
        app.buttons["editItemButton"].tap()
        let notes = app.textViews["markdownNotes"]
        reveal(notes); notes.tap(); notes.typeText("One task")
        reveal(app.buttons["markdownFormat-task"])
        app.buttons["markdownFormat-task"].tap()
        let original = notes.value as? String
        for _ in 0..<3 {
            app.buttons["composerMode-preview"].tap()
            app.buttons["composerMode-write"].tap()
            XCTAssertEqual(notes.value as? String, original)
        }
    }

    func testAccessibilitySizeScalesHeadline() throws {
        launchVault()
        let title = app.staticTexts["我的保险库"]
        let normal = title.frame.height
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.activate()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(title.frame.height, normal * 1.2)
        XCTAssertTrue(app.buttons["addItemButton"].isHittable)
        capture("12-accessibility-layout")
    }

    func testBackupPasswordMustMeetPolicyBeforeExport() throws {
        launchVault()
        openBackupExport()
        app.buttons["exportModePassword"].tap()
        let export = app.buttons["exportBackupButton"]
        let password = app.secureTextFields["backupPassword"]
        let confirmation = app.secureTextFields["backupPasswordConfirmation"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        replaceText(in: password, with: "eleven char")
        replaceText(in: confirmation, with: "eleven char")
        XCTAssertFalse(export.isEnabled, "11 characters is below the backup password minimum")
        replaceText(in: password, with: "backup passphrase 2026")
        replaceText(in: confirmation, with: "backup passphrase 2025")
        XCTAssertFalse(export.isEnabled, "mismatched confirmation must block export")
        replaceText(in: confirmation, with: "backup passphrase 2026")
        XCTAssertTrue(export.isEnabled)
        capture("09-backup-export-password")
    }

    func testExportAuthorizesBeforeOfferingTheFile() throws {
        launchVault()
        openBackupExport()
        let export = app.buttons["exportBackupButton"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let master = app.secureTextFields["exportMasterPassword"]
        let picker = app.buttons["取消"]
        if master.waitForExistence(timeout: 5) {
            // No passcode or biometrics: the device-owner check falls back to the master password.
            XCTAssertFalse(export.isEnabled)
            master.tap()
            master.typeText("Aegis preview fixture only")
            export.tap()
        } else if !picker.waitForExistence(timeout: 30) {
            // The system prompt lives outside the app; a simulated match must come from the host:
            // xcrun simctl spawn <udid> notifyutil -p com.apple.BiometricKit_Sim.pearl.match
            throw XCTSkip("device-owner prompt was not answered; simulate a biometric match to cover this path")
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the system export picker should appear")
        capture("10-backup-export-picker")
    }

    private func openBackupExport() {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let export = app.buttons["导出加密备份"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        reveal(export)
        export.tap()
        XCTAssertTrue(app.buttons["exportModeVault"].waitForExistence(timeout: 5))
    }
    /// Secure fields may clear on re-focus; deleting first makes the result independent of that.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + text)
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
    private func captureElement(_ element: XCUIElement, name: String) {
        let image = XCTAttachment(screenshot: element.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
