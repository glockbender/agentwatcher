use crate::{
    Client,
    clients::{Profiles, Rpc, foreground},
    execution::wait,
    fixture,
    guest::{ObservedCli, checked, in_guest, push_command, until},
    model::{Model, Plan},
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const CLIENTS: [Client; 2] = [Client::Claude, Client::Codex];
fn name(c: Client) -> &'static str {
    match c {
        Client::Claude => "claude",
        Client::Codex => "codex",
    }
}

fn trust(profiles: &Profiles, install: bool) -> Result<(String, String)> {
    let mut rpc = Rpc::start(profiles, true)?;
    let listing = rpc.call("hooks/list", json!({"cwds":[profiles.repo]}))?;
    let entries = listing["data"].as_array().context("Missing hook listing")?;
    ensure!(
        entries.len() == 1 && entries[0]["errors"] == json!([]),
        "Invalid hook listing: {listing}"
    );
    let matches = entries[0]["hooks"]
        .as_array()
        .context("Missing hooks")?
        .iter()
        .filter(|h| {
            h["command"]
                .as_str()
                .is_some_and(|s| s.contains("/GitProtection/hooks/git-guard.sh"))
        })
        .collect::<Vec<_>>();
    ensure!(
        matches.len() == 1,
        "Expected a single registered Agent Watch Git hook, found {}",
        matches.len()
    );
    let hook = matches[0];
    let key = hook["key"].as_str().context("Missing hook key")?.to_owned();
    let hash = hook["currentHash"]
        .as_str()
        .context("Missing hook hash")?
        .to_owned();
    if install {
        ensure!(
            hook["trustStatus"] == "untrusted",
            "Unexpected initial trust: {}",
            hook["trustStatus"]
        );
        rpc.call("config/value/write",json!({"keyPath":"hooks.state","value":{&key:{"trusted_hash":hash}},"mergeStrategy":"upsert"}))?;
    } else {
        ensure!(
            hook["trustStatus"] == "trusted" && hook["enabled"] == true,
            "Registered hook not active: {hook}"
        );
    }
    rpc.shutdown()?;
    Ok((key, hash))
}

fn exercise(p: &Profiles, c: Client, cli: &ObservedCli, branch: &str, probe: &Path) -> Result<()> {
    let prompt = "Run the Agent Watch fixture operation.";
    let exe = cli.path.to_str().context("Expected UTF-8 bundle path")?;
    let model = Model::start(
        c,
        Plan {
            prompt: prompt.into(),
            command: format!("git push origin --delete {branch}"),
            follow: Some((exe.into(), push_command(&cli.path, &p.repo, branch)?)),
        },
    )?;
    let log = p
        .home
        .join(format!("{}-{}.log", name(c), branch.replace('/', "-")));
    let mut child = foreground(p, c, &model, prompt, &log)?;
    let result = until(120, "the expected Git confirmation", || {
        model.check()?;
        ensure!(
            child.try_wait()?.is_none(),
            "{} exited, see {}",
            name(c),
            log.display()
        );
        if let Some(denial) = model.denial() {
            ensure!(
                denial.contains(exe),
                "Hook did not direct {} to the CLI: {denial}",
                name(c)
            );
        }
        let Some(alert) = cli.alert(probe)? else {
            return Ok(None);
        };
        ensure!(
            model.denial().is_some(),
            "Confirmation appeared before the hook response"
        );
        // The C locale escapes non-ASCII process arguments for display.
        let raw = checked(Command::new("/bin/ps").env("LC_ALL", "en_US.UTF-8").args([
            "-ww",
            "-p",
            &alert.helper.to_string(),
            "-o",
            "command=",
        ]))?;
        let (_, payload) = raw
            .split_once(" --confirmation-window ")
            .context("Missing confirmation payload")?;
        let data: Value = serde_json::from_str(payload).with_context(|| {
            format!(
                "Invalid confirmation payload from test helper {}: {payload:.400}",
                alert.helper
            )
        })?;
        let text = data["message"].as_str().context("Missing window message")?;
        let expected = if branch == "release" {
            "Шаг 1 из 2: Удаление защищённой ветки"
        } else {
            "Шаг 1 из 1: Удаление обычной ветки"
        };
        ensure!(
            text.starts_with(expected) && text.contains(branch),
            "Wrong confirmation for {branch}: {text}"
        );
        println!("{} {branch}: {expected}", name(c));
        Ok(Some(()))
    });
    let cleanup = cli.terminate();
    let _ = child.kill();
    let _ = wait(&mut child, Duration::from_secs(8))?;
    result?;
    cleanup?;
    until(8, "the previous confirmation processes to exit", || {
        Ok(cli.pids()?.is_empty().then_some(()))
    })
}

