use crate::{
    Client,
    clients::{Chat, Profiles},
    execution::output,
    fixture,
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::json;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

pub(crate) fn checked(cmd: &mut Command) -> Result<String> {
    output(cmd, Duration::from_secs(90))
}

pub(crate) fn in_guest(prefix: &str, run: impl FnOnce(&Path) -> Result<()>) -> Result<()> {
    ensure!(
        checked(Command::new("/usr/sbin/sysctl").args(["-n", "kern.hv_vmm_present"]))? == "1",
        "Run this check inside a disposable macOS guest with a graphical login."
    );
    let root = tempfile::Builder::new()
        .prefix(prefix)
        .tempdir_in("/private/tmp")?;
    if let Err(err) = run(root.path()) {
        let retained = root.keep();
        return Err(err.context(format!("Test files retained at {}", retained.display())));
    }
    Ok(())
}

pub(crate) fn push_command(binary: &Path, repo: &Path, branch: &str) -> Result<String> {
    let data =
        json!({"repository":repo,"remote":"origin","destination":format!("refs/heads/{branch}"),
        "delete":true,"reason":"Test Git protection on a disposable project."})
        .to_string();
    Ok(shlex::try_join([
        binary.to_str().context("Expected UTF-8 binary path")?,
        "push",
        &data,
    ])?)
}

fn process_table() -> Result<BTreeMap<u32, (u32, PathBuf)>> {
    let raw = output(
        Command::new("/bin/ps").args(["-axo", "pid=,ppid=,comm="]),
        Duration::from_secs(20),
    )?;
    let mut rows = BTreeMap::new();
    for row in raw.lines() {
        let (pid, rest) = row
            .trim_start()
            .split_once(char::is_whitespace)
            .context("Missing ps PID")?;
        let (parent, exe) = rest
            .trim_start()
            .split_once(char::is_whitespace)
            .context("Missing ps process")?;
        rows.insert(
            pid.parse()?,
            (parent.parse()?, PathBuf::from(exe.trim_start())),
        );
    }
    Ok(rows)
}

pub(crate) fn windows(probe: &Path, pid: u32) -> Result<Vec<u32>> {
    let output = output(
        Command::new(probe).arg(pid.to_string()),
        Duration::from_secs(15),
    )?;
    output
        .lines()
        .map(|line| line.parse().context("Invalid window ID"))
        .collect()
}

#[derive(PartialEq, Eq, Debug)]
pub(crate) struct Alert {
    pub parent: u32,
    pub helper: u32,
    pub ids: Vec<u32>,
}

pub(crate) struct ObservedCli {
    pub path: PathBuf,
}
impl ObservedCli {
    pub fn pids(&self) -> Result<Vec<u32>> {
        Ok(process_table()?
            .into_iter()
            .filter_map(|(pid, (_, p))| (p == self.path).then_some(pid))
            .collect())
    }
    pub fn alert(&self, probe: &Path) -> Result<Option<Alert>> {
        let rows = process_table()?;
        for (pid, (parent, path)) in &rows {
            if *path == self.path && rows.get(parent).is_some_and(|(_, p)| p == path) {
                let ids = windows(probe, *pid)?;
                if !ids.is_empty() {
                    return Ok(Some(Alert {
                        parent: *parent,
                        helper: *pid,
                        ids,
                    }));
                }
            }
        }
        Ok(None)
    }
    pub fn terminate(&self) -> Result<()> {
        for pid in self.pids()? {
            // Scope cleanup to the private binary copied for this test.
            let _ = Command::new("/bin/kill")
                .args(["-TERM", &pid.to_string()])
                .status();
        }
        Ok(())
    }
}

struct Cleanup<'a>(&'a ObservedCli);
impl Drop for Cleanup<'_> {
    fn drop(&mut self) {
        if let Err(e) = self.0.terminate() {
            eprintln!("Test cleanup: {e:#}");
        }
    }
}

pub(crate) fn until<T>(
    seconds: u64,
    expectation: &str,
    mut read: impl FnMut() -> Result<Option<T>>,
) -> Result<T> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(value) = read()? {
            return Ok(value);
        }
        if Instant::now() >= deadline {
            bail!("Timed out waiting for {expectation}");
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

pub(crate) fn close(client: Client, source: &Path, probe: &Path) -> Result<()> {
    in_guest("aw-close-", |root| {
        let fixture = fixture::prepare(&root.join("git"))?;
        let before = fixture.snapshot()?;
        let cli = ObservedCli {
            path: root.join("agent-watch-git"),
        };
        fs::copy(source, &cli.path)?;
        let _cleanup = Cleanup(&cli);
        let profiles = Profiles::new(&fixture, &[client])?;
        let mut chat = Chat::start(
            &profiles,
            client,
            push_command(&cli.path, &fixture.repo, "feature/example")?,
        )?;
        let alert = until(120, "a visible confirmation owned by the CLI", || {
            chat.alive()?;
            cli.alert(probe)
        })?;
        println!("Before closing: {alert:?}");
        std::thread::sleep(Duration::from_millis(400));
        ensure!(
            cli.alert(probe)?.as_ref() == Some(&alert),
            "The confirmation disappeared or changed before chat closure"
        );
        chat.close()?;
        until(10, "the window to close and both processes to exit", || {
            chat.alive()?;
            Ok((cli.pids()?.is_empty() && windows(probe, alert.helper)?.is_empty()).then_some(()))
        })?;
        ensure!(
            fixture.snapshot()? == before,
            "The remote references changed"
        );
        chat.finish()?;
        println!(
            "PASS {client:?}: all remote refs unchanged, the window closed, CLI and helper exited."
        );
        Ok(())
    })
}
