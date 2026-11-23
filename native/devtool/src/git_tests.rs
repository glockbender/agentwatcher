use std::{env, fs, path::PathBuf, process::Command};

fn checked(command: &mut Command) -> Result<(), String> {
    let status = command.status().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "{} exited with {status}",
            command.get_program().to_string_lossy()
        ))
    }
}
fn cargo() -> Command {
    let mut c = Command::new("rustup");
    c.args(["run", "1.98.1", "cargo"]);
    c
}
fn runner() -> Command {
    let mut c = cargo();
    c.args([
        "run",
        "--locked",
        "--quiet",
        "--manifest-path",
        "native/git-protection-e2e/Cargo.toml",
        "--",
    ]);
    c
}

pub(super) fn run(command: &str, args: &[String]) -> Result<(), String> {
    if command == "git-e2e" {
        use std::os::unix::process::CommandExt;
        return Err(runner().args(args).exec().to_string());
    }
    if !args.is_empty() {
        return Err(format!("{command} does not take positional arguments"));
    }
    let virtualized = Command::new("/usr/sbin/sysctl")
        .args(["-n", "kern.hv_vmm_present"])
        .output()
        .map_err(|e| e.to_string())?;
    if !virtualized.status.success() || String::from_utf8_lossy(&virtualized.stdout).trim() != "1" {
        return Err("Run this check in a disposable macOS guest with a graphical login".into());
    }
    let dir = env::current_dir()
        .map_err(|e| e.to_string())?
        .join(".build/cli-lifecycle");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let windows = dir.join("windows");
    checked(
        Command::new("xcrun")
            .args(["swiftc", "-O", "scripts/cli-lifecycle/windows.swift", "-o"])
            .arg(&windows),
    )?;
    if command == "test-git-upgrade" {
        let bundle = env::var_os("AGENT_WATCH_TEST_BUNDLE")
            .ok_or("Set AGENT_WATCH_TEST_BUNDLE to the bundle being tested")?;
        let mut run = runner();
        run.args(["upgrade", "--bundle"])
            .arg(bundle)
            .arg("--windows")
            .arg(&windows);
        return checked(&mut run);
    }
    let binary = if let Some(bin) = env::var_os("AGENT_WATCH_TEST_GIT_BIN") {
        PathBuf::from(bin)
    } else {
        let target = env::var_os("CARGO_TARGET_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(".build/devtool"));
        checked(
            cargo()
                .args([
                    "build",
                    "--locked",
                    "--release",
                    "--manifest-path",
                    "native/git-protection/Cargo.toml",
                    "--target-dir",
                ])
                .arg(&target),
        )?;
        target.join("release/agent-watch-git")
    };
    for client in ["codex", "claude"] {
        checked(
            runner()
                .args(["close", client, "--binary"])
                .arg(&binary)
                .arg("--windows")
                .arg(&windows),
        )?;
    }
    Ok(())
}