/// The registered command outlives a moved or half-replaced bundle, so it must answer with a
/// denial of its own instead of letting the client run the command unchecked. `moved` is the
/// executable at the bundle's temporary location, which nothing may start.
fn exercise_unavailable(
    p: &Profiles,
    c: Client,
    cli: &ObservedCli,
    moved: &ObservedCli,
    branch: &str,
) -> Result<()> {
    let prompt = "Run the Agent Watch fixture operation.";
    let exe = cli.path.to_str().context("Expected UTF-8 bundle path")?;
    let model = Model::start(
        c,
        Plan {
            prompt: prompt.into(),
            command: format!("git push origin --delete {branch}"),
            follow: Some((exe.into(), push_command(&cli.path, &p.repo, branch)?)),
        },
    )?;
    let log = p.home.join(format!(
        "{}-unavailable-{}.log",
        name(c),
        branch.replace('/', "-")
    ));
    let mut child = foreground(p, c, &model, prompt, &log)?;
    let result = until(120, "the denial from the unavailable hook", || {
        model.check()?;
        if let Some(denial) = model.denial() {
            // The registered command embeds the same sentence, so a client error that quotes the
            // command would match too; only the fallback's own output lacks the script path.
            ensure!(
                denial.contains("the installed hook could not run")
                    && !denial.contains("git-guard.sh"),
                "{} got an unexpected hook response while the bundle was unavailable: {denial}",
                name(c)
            );
            return Ok(Some(()));
        }
        ensure!(
            child.try_wait()?.is_none(),
            "{} exited without a hook response, see {}",
            name(c),
            log.display()
        );
        Ok(None)
    });
    let _ = child.kill();
    let stopped = wait(&mut child, Duration::from_secs(8));
    result?;
    stopped?;
    ensure!(
        cli.pids()?.is_empty() && moved.pids()?.is_empty(),
        "A confirmation process started while the bundle was unavailable"
    );
    println!(
        "{} {branch}: denied while the bundle was unavailable",
        name(c)
    );
    Ok(())
}

fn files(p: &Profiles) -> Vec<PathBuf> {
    vec![
        p.repo.join(".git/config"),
        p.home.join(".codex/config.toml"),
        p.home.join(".claude/settings.json"),
        p.home.join(".codex/hooks.json"),
    ]
}
fn contents(paths: &[PathBuf], semantic: bool) -> Result<Vec<Vec<u8>>> {
    paths
        .iter()
        .map(|path| {
            let raw = fs::read(path)?;
            if semantic && path.extension().is_some_and(|x| x == "json") {
                let data: Value = serde_json::from_slice(&raw)?;
                return Ok(serde_json::to_vec(&data)?);
            }
            Ok(raw)
        })
        .collect()
}

