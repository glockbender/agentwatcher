import Foundation
import XCTest

@testable import AgentWatchCore

/// The rules that turn a working directory into a place a person can be told about.
///
/// Every fixture below is shaped like the real file on a machine with four sessions in two
/// JetBrains projects — the bench the measurements in `docs/session-focus-research.md` were
/// taken on.
final class SessionLocatorTests: XCTestCase {
    private let home = "/Users/someone"

    private var recentProjects: Data {
        Data(
            """
            <application>
              <component name="RecentProjectsManager">
                <option name="additionalInfo">
                  <map>
                    <entry key="$USER_HOME$/CommonProjects/mcp-hub">
                      <value>
                        <RecentProjectMetaInfo frameTitle="mcp-hub – Commit: go-review" opened="true">
                          <option name="activationTimestamp" value="1764846029679" />
                        </RecentProjectMetaInfo>
                      </value>
                    </entry>
                    <entry key="$USER_HOME$/GolandProjects/ai-reviewer">
                      <value>
                        <RecentProjectMetaInfo frameTitle="ai-reviewer – README.md" opened="true" />
                      </value>
                    </entry>
                    <entry key="/private/tmp/probe">
                      <value>
                        <RecentProjectMetaInfo />
                      </value>
                    </entry>
                  </map>
                </option>
              </component>
            </application>
            """.utf8
        )
    }

    func testTheFileNamesEveryProjectItRemembers() {
        let projects = JetBrainsRecentProjects.parse(recentProjects, userHome: home)

        XCTAssertEqual(
            projects.map(\.path),
            [
                "/Users/someone/CommonProjects/mcp-hub",
                "/Users/someone/GolandProjects/ai-reviewer",
                "/private/tmp/probe",
            ])
        XCTAssertEqual(projects[0].windowTitle, "mcp-hub – Commit: go-review")
        XCTAssertEqual(projects[0].name, "mcp-hub")
        XCTAssertTrue(projects[1].isOpen)
    }

    /// A project with no window title and no `opened` is still a project. The IDE writes both
    /// when it feels like it, and an entry dropped for a missing attribute would lose exactly
    /// the project a person just opened.
    func testAnEntryWithNoAttributesSurvives() {
        let projects = JetBrainsRecentProjects.parse(recentProjects, userHome: home)

        XCTAssertEqual(projects[2].path, "/private/tmp/probe")
        XCTAssertNil(projects[2].windowTitle)
        XCTAssertFalse(projects[2].isOpen)
    }

    func testTruncatedXMLKeepsWhatItManagedToRead() {
        let half = Data(
            """
            <application><component><option><map>
              <entry key="$USER_HOME$/one">
                <value><RecentProjectMetaInfo frameTitle="one" /></value>
              </entry>
              <entry key="$USER_HOME$/tw
            """.utf8
        )

        XCTAssertEqual(
            JetBrainsRecentProjects.parse(half, userHome: home).map(\.path),
            ["/Users/someone/one"]
        )
    }

    func testTheProjectContainingADirectoryIsFound() {
        let projects = JetBrainsRecentProjects.parse(recentProjects, userHome: home)

        let found = SessionPlace.project(
            containing: "/Users/someone/CommonProjects/mcp-hub/internal/server",
            among: projects
        )

        XCTAssertEqual(found?.name, "mcp-hub")
    }

    /// Nesting is real, and the inner project is the answer.
    func testTheLongestMatchWins() {
        let projects = [
            KnownProject(path: "/src", windowTitle: nil, isOpen: true),
            KnownProject(path: "/src/tools/inner", windowTitle: nil, isOpen: true),
            KnownProject(path: "/src/tools", windowTitle: nil, isOpen: true),
        ]

        XCTAssertEqual(
            SessionPlace.project(containing: "/src/tools/inner/pkg", among: projects)?.path,
            "/src/tools/inner"
        )
    }

    /// The answer points at a window, so a project that has one beats a closer one that
    /// does not.
    func testAnOpenProjectBeatsACloserClosedOne() {
        let projects = [
            KnownProject(path: "/src/tools", windowTitle: nil, isOpen: true),
            KnownProject(path: "/src/tools/inner", windowTitle: nil, isOpen: false),
        ]

        XCTAssertEqual(
            SessionPlace.project(containing: "/src/tools/inner/pkg", among: projects)?.path,
            "/src/tools"
        )
    }

    /// Compared as path components, not as text: a prefix of a name is not a parent
    /// directory, and matching on characters would put a session in the wrong project.
    func testANameThatMerelyStartsTheSameIsNotAParent() {
        let projects = [KnownProject(path: "/src/app", windowTitle: nil, isOpen: true)]

        XCTAssertNil(SessionPlace.project(containing: "/src/application/main", among: projects))
        XCTAssertEqual(SessionPlace.project(containing: "/src/app", among: projects)?.path, "/src/app")
    }

    /// `.` and `..` are folded by the rule itself, so matching stays a statement about the
    /// two strings.
    ///
    /// It used to be `URL.standardizedFileURL`, which is documented as possibly consulting
    /// the file system — and this file's own header cites the `AGENTS.md` rule that Core
    /// takes bytes somebody else read. Whatever that call does on one machine, a matching
    /// rule must not be able to answer differently on the next.
    func testAPathIsFoldedByTheRuleRatherThanByTheDisk() {
        let projects = [KnownProject(path: "/src/app", windowTitle: nil, isOpen: true)]

        XCTAssertEqual(
            SessionPlace.project(containing: "/src/./app/pkg", among: projects)?.path,
            "/src/app"
        )
        XCTAssertEqual(
            SessionPlace.project(containing: "/src/tools/../app/pkg", among: projects)?.path,
            "/src/app"
        )
        XCTAssertEqual(
            SessionPlace.project(containing: "/src//app//pkg", among: projects)?.path,
            "/src/app",
            "an empty component is a doubled separator and means nothing"
        )
        XCTAssertNil(
            SessionPlace.project(containing: "/src/app/../elsewhere", among: projects),
            "and folding is not the same as ignoring: this one steps back out of the project"
        )
    }

    func testADirectoryNoProjectOwnsHasNoProject() {
        let projects = JetBrainsRecentProjects.parse(recentProjects, userHome: home)

        XCTAssertNil(SessionPlace.project(containing: "/Users/someone/elsewhere", among: projects))
    }
}
