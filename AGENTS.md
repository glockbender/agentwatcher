# Agent Watch development guide

## Architecture invariants

- `AgentWatchApp` owns macOS lifecycle and presentation only.
- `AgentWatchCore` holds deterministic domain state and must not import AppKit. It reads the file
  system only where the file system is the subject — finding an agent's file among file names.
- Lifecycle facts are deterministic; LLM output must never become the source of session state.
- Monitoring failures are fail-open and must not block an agent.
- Avoid polling while there are no active sessions.
- `AgentWatchLookup` asks the machine and answers; `AgentWatchSender` builds a request and
  sends it. Neither does the other's job — that is what the two targets are for.

## Required checks

Two gates, both installed by `task setup`:

- **commit** — `task verify`: format, the document checks, tests, debug and release builds, app
  bundle. Does not cover `ide-plugin/`.
- **push** — `task verify-all`: the above plus the IDE plugin (`task plugin-check`) and the
  network probe of the published release (`task probe-update`). The plugin is skipped where no
  JetBrains IDE is installed. A tag or a deletion is pushed without the gate.

Both gates check the working tree and refuse to run when it is not exactly what goes out: a commit
with unstaged or untracked files beside it, a push with uncommitted changes, or a push of a branch
that is not checked out.

The IDE plugin needs nothing installed: its Gradle wrapper fetches Gradle and a JDK. It compiles
against GoLand or IntelliJ IDEA 2026.1 or newer from this machine, or downloads one when none is
here (`task plugin-download` forces that). Only `task plugin` and `task plugin-download` stage the
ZIP, in `~/Library/Application Support/AgentWatch/ide-plugin/` — the one directory Tooling's
`Open Plugins` offers a plugin from.

Add or update tests for every domain-state transition. Keep UI thin enough that important behaviour
can be tested in `AgentWatchCoreTests` without launching an application.

## Local development

- **A local bundle loses macOS permissions on every rebuild unless it is signed with a
  certificate.** `scripts/build-app.sh` uses one called `Agent Watch Developer` when the keychain
  holds it. To create it: Keychain Access → Certificate Assistant → Create a Certificate…, Self
  Signed Root, Code Signing. It need not be trusted, so `security find-identity -v` will not list
  it.
- **`task verify` rebuilds `dist/` from scratch**, so hooks installed from `dist/AgentWatch.app`
  point at a bundle that will be replaced. Copy it to `/Applications` and install from the copy.
- **A debug copy that installs hooks needs `AGENT_WATCH_HOME_DIR` beside `AGENT_WATCH_SUPPORT_DIR`.**
  It names the home that holds `.claude` and `.codex`. `HOME` cannot do it: Foundation returns the
  account's home whatever `HOME` says, while both agents follow `HOME`. Give the same value to a
  sender you run by hand, or it reports its default folder as another one.
- **One Agent Watch runs at a time.** Quit an installed copy before running a build:
  `osascript -e 'quit app "AgentWatch"'`.
- **The shared Xcode scheme is committed on purpose:** Xcode builds only the products a scheme
  names, and a generated scheme leaves out `AgentWatchSend`.
- When Xcode is installed but `xcode-select -p` still points at the Command Line Tools:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer task verify`.
- **A click on the widget is checked with a real mouse event, not by calling `mouseDown`:** one
  press can both reach a see-through view and drag the widget, and a test that calls `mouseDown`
  cannot see the drag. Start a debug copy with
  `open --env AGENT_WATCH_SUPPORT_DIR=<scratch directory> -n <bundle>` — started straight from a
  shell, it never registers with Launch Services and Accessibility cannot see its windows — find
  its widget among the process's windows (it is not always window 1) and post the click with
  `CGEventPost`; System Events' `click at` does not reach the row.
- **`task e2e-update` updates a copy in a clean macOS, failures included.** It runs in a throwaway
  clone of the Tart machine `aw-golden` (`.claude/skills/readme-media/vm.md` sets it up) and puts
  nothing on this screen. It takes a few minutes, so the push gate leaves it out and the release
  skill runs it before every tag.
- **The README's pictures are drawn from code; redraw them in the change that alters what they
  show.** `task readme-images` draws them offscreen from the invented sessions in
  `ReadmeShowcase`. `task readme-menu` opens a real menu for a second and takes only its window,
  with Screen Recording permission. Both refuse to run unless a Retina display is the main one.
  The clips (`docs/images/clip-*.avif`) are screen recordings: the `readme-media` skill records and
  cuts them again.

## Documentation

Keep documents current as part of the change, not after it. Read `docs/implementation-plan.md`
before implementing: it holds status, next milestones and deferred decisions.

`docs/` holds one document per subject, and each says in its opening lines what it holds and what
it leaves out — find the owner of a subject there, not in a list. `task lint` checks the links
between documents, the opening, a limit of 500 lines and the status line of every ADR.

- **Behaviour** goes into the document that owns the subject, in the present tense. History stays
  in git. A document past 500 lines holds several subjects: split it.
- **Plans and open work** go into the plan documents, not into the ones that describe behaviour.
- **A decision** that is hard to reverse, surprising without the reason, and the result of a real
  trade-off gets an ADR in `docs/adr/` — including the deliberate no-s, which stop the next review
  from suggesting them again. One decision per file, numbered and never renumbered, with a status
  line. Code cites `ADR-0001`; a passage is cited by its heading, never by a section number.
- **A measured fact** about Claude Code, Codex, an IDE or macOS carries its version where it is
  stated: `(замер: Claude Code 2.1.272)` in a document, `Measured on Claude Code 2.1.272` in a code
  comment. `docs/measurements.md` is generated from these by `task measurements`; never edit it.
- **A closed study** moves to `docs/research/` with an archive banner. An article in
  `docs/articles/` is a snapshot of its date. Neither is updated afterwards.
- **`CHANGELOG.md`** is written at release time by the `release` skill, from the commits since the
  last tag. Only a change the person has to act on after updating goes into `[Unreleased]` at once,
  in the commit that makes it.
- **`README.md`** is for somebody installing the app: short, describing the latest commit — no
  version numbers, no "coming in the next release". Developer notes belong in this file.
- **`TROUBLESHOOTING.md`** is for the same reader: something that looks wrong while the app works as
  designed. Add an entry whenever an investigation ends in "this is how the agent or macOS
  behaves". An entry is `## <what the person sees>` and three paragraphs: **Why:**, **What to do:**
  and **Checked on:** (the version, or `not recorded`). `task lint` checks the shape; whether an
  entry is missing, you decide.
