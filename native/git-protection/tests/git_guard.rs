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
