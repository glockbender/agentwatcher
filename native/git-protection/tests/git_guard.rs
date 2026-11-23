mod support;

use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};
use support::TestDirectory;

struct Bundle {
    root: TestDirectory,
    hook: PathBuf,
    cli: PathBuf,
}

impl Bundle {
    fn new() -> Self {
        let root = TestDirectory::new("guard");
        let contents = root.path().join("Example Application.app/Contents");
        let hook = contents.join("Resources/GitProtection/hooks/git-guard.sh");
        let cli = contents.join("MacOS/AgentWatchGit");
        for dest in [&hook, &cli] {
            std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        }
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Resources/GitProtection/hooks/git-guard.sh"),
            &hook,
        )
        .unwrap();
        std::fs::copy(env!("CARGO_BIN_EXE_agent-watch-git"), &cli).unwrap();
        Self { root, hook, cli }
    }

    fn command(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.current_dir(self.root.path()).env_clear().envs([
            ("HOME", self.root.path().to_str().unwrap()),
            ("PATH", "/usr/bin:/bin"),
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_ALLOW_PROTOCOL", "file"),
        ]);
        cmd
    }

    fn repo(&self, name: &str) -> PathBuf {
        let path = self.root.path().join(name);
        std::fs::create_dir(&path).unwrap();
        self.git(&path, &["init", "--template=", "-b", "main"]);
        self.git(&path, &["commit", "--allow-empty", "-m", "Fixture"]);
        path
    }

    fn git(&self, dir: &Path, args: &[&str]) {
        let output = self
            .command("git")
            .current_dir(dir)
            .args([
                "-c",
                "user.name=Test",
                "-c",
                "user.email=fixture@example.invalid",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn spawn(&self, args: &[&str]) -> Child {
        self.command("/bin/bash")
            .arg(&self.hook)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }

    fn invoke(&self, host: &str, payload: &str) -> String {
        let args = if host == "codex" {
            &["--host", "codex"][..]
        } else {
            &[]
        };
        let mut child = self.spawn(args);
        child
            .stdin
            .take()
            .unwrap()
            .write_all(payload.as_bytes())
            .unwrap();
        let output = finish(child);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }
}

fn finish(mut child: Child) -> Output {
    // The hook has six seconds to inspect Git, starting after macOS launches the binary.
    let deadline = Instant::now() + Duration::from_secs(20);
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("Git hook timed out");
        }
        std::thread::sleep(Duration::from_millis(3));
    }
    child.wait_with_output().unwrap()
}

fn denial(output: &str) -> String {
    let parsed: Value = serde_json::from_str(output).unwrap();
    let verdict = &parsed["hookSpecificOutput"];
    assert_eq!(verdict["hookEventName"], "PreToolUse");
    assert_eq!(verdict["permissionDecision"], "deny");
    verdict["permissionDecisionReason"].as_str().unwrap().into()
}

