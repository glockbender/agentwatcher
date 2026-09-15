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

    func testTheSessionTopicIsShownUnlessItIsTurnedOff() throws {
        let store = try makeStore()

        XCTAssertTrue(store.showsSessionTopic)

        store.setShowsSessionTopic(false)
        XCTAssertFalse(store.showsSessionTopic)
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
        // Clamped to a value it already holds, which is the same drag against the end stop.
        store.setScale(9)
        store.setScale(WidgetSettingsStore.maximumScale)

        XCTAssertEqual(announced, 2, "one for each size the widget actually changed to")
    }

    private func makeStore() throws -> WidgetSettingsStore {
        WidgetSettingsStore(preferences: try isolatedPreferences())
    }
}
