import AgentWatchCore
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

    /// On, and for the two states where a person has a next move: something is waiting for
    /// them, or something is finished for them to look at.
    func testTheMenuListsSessionsThatNeedYouOrAreDoneUntilAskedOtherwise() throws {
        let store = try makeStore()

        XCTAssertTrue(store.listsSessionsInMenu)
        XCTAssertEqual(store.menuSessionAttentions, [.needsPerson, .done])
    }

    /// Two keys, so switching the list off keeps the states chosen for it.
    func testTurningTheListOffKeepsTheStatesChosenForIt() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetSettingsStore(preferences: preferences)

        store.setMenuLists(.working, true)
        store.setMenuLists(.done, false)
        store.setListsSessionsInMenu(false)

        let reopened = WidgetSettingsStore(preferences: preferences)
        XCTAssertFalse(reopened.listsSessionsInMenu)
        XCTAssertEqual(reopened.menuSessionAttentions, [.needsPerson, .working])
    }

    /// Stored in the order the icon reads them, so the file does not reorder itself with
    /// every click.
    func testTheStatesAreStoredByNameInReadingOrder() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetSettingsStore(preferences: preferences)

        store.setMenuLists(.quiet, true)
        store.setMenuLists(.working, true)

        XCTAssertEqual(
            preferences.strings(forKey: "menuSessionAttentions"),
            ["needsPerson", "working", "done", "quiet"]
        )
    }

    /// A name this version does not know is skipped rather than failing the whole list, and a
    /// closed session is never listed — the icon counts it nowhere either (ADR-0002).
    func testANameThisVersionCannotListIsLeftOut() throws {
        let preferences = try isolatedPreferences()
        preferences.set(["done", "sleeping", "closed"], forKey: "menuSessionAttentions")

        XCTAssertEqual(WidgetSettingsStore(preferences: preferences).menuSessionAttentions, [.done])
    }

    /// Eight, where the menu stopped before its list could scroll, until a person picks another.
    func testTheMenuShowsEightSessionsBeforeItsListScrolls() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetSettingsStore(preferences: preferences)
        XCTAssertEqual(store.menuSessionsBeforeScrolling, 8)

        store.setMenuSessionsBeforeScrolling(12)

        XCTAssertEqual(WidgetSettingsStore(preferences: preferences).menuSessionsBeforeScrolling, 12)
    }

    /// Out of range is still "more" or "fewer", so it is clamped rather than refused — from
    /// the stepper and from an edited file alike, including a number no `Int` can hold.
    func testTheNumberOfSessionsBeforeScrollingStaysInRange() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetSettingsStore(preferences: preferences)
        let range = WidgetSettingsStore.menuSessionsBeforeScrollingRange

        store.setMenuSessionsBeforeScrolling(1)
        XCTAssertEqual(store.menuSessionsBeforeScrolling, range.lowerBound)
        store.setMenuSessionsBeforeScrolling(500)
        XCTAssertEqual(store.menuSessionsBeforeScrolling, range.upperBound)

        preferences.set(1e300, forKey: "menuSessionsBeforeScrolling")
        XCTAssertEqual(store.menuSessionsBeforeScrolling, range.upperBound)
        preferences.set(-4, forKey: "menuSessionsBeforeScrolling")
        XCTAssertEqual(store.menuSessionsBeforeScrolling, range.lowerBound)
        preferences.set(6.4, forKey: "menuSessionsBeforeScrolling")
        XCTAssertEqual(store.menuSessionsBeforeScrolling, 6)
    }

    func testChangingTheListIsAnnounced() throws {
        let store = try makeStore()
        var announced = 0
        store.onChange = { setting in
            if case .menuSessions = setting {
                announced += 1
            }
        }

        store.setListsSessionsInMenu(false)
        store.setMenuLists(.quiet, true)
        store.setMenuSessionsBeforeScrolling(10)

        XCTAssertEqual(announced, 3)
    }

    /// The sphere, counting every state, until a person picks otherwise.
    func testTheIconIsASphereOfEveryStateUntilAskedOtherwise() throws {
        let store = try makeStore()

        XCTAssertEqual(store.menuBarIconStyle, .sphere)
        XCTAssertEqual(store.menuBarIconAttentions, Set(SessionAttention.counted))
    }

    func testTheIconsStyleAndStatesAreKept() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetSettingsStore(preferences: preferences)

        store.setMenuBarIconStyle(.counts)
        store.setMenuBarIconShows(.quiet, false)
        store.setMenuBarIconShows(.done, false)

        let reopened = WidgetSettingsStore(preferences: preferences)
        XCTAssertEqual(reopened.menuBarIconStyle, .counts)
        XCTAssertEqual(reopened.menuBarIconAttentions, [.needsPerson, .working])
        XCTAssertEqual(preferences.strings(forKey: "menuBarIconAttentions"), ["needsPerson", "working"])
    }

    /// Separate from the states the menu lists: choosing what the icon counts must not
    /// change what the menu lists, or the other way round.
    func testTheIconsStatesAreNotTheMenusStates() throws {
        let store = try makeStore()

        store.setMenuBarIconShows(.needsPerson, false)
        store.setMenuLists(.quiet, true)

        XCTAssertEqual(store.menuSessionAttentions, [.needsPerson, .done, .quiet])
        XCTAssertEqual(store.menuBarIconAttentions, [.working, .done, .quiet])
    }

    /// The menu greys the last state, but the menu is not the only writer: the store refuses
    /// the write too, and says nothing changed.
    func testTheLastStateCannotBeTakenOutOfTheIcon() throws {
        let store = try makeStore()
        var announced = 0
        store.onChange = { setting in
            if case .menuBarIcon = setting {
                announced += 1
            }
        }

        for attention in [SessionAttention.working, .done, .quiet, .needsPerson] {
            store.setMenuBarIconShows(attention, false)
        }

        XCTAssertEqual(store.menuBarIconAttentions, [.needsPerson])
        XCTAssertEqual(announced, 3, "a refused write was announced")
    }

    /// An empty list or a name this version does not know may not leave the icon blank. The
    /// names are the two styles taken out before any release, the pie and the plain glyph: a
    /// build from between left them behind.
    func testAnIconFileThisVersionCannotReadStillDrawsSomething() throws {
        let preferences = try isolatedPreferences()
        for retired in ["pie", "appIcon"] {
            preferences.set(retired, forKey: "menuBarIconStyle")
            XCTAssertEqual(WidgetSettingsStore(preferences: preferences).menuBarIconStyle, .sphere, retired)
        }
        preferences.set([String](), forKey: "menuBarIconAttentions")
        XCTAssertEqual(
            WidgetSettingsStore(preferences: preferences).menuBarIconAttentions, Set(SessionAttention.counted))

        preferences.set(["done", "sleeping", "closed"], forKey: "menuBarIconAttentions")
        XCTAssertEqual(WidgetSettingsStore(preferences: preferences).menuBarIconAttentions, [.done])
    }

    private func makeStore() throws -> WidgetSettingsStore {
        WidgetSettingsStore(preferences: try isolatedPreferences())
    }
}
