mod support;

use nix::errno::Errno;
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

fn eventually<T>(label: &str, mut read: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(value) = read() {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {label}");
        thread::sleep(Duration::from_millis(20));
    }
}

#[derive(Clone, Copy)]
enum Close {
    Signal,
    Output,
    Parent,
}

fn cancel_during_preparation(close: Close) {
    let root = support::TestDirectory::new("git-cli");
    let git = root.path().join("git");
    fs::write(
        &git,
        "#!/bin/sh\necho $$ > preparing.pid\nexec /bin/sleep 12\n",
    )
    .unwrap();
    fs::set_permissions(git, fs::Permissions::from_mode(0o700)).unwrap();

    let binary = env!("CARGO_BIN_EXE_agent-watch-git");
    let args = json!({
        "repository": root.path(), "destination": "refs/heads/example", "delete": true
    });
    let mut command = if matches!(close, Close::Parent) {
        // Keep the caller's output open beyond its exit, so only parent loss can stop the CLI.
        let mut parent = Command::new("/bin/sh");
        parent.args(["-c", r#""$@" & echo $! > cli.pid; wait"#, "test", binary]);
        parent
    } else {
        Command::new(binary)
    };
    let mut caller = command
        .arg("push")
        .arg(args.to_string())
        .current_dir(root.path())
        .env_clear()
        .env("PATH", root.path())
        .env("HOME", root.path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let read_pid = |file: &str| {
        eventually(file, || {
            fs::read_to_string(root.path().join(file))
                .ok()?
                .trim()
                .parse::<i32>()
                .ok()
                .map(Pid::from_raw)
        })
    };
    let preparing_git = read_pid("preparing.pid");
    let caller_pid = Pid::from_raw(i32::try_from(caller.id()).unwrap());
    let cli_pid = if matches!(close, Close::Parent) {
        read_pid("cli.pid")
    } else {
        caller_pid
    };
    match close {
        Close::Signal => kill(caller_pid, Signal::SIGTERM).unwrap(),
        Close::Output => drop(caller.stdout.take()),
        Close::Parent => kill(caller_pid, Signal::SIGKILL).unwrap(),
    }
    let status = eventually("caller exit", || caller.try_wait().unwrap());
    assert!(!status.success());
    for pid in [preparing_git, cli_pid] {
        eventually("reaped process", || {
            (kill(pid, None) == Err(Errno::ESRCH)).then_some(())
        });
    }
}

#[test]
fn cli_stops_on_signal() {
    cancel_during_preparation(Close::Signal);
}

#[test]
fn cli_stops_when_output_reader_closes() {
    cancel_during_preparation(Close::Output);
}

#[test]
fn cli_stops_when_parent_dies() {
    cancel_during_preparation(Close::Parent);
}

#[cfg(not(feature = "mcp-fixture"))]
#[test]
fn production_binary_requires_an_explicit_command_and_never_serves_mcp() {
    for args in [vec![], vec!["--mcp-forms"], vec!["--client-forms"]] {
        let output = Command::new(env!("CARGO_BIN_EXE_agent-watch-git"))
            .args(args)
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8(output.stderr).unwrap().contains("Usage:"));
    }
}
