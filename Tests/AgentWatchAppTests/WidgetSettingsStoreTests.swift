import XCTest

@testable import AgentWatchApp

@MainActor
final class WidgetSettingsStoreTests: XCTestCase {
    func testNothingIsLockedUntilItIsAskedFor() throws {
        let store = try makeStore()

        XCTAssertFalse(store.locksPosition)
        XCTAssertFalse(store.locksSize)
    }

    func testBothLocksArePersistedIndependently() throws {
        let store = try makeStore()

        store.setLocksPosition(true)

        XCTAssertTrue(store.locksPosition)
        XCTAssertFalse(store.locksSize, "locking the position must not also freeze the size")

        store.setLocksSize(true)
        store.setLocksPosition(false)

        XCTAssertFalse(store.locksPosition)
        XCTAssertTrue(store.locksSize)
    }

    func testClosedSessionsAreRetiredAfterTwoMinutesByDefault() throws {
        let store = try makeStore()

        XCTAssertEqual(
            store.closedSessionRetention,
            .after(WidgetSettingsStore.defaultClosedSessionRetention)
        )
    }

    func testAZeroRetentionMeansKeepUntilDismissed() throws {
        let store = try makeStore()

        store.setClosedSessionRetention(.manual)

        XCTAssertEqual(store.closedSessionRetention, .manual)
        XCTAssertEqual(store.closedSessionRetention.seconds, 0)
    }

    func testAChosenRetentionSurvives() throws {
        let store = try makeStore()

        store.setClosedSessionRetention(.after(600))

        XCTAssertEqual(store.closedSessionRetention, .after(600))
    }

    func testTranscriptsAreReadEveryFiveSecondsUntilAskedOtherwise() throws {
        let store = try makeStore()

        XCTAssertEqual(store.transcriptPollInterval, WidgetSettingsStore.defaultTranscriptPollInterval)

        store.setTranscriptPollInterval(10)
        XCTAssertEqual(store.transcriptPollInterval, 10)
    }

    func testReadingCanBeTurnedOffEntirely() throws {
        let store = try makeStore()

        store.setTranscriptPollInterval(nil)

        XCTAssertNil(store.transcriptPollInterval)
    }

    /// The only way a value out of range gets stored is an edited preferences file. Reading
    /// a growing file ten times a second because a number was mistyped is worse than not
    /// reading it, so the answer is off rather than a clamp.
    func testAnImpossibleIntervalIsTreatedAsOffRatherThanClamped() throws {
        let store = try makeStore()

        store.setTranscriptPollInterval(0.1)
        XCTAssertNil(store.transcriptPollInterval)

        store.setTranscriptPollInterval(86_400)
        XCTAssertNil(store.transcriptPollInterval)
    }

    func testTheWidgetIsDrawnAtItsTunedSizeUntilAskedOtherwise() throws {
        let store = try makeStore()
        XCTAssertEqual(store.scale, 1)

        store.setScale(1.5)

        XCTAssertEqual(store.scale, 1.5)
    }

    /// Clamped rather than refused: a scale out of range still means something — larger, or
    /// smaller — where a mistyped poll interval means a file read at a rate nobody chose.
    func testASizeOutOfRangeIsBroughtBackIntoIt() throws {
        let store = try makeStore()

        store.setScale(10)
        XCTAssertEqual(store.scale, WidgetSettingsStore.maximumScale)

        store.setScale(0.1)
        XCTAssertEqual(store.scale, WidgetSettingsStore.minimumScale)
    }

    /// The slider is not the only writer: a hand-edited preferences file is one too, and a
    /// stored size between two stops would draw a widget the settings window then reports as
    /// a size it is not at.
    func testASizeBetweenTwoStopsIsMovedToTheNearerOne() throws {
        let store = try makeStore()

        store.setScale(1.07)
        XCTAssertEqual(store.scale, 1.05, accuracy: 0.0001)

        store.setScale(1.08)
        XCTAssertEqual(store.scale, 1.1, accuracy: 0.0001)
    }

    /// Every stop has to survive being stored and read back as itself. The step is five
    /// percent, which no `Double` holds exactly, so the arithmetic that snaps a value has to
    /// leave a value that is already on a stop alone — otherwise the widget rebuilds on every
    /// frame of a drag that is standing still.
    func testEverySizeOnOfferIsStoredAsItself() throws {
        let store = try makeStore()

        for scale in WidgetSettingsStore.offeredScales {
            store.setScale(scale)
            XCTAssertEqual(
                store.scale,
                scale,
                "\(Int((scale * 100).rounded()))% did not survive being written and read back"
            )
        }
    }

    /// The slider behind this fires on every frame of a drag, and each write rebuilds every
    /// row in the widget. A drag that stays on one tick mark must cost nothing.
    func testSettingTheSizeItAlreadyHasTellsNobody() throws {
        let store = try makeStore()
        var announced = 0
        store.onChange = { setting in
            if case .scale = setting {
                announced += 1
            }
        }

        store.setScale(1.5)
        store.setScale(1.5)
        // Two sizes off the grid that snap to the same stop: the dedup has to happen after
        // the snapping, or every stray fraction of a percent would be a rebuild.
        store.setScale(1.51)
        store.setScale(1.49)
        // Clamped to a value it already holds, which is the same drag against the end stop.
        store.setScale(9)
        store.setScale(WidgetSettingsStore.maximumScale)

        XCTAssertEqual(announced, 2, "one for each size the widget actually changed to")
    }

    /// The constant is kept as the text that goes into the file, so that the default needs no
    /// fallback for the case where it fails to build. This is the test that keeps it honest —
    /// without it, a typo in `opt+cmd+13` would ship as a fresh install with no shortcut at all.
    func testAFreshInstallTogglesTheWidgetWithOptionCommandW() throws {
        let store = try makeStore()

        XCTAssertEqual(store.toggleShortcut?.displayed, "⌥⌘W")
    }

    func testAChosenShortcutSurvives() throws {
        let store = try makeStore()
        let chosen = try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: [.control, .shift]))

        store.setToggleShortcut(chosen)

        XCTAssertEqual(store.toggleShortcut, chosen)
    }

    /// Clearing has to be a state the file can hold, not the absence of a key: an absent key is
    /// how a fresh install looks, and that one gets `⌥⌘W` back.
    func testAClearedShortcutStaysCleared() throws {
        let store = try makeStore()

        store.setToggleShortcut(nil)

        XCTAssertNil(store.toggleShortcut)
    }

    func testChangingTheShortcutIsAnnouncedSoItCanBeRegisteredAgain() throws {
        let store = try makeStore()
        var announced = 0
        store.onChange = { setting in
            if case .toggleShortcut = setting {
                announced += 1
            }
        }

        store.setToggleShortcut(WidgetShortcut(keyCode: 96, modifiers: [.control]))
        store.setToggleShortcut(nil)

        XCTAssertEqual(announced, 2)
    }

    private func makeStore() throws -> WidgetSettingsStore {
        WidgetSettingsStore(preferences: try isolatedPreferences())
    }
}
