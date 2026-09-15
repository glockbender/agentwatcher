import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// What each text part of a row says, and what the three parts with a choice say under each
/// of their choices.
///
/// Asked of the text rather than of a drawn row: a label's string is the whole question here,
/// and `RowTemplateDrawingTests` is where the views are. The choices had tests for being
/// stored and for being read back, and none for what they put in a row — so `Name · effort`
/// could have stored perfectly and drawn the bare name.
final class RowPartTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - The model, with and without the effort

    func testTheModelPartSaysTheEffortOnlyWhenItIsAskedTo() {
        var codex = testSession(source: .codex, title: "Port the probe", lastObservedAt: now)
        codex.modelName = "gpt-5-codex"
        codex.reasoningEffort = "high"

        XCTAssertEqual(
            rowPartText(.model, for: codex, layout: RowLayout(parts: [.model, .gap], modelStyle: .plain)),
            "gpt-5-codex"
        )
        XCTAssertEqual(
            rowPartText(.model, for: codex, layout: RowLayout(parts: [.model, .gap], modelStyle: .effort)),
            "gpt-5-codex · high"
        )
    }

    /// Claude writes no effort, so the same choice has to leave its rows alone rather than
    /// draw a separator with nothing after it.
    func testAModelWithNoEffortReportedIsDrawnWithoutASeparator() {
        var claude = testSession(title: "Fix the row", lastObservedAt: now)
        claude.modelName = "claude-opus-5"

        XCTAssertEqual(
            rowPartText(.model, for: claude, layout: RowLayout(parts: [.model, .gap], modelStyle: .effort)),
            "claude-opus-5"
        )
    }

    // MARK: - The context, in either number or both

    func testTheContextPartDrawsWhicheverNumberWasAskedFor() {
        var session = testSession(title: "Fix the row", lastObservedAt: now)
        session.contextTelemetry = .init(totalInputTokens: 212_000, usedPercentage: 63)

        XCTAssertEqual(widgetContextText(for: session, style: .percent), "63%")
        XCTAssertEqual(widgetContextText(for: session, style: .tokens), "212k")
        XCTAssertEqual(widgetContextText(for: session, style: .both), "63% · 212k")
    }

    /// Claude reports a count and no share. Asking for the share then falls back to the count
    /// rather than to an empty column, which would read as "context unknown" for a session
    /// whose context is known.
    func testAskingForAShareNobodyReportedDrawsTheCount() {
        var session = testSession(title: "Fix the row", lastObservedAt: now)
        session.contextTelemetry = .init(totalInputTokens: 85_000)

        XCTAssertEqual(widgetContextText(for: session, style: .percent), "85k")
        XCTAssertEqual(widgetContextText(for: session, style: .both), "85k")
    }

    // MARK: - The parts with nothing to choose

    /// The row and the hover card say these in the same words. Two spellings of one fact
    /// would make one of them wrong, with no way for a reader to tell which.
    func testThePartsWithoutAChoiceSayWhatTheCardSays() {
        var codex = testSession(source: .codex, title: "Port the probe", lastObservedAt: now)
        codex.clientKind = .cli
        codex.threadKind = .subagent
        codex.threadNickname = "Darwin"
        codex.gitBranch = "row-format"
        let layout = RowLayout.standard

        XCTAssertEqual(rowPartText(.host, for: codex, layout: layout), "CLI")
        XCTAssertEqual(rowPartText(.thread, for: codex, layout: layout), "subagent Darwin")
        XCTAssertEqual(rowPartText(.branch, for: codex, layout: layout), "row-format")
        XCTAssertEqual(rowPartText(.project, for: codex, layout: layout), codex.projectName)
    }

    /// A person's own session has no thread worth naming, and a part with nothing to say is
    /// left out of the row rather than drawn empty.
    func testAPartTheSessionCannotFillSaysNothing() {
        var plain = testSession(title: "Fix the row", lastObservedAt: now)
        plain.threadKind = .user
        plain.gitBranch = nil
        plain.modelName = nil

        for part in [RowPart.thread, .branch, .model] {
            XCTAssertNil(rowPartText(part, for: plain, layout: .standard), "\(part) drew something")
        }
    }

    /// The parts that are not text at all: a dot, a picture, a number beside a symbol, and the
    /// row's own slack. They are drawn by the row, and asking them for a word says nothing.
    func testThePartsThatAreNotTextHaveNoneOfIt() {
        let session = testSession(title: "Fix the row", lastObservedAt: now)

        for part in [RowPart.timer, .lamp, .agent, .fault, .counters, .context, .gap] {
            XCTAssertNil(rowPartText(part, for: session, layout: .standard), "\(part) is not a word")
        }
    }
}
