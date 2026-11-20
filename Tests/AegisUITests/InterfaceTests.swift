import XCTest

@MainActor
final class InterfaceTests: XCTestCase {
    private var app: XCUIApplication!

    private func launchVault(extraArguments: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview-vault", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extraArguments
        app.launch()
        app.activate()
        unlockIfNeeded()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 20))
    }

    func testBrowseEditAndPreviewMarkdown() {
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

    func testUtilitiesAndOrientation() {
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

    func testExpandedMarkdownEditorReturnsDraftAndSaves() {
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

    func testOnboardingRequiresMatchingPasswordAndRecoveryConfirmation() {
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
        reveal(master)
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
        reveal(create)
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

    func testOnboardingOffersLocalImportBeforeCreatingAVault() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.activate()
        let localImport = app.buttons["localImportButton"]
        XCTAssertTrue(localImport.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["onboardingBackupImportButton"].exists)
        XCTAssertTrue(localImport.isEnabled, "Joining a vault must not require a new master password")
        addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
            for label in ["允许", "好", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        localImport.tap()
        let receive = app.buttons["receiveLocalVaultButton"]
        XCTAssertTrue(receive.waitForExistence(timeout: 10))
        XCTAssertFalse(receive.isEnabled)
        XCTAssertFalse(app.buttons["localPairingModeButton"].exists)
        XCTAssertFalse(app.textFields["localPairingCodeInput"].exists)
        XCTAssertFalse(app.staticTexts["localPairingComparison"].exists)
        capture("onboarding-local-import")
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(localImport.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["unlockButton"].isEnabled)
        XCTAssertTrue(app.secureTextFields["confirmPassword"].exists, "Cancelling import must leave the device uninitialized")
    }

    func testChromeCSVOnlyImportsCheckedRecords() {
        launchVault(extraArguments: ["--preview-chrome-csv"])
        openPasswordCSV()
        XCTAssertTrue(app.staticTexts["Chrome"].waitForExistence(timeout: 10))
        let confirm = app.buttons["confirmPasswordCSV"]
        app.buttons["clearPasswordCSVItems"].tap()
        XCTAssertFalse(confirm.isEnabled)
        let alpha = app.buttons.containing(.staticText, identifier: "CSV Alpha").firstMatch
        reveal(alpha)
        alpha.tap()
        XCTAssertTrue(confirm.isEnabled)
        capture("chrome-csv-preview")
        confirm.tap()
        XCTAssertTrue(app.buttons["importPasswordCSVButton"].waitForExistence(timeout: 10))
        app.buttons["保险库"].tap()
        let search = app.textFields["vaultSearch"]
        search.tap()
        search.typeText("CSV")
        XCTAssertTrue(app.buttons["record-CSV Alpha"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["record-CSV Beta"].exists)
    }

    func testOnePasswordCSVPreviewClearsOnBackgroundLock() throws {
        launchVault(extraArguments: ["--preview-onepassword-csv"])
        openPasswordCSV()
        XCTAssertTrue(app.staticTexts["1Password"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["synthetic-alpha"].exists)
        capture("onepassword-csv-preview")
        // The simulator's Home event can leave Aegis foregrounded; switch to another app.
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        let vault = try XCTUnwrap(app)
        let isBackgrounded = NSPredicate { _, _ in
            let state = vault.state
            return state == .runningBackground || state == .runningBackgroundSuspended
        }
        let background = XCTNSPredicateExpectation(predicate: isBackgrounded, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed, "Current app state: \(app.state)")
        app.activate()
        let password = app.secureTextFields["masterPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        unlockIfNeeded()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirmPasswordCSV"].exists)
        XCTAssertFalse(app.buttons["record-CSV Alpha"].exists)
    }

    func testLANSyncRequiresOptInAndRemainsEnabledAfterUnlock() {
        launchVault()
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.segmentedControls["settingsTabs"].buttons["同步与备份"].tap()
        let toggle = app.switches["lanSyncToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["lanSyncStatus"].waitForExistence(timeout: 5))
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        app.activate()
        XCTAssertTrue(app.secureTextFields["masterPassword"].waitForExistence(timeout: 15))
        unlockIfNeeded()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.segmentedControls["settingsTabs"].buttons["同步与备份"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.staticTexts["lanSyncStatus"].exists)
    }

    private func openPasswordCSV() {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.segmentedControls["settingsTabs"].buttons["同步与备份"].tap()
        let action = app.buttons["importPasswordCSVButton"]
        reveal(action)
        action.tap()
    }

    func testFileImportOnlyWritesSelectedItems() throws {
        try exerciseImportSelection(localNetwork: false)
    }

    func testReplacingBackupClearsTheOldPreviewAfterReadFailure() {
        app = XCUIApplication()
        app.launchArguments = ["--preview-onboarding", "--preview-import-selection", "--preview-failed-backup-replacement",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let open = app.buttons["onboardingBackupImportButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let confirm = app.buttons["confirmRestoreButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        let choose = app.buttons["chooseBackupFile"]
        reveal(choose); choose.tap()
        XCTAssertTrue(confirm.exists, "Cancelling the picker preserves the current preview")
        choose.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["verifyBackupButton"].isEnabled)
    }

    func testLocalImportOnlyWritesSelectedItems() throws {
        try exerciseImportSelection(localNetwork: true)
    }

    private func exerciseImportSelection(localNetwork: Bool) throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview-onboarding", "--preview-import-selection", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.activate()
        let open = app.buttons[localNetwork ? "localImportButton" : "onboardingBackupImportButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let clear = app.buttons["clearImportItems"]
        XCTAssertTrue(clear.waitForExistence(timeout: 20))
        reveal(clear); clear.tap()
        let confirm = app.buttons[localNetwork ? "confirmLocalImportButton" : "confirmRestoreButton"]
        XCTAssertTrue(confirm.exists)
        XCTAssertFalse(confirm.isEnabled, "A nonempty vault must not silently import everything when selection is empty")
        let apple = app.buttons["importItem-00000000-0000-0000-0000-000000000001"]
        reveal(apple); apple.tap()
        XCTAssertEqual(apple.value as? String, "已选择")
        let github = app.buttons["importItem-00000000-0000-0000-0000-000000000002"]
        XCTAssertEqual(github.value as? String, "未选择")
        capture(localNetwork ? "local-import-selection" : "file-import-selection")
        reveal(confirm)
        XCTAssertTrue(confirm.isEnabled); confirm.tap()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["record-Apple"].exists)
        XCTAssertFalse(app.buttons["record-GitHub"].exists)
        XCTAssertFalse(app.buttons["record-Import note"].exists)
    }

    func testUnnamedRecordCannotSaveAndGeneratorLimitIsDisabled() {
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
            for _ in 0 ..< decrements {
                app.buttons["increasePasswordLength"].tap()
            }
        }
        for _ in 0 ..< 64 {
            if !decrease.isEnabled {
                break
            }
            decrease.tap()
            decrements += 1
        }
        XCTAssertFalse(decrease.isEnabled)
        XCTAssertTrue(app.buttons["increasePasswordLength"].isEnabled)
        captureElement(decrease, name: "generator-limit-disabled")
    }

    func testDamagedHistoryLeavesReadableRecordsAndKeepsDraft() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview-vault", "--preview-damaged-vault", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let warning = app.descendants(matching: .any).matching(identifier: "vaultIntegrityWarning").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["addItemButton"].isEnabled)
        let drafts = app.buttons["resumeDrafts"]
        XCTAssertTrue(drafts.exists)
        let apple = app.buttons["record-Apple"]
        XCTAssertTrue(apple.exists)
        capture("vault-integrity-warning")
        apple.tap()
        let edit = app.buttons["editItemButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(edit.isEnabled)
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        app.buttons["锁定保险库"].tap()
        unlockIfNeeded()
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(drafts.exists)
        XCTAssertTrue(apple.exists)
    }

    func testDraftSurvivesCloseLockUnlockAndSave() {
        launchVault()
        app.buttons["record-Apple"].tap()
        app.buttons["editItemButton"].tap()
        let notes = app.textViews["markdownNotes"]
        reveal(notes); notes.tap(); notes.typeText("Retained draft after lock")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["保留草稿并关闭"].waitForExistence(timeout: 5))
        app.buttons["保留草稿并关闭"].tap()
        let back = app.buttons["BackButton"]
        if back.exists {
            back.tap()
        }
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

    func testFormattingIsNotReplayedByPreviewSwitches() {
        launchVault()
        app.buttons["record-Apple"].tap()
        app.buttons["editItemButton"].tap()
        let notes = app.textViews["markdownNotes"]
        reveal(notes); notes.tap(); notes.typeText("One task")
        reveal(app.buttons["markdownFormat-task"])
        app.buttons["markdownFormat-task"].tap()
        let original = notes.value as? String
        for _ in 0 ..< 3 {
            app.buttons["composerMode-preview"].tap()
            app.buttons["composerMode-write"].tap()
            XCTAssertEqual(notes.value as? String, original)
        }
    }

    func testAccessibilitySizeScalesHeadline() {
        launchVault()
        let title = app.staticTexts["vaultListTitle"]
        let normal = title.frame.height
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.activate()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(title.frame.height, normal * 1.2)
        XCTAssertTrue(app.buttons["addItemButton"].isHittable)
        capture("12-accessibility-layout")
    }

    func testAppearancePersistsAcrossLaunches() {
        launchVault()
        app.buttons["设置"].tap()
        app.segmentedControls["settingsTabs"].buttons["外观与关于"].tap()
        let appearance = app.segmentedControls["appearancePicker"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.buttons["深色"].tap()
        XCTAssertTrue(appearance.buttons["深色"].isSelected)
        capture("13-dark-appearance")
        app.terminate()
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 20))
        app.buttons["设置"].tap()
        app.segmentedControls["settingsTabs"].buttons["外观与关于"].tap()
        XCTAssertTrue(appearance.buttons["深色"].isSelected)
        appearance.buttons["浅色"].tap()
        XCTAssertTrue(appearance.buttons["浅色"].isSelected)
        capture("14-light-appearance")
        appearance.buttons["跟随系统"].tap()
    }

    func testKeychainDeleteFailureKeepsBiometricsEnabledAndWarnsAfterRotation() {
        launchVault(extraArguments: ["--preview-keychain-delete-failure"])
        app.buttons["设置"].tap()
        let biometrics = app.switches["biometricsToggle"]
        reveal(biometrics)
        XCTAssertEqual(biometrics.value as? String, "1")
        biometrics.tap()
        let error = app.alerts.firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        error.buttons.firstMatch.tap()
        XCTAssertEqual(biometrics.value as? String, "1")
        exerciseMasterPasswordRotation(expectKeychainWarning: true)
    }

    func testChangeMasterPasswordRotatesCredentials() {
        launchVault()
        app.buttons["设置"].tap()
        exerciseMasterPasswordRotation(expectKeychainWarning: false)
    }

    private func exerciseMasterPasswordRotation(expectKeychainWarning: Bool) {
        let open = app.buttons["changeMasterPasswordButton"]
        reveal(open)
        open.tap()
        let current = app.secureTextFields["currentMasterPassword"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        let submit = app.buttons["changeMasterPasswordSubmit"]
        let newPassword = "rotated preview passphrase"
        current.tap(); current.typeText("Aegis preview fixture only")
        let password = app.secureTextFields["newMasterPassword"]
        password.tap(); password.typeText(newPassword)
        let confirmation = app.secureTextFields["confirmNewMasterPassword"]
        confirmation.tap(); confirmation.typeText(newPassword + "x")
        XCTAssertFalse(submit.isEnabled, "mismatched confirmation must block the change")
        // Keep focus so the secure field cannot automatically clear the whole confirmation.
        confirmation.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        if expectKeychainWarning {
            let warning = app.alerts.firstMatch
            XCTAssertTrue(warning.waitForExistence(timeout: 30))
            XCTAssertTrue(warning.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "未能从本机钥匙串删除旧的生物识别凭据")).firstMatch.exists)
            warning.buttons.firstMatch.tap()
        }

        // The new recovery key is shown in the same sheet and must be confirmed before it closes.
        let acknowledgement = app.switches["recoveryAcknowledgement"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 30))
        capture("10-rotation-recovery-key")
        acknowledgement.tap()
        app.buttons["enterVaultButton"].tap()
        XCTAssertTrue(acknowledgement.waitForNonExistence(timeout: 8))

        app.buttons["保险库"].tap()
        let lock = app.buttons["锁定保险库"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        lock.tap()
        let master = app.secureTextFields["masterPassword"]
        XCTAssertTrue(master.waitForExistence(timeout: 8))
        master.tap(); master.typeText("Aegis preview fixture only")
        app.buttons["unlockButton"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15), "the old master password must no longer unlock")
        app.alerts.firstMatch.buttons.firstMatch.tap()
        replaceText(in: master, with: "rotated preview passphrase")
        app.buttons["unlockButton"].tap()
        XCTAssertTrue(app.buttons["addItemButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["record-Apple"].waitForExistence(timeout: 5), "records survive the rotation")
    }

    func testBackupPasswordMustMeetPolicyBeforeExport() {
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
        let dataTab = app.buttons["同步与备份"]
        XCTAssertTrue(dataTab.waitForExistence(timeout: 5))
        dataTab.tap()
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
        for _ in 0 ..< 6 {
            if element.isHittable {
                return
            }
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
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
