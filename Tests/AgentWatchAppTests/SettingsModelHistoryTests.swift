import XCTest

@testable import AgentWatchApp

/// Back and forward in the settings window, walked the way System Settings walks them: in the
/// order the pages were opened, with a new page dropping whatever was ahead.
@MainActor
final class SettingsModelHistoryTests: XCTestCase {
    /// A fresh window opens on the sidebar's top entry and has nowhere to go but where the
    /// person sends it.
    func testAFreshWindowOpensOnGeneralWithNoHistory() throws {
        let (model, _) = try makeModel()

        XCTAssertEqual(model.page, .general)
        XCTAssertEqual(model.page, SettingsPage.sidebar.first)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
    }

    /// Back retraces the pages opened, forward returns along them.
    func testBackAndForwardWalkThePagesInTheOrderTheyWereOpened() throws {
        let (model, _) = try makeModel()

        model.go(.appearance)
        model.go(.menuBar)
        model.goBack()
        XCTAssertEqual(model.page, .appearance)
        model.goBack()
        XCTAssertEqual(model.page, .general)
        XCTAssertFalse(model.canGoBack)

        model.goForward()
        XCTAssertEqual(model.page, .appearance)
        model.goForward()
        XCTAssertEqual(model.page, .menuBar)
        XCTAssertFalse(model.canGoForward)
    }

    /// Opening a page after going back is a new path: what was ahead is gone.
    func testOpeningAPageAfterGoingBackDropsWhatWasAhead() throws {
        let (model, _) = try makeModel()

        model.go(.appearance)
        model.go(.menuBar)
        model.goBack()
        model.go(.general)

        XCTAssertEqual(model.page, .general)
        XCTAssertFalse(model.canGoForward)
        model.goBack()
        XCTAssertEqual(model.page, .appearance)
    }

    /// Asking for the page already shown is not a step: back must not lead to the same page.
    func testGoingToThePageAlreadyShownIsNotRemembered() throws {
        let (model, _) = try makeModel()

        model.go(.general)

        XCTAssertFalse(model.canGoBack)
    }

    /// Back and forward with nothing to walk to leave the window where it is.
    func testBackAndForwardWithNothingThereChangeNothing() throws {
        let (model, _) = try makeModel()

        model.goBack()
        model.goForward()

        XCTAssertEqual(model.page, .general)
    }

    /// The host is held weakly by the model, so it is returned for the test to keep alive.
    private func makeModel() throws -> (SettingsModel, FakeAppHost) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        let model = SettingsModel(
            themes: ThemeStore(preferences: preferences, folder: nil),
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings),
            host: host,
            version: nil
        )
        return (model, host)
    }
}
