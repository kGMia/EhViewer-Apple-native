import XCTest

final class ehviewer_appleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWideBrowserExposesUnifiedSearchRecordsPanel() throws {
        let app = configuredApplication()
        app.launchEnvironment["EH_UI_TEST_WIDE"] = "1"
        app.launch()

        // SwiftUI 的最外层 Group 不一定生成独立的辅助功能节点；使用真正
        // 可操作的侧栏与搜索框作为启动完成条件，避免测试依赖实现细节。
        let homeTab = element("sidebar.tab.首页", in: app)
        XCTAssertTrue(
            homeTab.waitForExistence(timeout: 10),
            "未找到宽窗口侧栏。当前界面层级：\n\(app.debugDescription)"
        )
        XCTAssertTrue(element("gallery.search.field", in: app).waitForExistence(timeout: 5))

        let searchField = element("gallery.search.field", in: app)
        searchField.click()
        XCTAssertTrue(element("quickSearch.panel", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["搜索历史"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["已保存的搜索"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("gallery.search.quick", in: app).exists)
        XCTAssertTrue(element("gallery.display.toggle", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(app.searchFields["筛选已保存的搜索"].exists)
    }

    @MainActor
    func testCompactGalleryUsesSingleColumnAndBackReturnsToFeed() throws {
        let app = configuredApplication()
        app.launchEnvironment["EH_UI_TEST_COMPACT"] = "1"
        app.launchEnvironment["EH_UI_TEST_GALLERY_GID"] = "987654321"
        app.launch()

        XCTAssertTrue(element("gallery.detail.compact", in: app).waitForExistence(timeout: 10))
        let backButton = element("gallery.detail.back", in: app)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.click()

        XCTAssertTrue(element("gallery.search.field", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("gallery.detail.compact", in: app).exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            configuredApplication().launch()
        }
    }

    @MainActor
    private func configuredApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EH_UI_TEST_BYPASS_ONBOARDING"] = "1"
        app.launchArguments = [
            "-show_warning", "NO",
            "-has_selected_site", "YES",
            "-skip_sign_in", "YES",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