#[test]
fn both_hook_hosts_preserve_shell_decisions() {
    let bundle = Bundle::new();
    let main = bundle.repo("main");
    let feature = bundle.repo("feat");
    bundle.git(&feature, &["switch", "-c", "feature-x"]);
    bundle.git(&feature, &["tag", "local-tag"]);
    for branch in ["widget-row-redesign", "old-feature", "feature-x"] {
        bundle.git(
            &feature,
            &[
                "update-ref",
                &format!("refs/remotes/origin/{branch}"),
                "HEAD",
            ],
        );
    }
    let cases: Vec<(String, String, String)> =
        serde_json::from_str(include_str!("fixtures/guard-decisions.json")).unwrap();
    let mut failures = Vec::new();
    for (want, command, folder) in cases {
        let command = command
            .replace("{feat}", feature.to_str().unwrap())
            .replace("{main}", main.to_str().unwrap());
        let cwd = match folder.as_str() {
            "main" => &main,
            "feat" => &feature,
            _ => panic!("unknown fixture {folder}"),
        };
        for (host, input) in [
            ("claude", json!({"command": command})),
            ("codex", json!({"cmd": command})),
        ] {
            let result = bundle.invoke(host, &json!({"cwd": cwd, "tool_input": input}).to_string());
            match (want.as_str(), result.is_empty()) {
                ("allow", true) => {}
                ("deny", false) => {
                    denial(&result);
                }
                _ => failures.push(format!(
                    "{host} expected {want}: {command:?}, got {result:?}"
                )),
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn both_hosts_check_configured_push_routing() {
    let bundle = Bundle::new();
    let repo = bundle.repo("feat");
    bundle.git(&repo, &["switch", "-c", "feature-x"]);
    bundle.git(
        &repo,
        &["config", "remote.example.push", "HEAD:refs/heads/main"],
    );
    bundle.git(&repo, &["config", "remote.backup.mirror", "true"]);

    for host in ["claude", "codex"] {
        let check = |command: &str| {
            bundle.invoke(
                host,
                &json!({"cwd": repo, "tool_input": {"command": command}}).to_string(),
            )
        };
        for command in [
            "git push",
            "git push example",
            "git push --repo=example",
            "git push example feature-x",
            "git push --repo=origin example",
        ] {
            assert!(denial(&check(command)).contains("depends on Git configuration"));
        }
        assert!(denial(&check("git push backup")).contains("mirror push"));
        assert!(
            denial(&check("git -c push.default=upstream push origin")).contains("push routing")
        );
        assert!(check("git push example HEAD:refs/heads/feature-x").is_empty());
        assert!(check("git push --dry-run backup").is_empty());
        assert!(
            denial(&check("git push origin --delete refs/heads/topic"))
                .contains("deletes branch 'topic'")
        );
        assert!(
            denial(&check("git push origin --delete refs/tags/v1")).contains("deletes tag 'v1'")
        );
    }

    bundle.git(&repo, &["config", "push.default", "upstream"]);
    let result = bundle.invoke(
        "codex",
        &json!({
            "cwd": repo,
            "tool_input": {"command": "git push origin feature-x"}
        })
        .to_string(),
    );
    assert!(denial(&result).contains("depends on Git configuration"));
}

#[test]
fn both_hosts_deny_implicit_push_without_a_known_branch() {
    let bundle = Bundle::new();
    let payload = json!({
        "cwd": bundle.root.path(),
        "tool_input": {"command": "git push"}
    });
    for host in ["claude", "codex"] {
        let reason = denial(&bundle.invoke(host, &payload.to_string()));
        assert!(reason.contains("current branch could not be determined"));
    }
}

#[test]
fn both_hosts_direct_deletion_to_the_installed_cli() {
    let bundle = Bundle::new();
    for host in ["claude", "codex"] {
        let output = bundle.invoke(
            host,
            r#"{"tool_input":{"command":"git push origin --delete topic"}}"#,
        );
        let reason = denial(&output);
        assert!(
            reason.contains(&format!(
                "'{}' push",
                bundle.cli.canonicalize().unwrap().display()
            )),
            "{reason}"
        );
        assert!(reason.contains("delete to true"), "{reason}");
        assert!(
            bundle
                .invoke(host, r#"{"tool_input":{"command":"git branch topic"}}"#)
                .is_empty()
        );
        denial(&bundle.invoke(host, "invalid"));
    }
}

#[test]
fn codex_command_workdir_overrides_session_cwd() {
    let bundle = Bundle::new();
    let main = bundle.repo("main");
    let feature = bundle.repo("feat");
    bundle.git(&feature, &["switch", "-c", "feature"]);
    denial(&bundle.invoke(
        "codex",
        &json!({"cwd": feature, "tool_input":{"cmd":"git push", "workdir": main}}).to_string(),
    ));
}

#[test]
fn incomplete_event_is_denied_before_the_client_timeout() {
    let bundle = Bundle::new();
    let mut child = bundle.spawn(&[]);
    let mut input = child.stdin.take().unwrap();
    input.write_all(b"{").unwrap();
    let output = finish(child);
    drop(input);

    assert!(output.status.success());
    let reason = denial(std::str::from_utf8(&output.stdout).unwrap());
    assert!(reason.contains("hook deadline"), "{reason}");
}

#[test]
fn cancelling_the_hook_reaps_its_git_query() {
    use nix::errno::Errno;
    use nix::sys::signal::{Signal, kill};
    use nix::unistd::Pid;
    use std::os::unix::fs::PermissionsExt;

    let bundle = Bundle::new();
    let marker = bundle.root.path().join("git-query.pid");
    let inspector = bundle.root.path().join("git");
    std::fs::write(
        &inspector,
        "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$AW_TEST_GIT_PID_FILE\"\nexec /bin/sleep 30\n",
    )
    .unwrap();
    std::fs::set_permissions(&inspector, std::fs::Permissions::from_mode(0o700)).unwrap();

    let mut child = bundle
        .command(bundle.cli.to_str().unwrap())
        .arg("hook")
        .env("PATH", bundle.root.path())
        .env("AW_TEST_GIT_PID_FILE", &marker)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(br#"{"tool_input":{"command":"git push"}}"#)
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let query = loop {
        if let Some(pid) = std::fs::read_to_string(&marker)
            .ok()
            .and_then(|text| text.trim().parse().ok())
        {
            break Pid::from_raw(pid);
        }
        assert!(Instant::now() < deadline, "Git inspection did not start");
        std::thread::sleep(Duration::from_millis(10));
    };
    kill(
        Pid::from_raw(i32::try_from(child.id()).unwrap()),
        Signal::SIGTERM,
    )
    .unwrap();
    let output = finish(child);
    denial(std::str::from_utf8(&output.stdout).unwrap());
    assert_eq!(kill(query, None), Err(Errno::ESRCH));
}

#[test]
fn installation_check_returns_with_stdin_open_and_rejects_missing_cli() {
    let bundle = Bundle::new();
    let checked = finish(bundle.spawn(&["--check"]));
    assert!(checked.status.success());
    assert_eq!(checked.stdout, b"agent-watch-git-hook-ok\n");
    assert!(checked.stderr.is_empty());
    std::fs::rename(&bundle.cli, bundle.cli.with_extension("missing")).unwrap();
    let missing = finish(bundle.spawn(&["--check"]));
    assert!(!missing.status.success());
    assert!(!missing.stderr.is_empty());
    for host in ["claude", "codex"] {
        denial(&bundle.invoke(
            host,
            r#"{"tool_input":{"command":"git push origin --delete topic"}}"#,
        ));
    }
}

impl Bundle {
    fn branch_types(&self, text: &str) {
        let path = self
            .root
            .path()
            .join("Library/Application Support/AgentWatch/git-branch-types.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    /// A working copy with a local destination whose default branch is `trunk`, fetched so
    /// that every remote branch is known locally.
    fn repo_with_remote(&self) -> PathBuf {
        let repo = self.repo("typed");
        let remote = self.root.path().join("destination.git");
        let remote_path = remote.to_str().unwrap();
        self.git(&repo, &["init", "--bare", "--template=", remote_path]);
        self.git(&repo, &["remote", "add", "origin", remote_path]);
        for branch in [
            "trunk",
            "agent/x",
            "agent/old",
            "agent/tagged",
            "agent/kept",
            "locked/x",
            "feature/y",
        ] {
            self.git(
                &repo,
                &["push", "-q", "origin", &format!("HEAD:refs/heads/{branch}")],
            );
        }
        self.git(
            &repo,
            &[
                "--git-dir",
                remote_path,
                "symbolic-ref",
                "HEAD",
                "refs/heads/trunk",
            ],
        );
        self.git(&repo, &["fetch", "-q", "origin"]);
        self.git(&repo, &["branch", "trunk"]);
        self.git(&repo, &["branch", "heads/trunk"]);
        // A branch named like a tag the remote has, and a remote defined outside the config.
        self.git(&repo, &["push", "-q", "origin", "HEAD:refs/tags/v1"]);
        self.git(&repo, &["branch", "v1"]);
        std::fs::create_dir_all(repo.join(".git/branches")).unwrap();
        std::fs::write(
            repo.join(".git/branches/legacy"),
            format!("{remote_path}#main\n"),
        )
        .unwrap();
        self.git(&repo, &["branch", "locked/x"]);
        self.git(&repo, &["switch", "-q", "-c", "agent/x"]);
        self.git(&repo, &["tag", "agent/tagged"]);
        self.git(
            &repo,
            &[
                "config",
                "--add",
                "mothership.protectedBranch",
                "agent/kept",
            ],
        );
        repo
    }
}

const HOOK_TYPES: &str = r#"{"version":1,"types":[
    {"name":"Drafts","patterns":["agent/*","heads/*","v*","trunk","main"],"level":"none"},
    {"name":"Locked","patterns":["locked/*"],"level":"forbid"},
    {"name":"Features","patterns":["feature/*"],"level":"click"}]}"#;

#[test]
fn branch_types_decide_force_pushes_and_deletions_in_the_hook() {
    let bundle = Bundle::new();
    let repo = bundle.repo_with_remote();
    bundle.branch_types(HOOK_TYPES);
    let allowed = [
        "git push -f origin agent/x",
        "git push --force-with-lease",
        "git push -f",
        "git push origin +agent/x",
        "git push -f origin HEAD",
        "git push -f origin HEAD:refs/heads/agent/new",
        "git push origin --delete refs/heads/agent/old",
        "git push origin :refs/heads/agent/old",
        "git push -u --force-with-lease=agent/x origin agent/x",
    ];
    let checked = [
        // The floor: main, the remote's default branch and a project rule keep the window.
        ("git push -f origin HEAD:refs/heads/main", "force push"),
        ("git push -f origin HEAD:refs/heads/trunk", "force push"),
        ("git push -f origin trunk", "force push"),
        (
            "git push origin --delete refs/heads/trunk",
            "deletes branch 'trunk'",
        ),
        (
            "git push origin --delete refs/heads/agent/kept",
            "deletes branch 'kept'",
        ),
        // A short <dst> is matched against the remote's refs, where it can be a tag or another
        // branch, so only refs/heads/ goes without a window.
        (
            "git push origin --delete agent/old",
            "deletes branch 'agent/old'",
        ),
        ("git push origin :agent/old", "deletes branch 'agent/old'"),
        ("git push -f origin HEAD:agent/old", "force push"),
        ("git push origin --delete tags/agent/tagged", "deletes"),
        ("git push -f origin HEAD:heads/trunk", "force push"),
        // A local name must resolve to its own refs/heads/ ref.
        ("git push -f origin heads/trunk", "force push"),
        // What the hook reads must be what the push sees: one plain `git push`, nothing else.
        ("git push -f origin agent/x 2>&1 | tail -3", "force push"),
        (
            "git checkout -b agent/t; git push -f origin HEAD",
            "force push",
        ),
        (
            "echo 'ref: refs/heads/main' > .git/HEAD; git push -f origin HEAD",
            "force push",
        ),
        ("true && git push -f origin agent/x", "force push"),
        ("bash -c 'git push -f origin agent/x'", "force push"),
        ("git push -f origin v1:v1", "force push"),
        ("git push -f origin agent/x:agent/x", "force push"),
        (
            "git push -f origin HEAD <<EOF\n$(git symbolic-ref HEAD refs/heads/main)\nEOF",
            "force push",
        ),
        (
            "git push -f origin HEAD 2>${x:-$(git symbolic-ref HEAD refs/heads/main)}/dev/null",
            "force push",
        ),
        (
            "git push -f --force-with-lease=${x#$(git symbolic-ref HEAD refs/heads/main)} origin HEAD",
            "force push",
        ),
        ("git push -f origin 'agent/x'", "force push"),
        ("git push -f legacy", "force push"),
        ("X=1 git push -f origin agent/x", "force push"),
        ("git -C . push -f origin agent/x", "force push"),
        ("git push --mirror origin", "force push"),
        ("git push -f --tags origin agent/x", "force push"),
        (
            "git push -f --recurse-submodules=on-demand origin agent/x",
            "force push",
        ),
        (
            "git push -f --receive-pack=git-receive-pack origin agent/x",
            "force push",
        ),
        // Other types and other risks keep today's checks.
        ("git push -f origin HEAD:refs/heads/feature/y", "force push"),
        (
            "git push -f origin agent/x HEAD:refs/heads/feature/y",
            "force push",
        ),
        ("git push -f --all origin", "--all"),
        ("git push -f origin 'agent/*'", "matching branches"),
        ("git push -f --prune origin agent/x", "--prune"),
        ("git -c push.default=matching push -f", "push routing"),
        ("git push -f /elsewhere agent/x", "force push"),
    ];
    for host in ["claude", "codex"] {
        let check = |command: &str| {
            bundle.invoke(
                host,
                &json!({"cwd": repo, "tool_input": {"command": command}}).to_string(),
            )
        };
        for command in allowed {
            assert_eq!(check(command), "", "{host} should allow {command}");
        }
        for (command, risk) in checked {
            let output = check(command);
            assert!(!output.is_empty(), "{host} should deny {command}");
            let reason = denial(&output);
            assert!(reason.contains(risk), "{host} {command}: {reason}");
            assert!(reason.contains("push '<JSON object>'"), "{reason}");
            assert!(!reason.contains("forbidden"), "{reason}");
        }
        for (command, refusal) in [
            (
                "git push origin --delete refs/heads/locked/x",
                "deleting branch 'locked/x'",
            ),
            (
                "git push -f origin HEAD:refs/heads/locked/x",
                "force push to 'locked/x'",
            ),
            (
                "git push -f origin locked/x 2>&1 | tail -3",
                "force push to 'locked/x'",
            ),
        ] {
            let reason = denial(&check(command));
            assert!(reason.contains(refusal), "{reason}");
            assert!(
                reason.contains("forbidden by branch type 'Locked'"),
                "{reason}"
            );
            assert!(reason.contains("run it in a terminal"), "{reason}");
            assert!(!reason.contains("push '<JSON object>'"), "{reason}");
        }
        // A short name may not be the branch: the executor decides it with the exact ref.
        assert!(!denial(&check("git push origin --delete locked/x")).contains("forbidden"));
        let both = denial(&check(
            "git push -f origin HEAD:refs/heads/locked/x HEAD:refs/heads/feature/y",
        ));
        assert!(both.contains("forbidden by branch type 'Locked'"), "{both}");
        assert!(
            both.contains("force push. For one intended reference"),
            "{both}"
        );
    }
}

#[test]
fn without_a_readable_table_the_hook_checks_as_before() {
    let bundle = Bundle::new();
    let repo = bundle.repo_with_remote();
    for table in [
        None,
        Some("{"),
        Some(&HOOK_TYPES.replace("\"none\"", "\"sometimes\"")[..]),
    ] {
        if let Some(table) = table {
            bundle.branch_types(table);
        }
        for command in [
            "git push -f origin agent/x",
            "git push origin --delete agent/old",
            "git push origin --delete locked/x",
        ] {
            let reason = denial(&bundle.invoke(
                "claude",
                &json!({"cwd": repo, "tool_input": {"command": command}}).to_string(),
            ));
            assert!(
                reason.contains("push '<JSON object>'"),
                "{command}: {reason}"
            );
        }
    }
}