pub(crate) fn run(source: &Path, previous: Option<&Path>, probe: &Path) -> Result<()> {
    in_guest("aw-upgrade-", |root| {
        let fixture = fixture::prepare(&root.join("git"))?;
        let refs = fixture.snapshot()?;
        let marker = root.join("push-attempted");
        let hook = fixture.remote.join("hooks/pre-receive");
        fs::create_dir_all(hook.parent().unwrap())?;
        fs::write(
            &hook,
            format!(
                "#!/bin/sh\ntouch {}\nexit 1\n",
                shlex::try_quote(marker.to_str().context("Expected UTF-8 path")?)?
            ),
        )?;
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o700))?;
        let profiles = Profiles::new(&fixture, &CLIENTS)?;
        let config = profiles.home.join(".codex/config.toml");
        fs::write(config, "[analytics]\nenabled = false\n")?;
        let install = root.join("Test Applications");
        fs::create_dir(&install)?;
        let bundle = install.join("AgentWatch.app");
        checked(
            Command::new("/usr/bin/ditto")
                .arg(previous.unwrap_or(source))
                .arg(&bundle),
        )?;
        if previous.is_none() {
            checked(
                Command::new("/usr/libexec/PlistBuddy")
                    .args(["-c", "Set :CFBundleVersion 1"])
                    .arg(bundle.join("Contents/Info.plist")),
            )?;
            writeln!(
                OpenOptions::new()
                    .append(true)
                    .open(bundle.join("Contents/Resources/GitProtection/hooks/git-guard.sh"))?,
                "\n# Previous release fixture"
            )?;
            checked(
                Command::new("/usr/bin/codesign")
                    .args(["-f", "-s", "-"])
                    .arg(&bundle),
            )?;
        }
        let verify = || {
            checked(
                Command::new("/usr/bin/codesign")
                    .args(["--verify", "--deep", "--strict"])
                    .arg(&bundle),
            )
        };
        verify()?;
        let installer = bundle.join("Contents/MacOS/AgentWatch");
        let cli = ObservedCli {
            path: bundle.join("Contents/MacOS/AgentWatchGit"),
        };
        let registration = |action: &str, c: Client| -> Result<()> {
            let result = checked(
                profiles
                    .cmd(&installer)
                    .args(["--git-hooks", action, name(c)])
                    .arg(profiles.profile(c)),
            )?;
            ensure!(
                result == "registered",
                "{} {action} returned {result}",
                name(c)
            );
            Ok(())
        };
        for c in CLIENTS {
            let (file, seed) = match c {
                Client::Claude => (
                    "settings.json",
                    json!({"hooks":{"SessionStart":[]},"env":{"DISABLE_AUTOUPDATER":"1"}}),
                ),
                Client::Codex => ("hooks.json", json!({"hooks":{"SessionStart":[]}})),
            };
            fs::write(profiles.profile(c).join(file), serde_json::to_vec(&seed)?)?;
            registration("install", c)?;
        }
        let identity = trust(&profiles, true)?;
        let paths = files(&profiles);
        let state = contents(&paths, true)?;
        let check = |branches: &[&str]| -> Result<()> {
            ensure!(
                trust(&profiles, false)? == identity,
                "Codex hook identity changed"
            );
            for c in CLIENTS {
                for branch in branches {
                    exercise(&profiles, c, &cli, branch, probe)?;
                    ensure!(
                        fixture.snapshot()? == refs && !marker.exists(),
                        "Deletion reached the local receiver"
                    );
                }
            }
            ensure!(
                contents(&paths, true)? == state,
                "The settings or repository rule changed"
            );
            Ok(())
        };
        println!("Before bundle replacement");
        check(&["release"])?;
        let bytes = contents(&paths, false)?;
        let old = root.join("previous.app");
        fs::rename(&bundle, &old)?;
        checked(Command::new("/usr/bin/ditto").arg(source).arg(&bundle))?;
        verify()?;
        let seal = "Contents/_CodeSignature/CodeResources";
        ensure!(
            fs::read(bundle.join(seal))? != fs::read(old.join(seal))?,
            "The fixture requires two different signed bundles"
        );
        for c in CLIENTS {
            registration("status", c)?;
        }
        println!("After bundle replacement");
        check(&["release", "feature/example"])?;
        ensure!(
            contents(&paths, false)? == bytes,
            "Updating or starting the next chat changed the profile bytes"
        );
        println!("While the bundle is temporarily unavailable");
        let unavailable = root.join("temporarily unavailable.app");
        fs::rename(&bundle, &unavailable)?;
        let moved = ObservedCli {
            path: unavailable.join("Contents/MacOS/AgentWatchGit"),
        };
        let denied = CLIENTS.iter().try_for_each(|&c| -> Result<()> {
            exercise_unavailable(&profiles, c, &cli, &moved, "feature/example")?;
            ensure!(
                fixture.snapshot()? == refs && !marker.exists(),
                "An unavailable bundle let the deletion reach the local receiver"
            );
            Ok(())
        });
        // Restore before reporting, so a failure leaves the retained files in a usable state.
        let restored = fs::rename(&unavailable, &bundle).context("Could not restore the bundle");
        denied?;
        restored?;
        println!("After the bundle returns");
        check(&["feature/example"])?;
        ensure!(
            contents(&paths, false)? == bytes,
            "The unavailable bundle or the chats around it changed the profile bytes"
        );
        println!(
            "PASS: both clients kept their hooks and rule across replacement, denied while the bundle was missing and confirmed again after it returned; all refs unchanged."
        );
        Ok(())
    })
}
