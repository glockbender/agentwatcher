//! Run the Sparkle acceptance suite in a disposable macOS guest.
mod guest;
mod server;
use std::{
    env,
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type R<T = ()> = Result<T, String>;

fn checked(command: &mut Command) -> R {
    let name = command.get_program().to_string_lossy().into_owned();
    let status = command.status().map_err(|e| format!("{name}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{name} exited with {status}"))
    }
}
fn output(command: &mut Command) -> R<String> {
    let name = command.get_program().to_string_lossy().into_owned();
    let o = command.output().map_err(|e| format!("{name}: {e}"))?;
    if !o.status.success() {
        return Err(format!(
            "{name}: {}",
            String::from_utf8_lossy(&o.stderr).trim()
        ));
    }
    String::from_utf8(o.stdout)
        .map(|s| s.trim_end().to_owned())
        .map_err(|e| e.to_string())
}
fn cmd(program: impl AsRef<OsStr>, args: &[&str]) -> Command {
    let mut c = Command::new(program);
    c.args(args);
    c
}
fn io<T>(result: std::io::Result<T>) -> R<T> {
    result.map_err(|e| e.to_string())
}
fn at(path: &Path) -> R<&str> {
    path.to_str()
        .ok_or_else(|| format!("Unsupported path encoding: {}", path.display()))
}
fn mkdir(path: &Path) -> R {
    io(fs::create_dir_all(path))
}
fn replace_plist(plist: &Path, key: &str, value: &str) -> R {
    checked(cmd("plutil", &["-replace", key, "-string", value]).arg(plist))
}
fn sign(app: &Path) -> R {
    checked(cmd("codesign", &["--force", "--sign", "-"]).arg(app))?;
    checked(cmd("codesign", &["--verify", "--strict"]).arg(app))
}
fn bounded(
    command: &mut Command,
    duration: Duration,
    interrupted: &std::sync::atomic::AtomicBool,
) -> R {
    use std::sync::atomic::Ordering;
    let name = command.get_program().to_string_lossy().into_owned();
    let mut child = io(command.spawn())?;
    let deadline = Instant::now() + duration;
    loop {
        if let Some(status) = io(child.try_wait())? {
            return if status.success() {
                Ok(())
            } else {
                Err(format!("{name}: {status}"))
            };
        }
        if Instant::now() >= deadline || interrupted.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{name} interrupted or timed out"));
        }
        thread::sleep(Duration::from_millis(150));
    }
}
struct Machine {
    name: String,
    runner: Option<Child>,
}
impl Drop for Machine {
    fn drop(&mut self) {
        let cleanup = std::sync::atomic::AtomicBool::new(false);
        let _ = bounded(
            &mut cmd("tart", &["stop", &self.name]),
            Duration::from_secs(45),
            &cleanup,
        );
        if let Some(r) = &mut self.runner {
            let _ = r.kill();
            let _ = r.wait();
        }
        if let Err(error) = bounded(
            &mut cmd("tart", &["delete", &self.name]),
            Duration::from_secs(60),
            &cleanup,
        ) {
            eprintln!("Could not remove disposable VM {}: {error}", self.name);
        }
    }
}

fn feed(name: &str, mode: &str, signature: &str, share: &Path, changelog: &Path) -> R {
    let url = format!("http://127.0.0.1:8123/zip/{mode}/AgentWatch-0.9.2.zip");
    let out = io(fs::File::create(
        share.join(format!("serve/feeds/{name}.xml")),
    ))?;
    checked(
        cmd(
            env::current_exe().map_err(|e| e.to_string())?,
            &["appcast", "0.9.2", &url, signature, at(changelog)?],
        )
        .stdout(out),
    )
}

fn local_build(work: &Path, share: &Path) -> R {
    let exe = io(env::current_exe())?;
    let build = if let Some(existing) = env::var_os("AGENT_WATCH_TEST_UPDATE_BUNDLE") {
        let app = PathBuf::from(existing);
        checked(cmd("codesign", &["--verify", "--deep", "--strict"]).arg(&app))?;
        app
    } else {
        let app = work.join("build/AgentWatch.app");
        let log = io(fs::File::create(work.join("build.log")))?;
        checked(
            cmd(&exe, &["build-app", "debug", at(&app)?])
                .env("AGENT_WATCH_SIGNING_IDENTITY", "-")
                .stdout(io(log.try_clone())?)
                .stderr(log),
        )?;
        app
    };
    let public = output(
        Command::new("swift")
            .arg("scripts/update-test/testkey.swift")
            .arg(work),
    )?;
    for (kind, version) in [("old", "0.9.0"), ("new", "0.9.2")] {
        let app = share.join(kind).join("AgentWatch.app");
        checked(Command::new("ditto").arg(&build).arg(&app))?;
        let plist = app.join("Contents/Info.plist");
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            replace_plist(&plist, key, version)?;
        }
        replace_plist(&plist, "SUPublicEDKey", &public)?;
        sign(&app)?;
    }
    let zip = share.join("serve/AgentWatch-0.9.2.zip");
    checked(
        cmd("ditto", &["-c", "-k", "--keepParent"])
            .arg(share.join("new/AgentWatch.app"))
            .arg(&zip),
    )?;
    let signer = PathBuf::from(output(&mut cmd(&exe, &["sparkle-tools"]))?).join("sign_update");
    let key = work.join("private.key");
    let signature = output(
        Command::new(&signer)
            .arg("--ed-key-file")
            .arg(&key)
            .arg(&zip),
    )?;
    let other = work.join("other");
    io(fs::write(&other, b"not the archive"))?;
    let wrong = output(
        Command::new(signer)
            .arg("--ed-key-file")
            .arg(key)
            .arg("-p")
            .arg(other),
    )?;
    let length = io(fs::metadata(&zip))?.len();
    let wrong = format!("sparkle:edSignature=\"{wrong}\" length=\"{length}\"");
    let changelog = work.join("CHANGELOG.md");
    io(fs::write(&changelog, include_str!("changes.md.in")))?;
    for (name, mode, sig) in [
        ("good", "ok", &signature),
        ("drop", "drop", &signature),
        ("stall", "stall", &signature),
        ("error", "error", &signature),
        ("badsig", "ok", &wrong),
    ] {
        feed(name, mode, sig, share, &changelog)?;
    }
    Ok(())
}

pub(super) fn host(args: &[String]) -> R {
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    let (from, masquerade) = match args.as_slice() {
        [] => (None, None),
        ["--from", v] => (Some(*v), None),
        ["--from", v, "--as", old] => (Some(*v), Some(*old)),
        _ => return Err("Usage: e2e-update [--from TAG [--as OLDER_VERSION]]".into()),
    };
    let golden = env::var("AGENT_WATCH_TEST_VM_BASE").unwrap_or_else(|_| "aw-golden".into());
    checked(cmd("tart", &["get", &golden]).stdout(Stdio::null()))?;
    let name = format!("aw-update-{}", std::process::id());
    let unique = format!(
        "{}-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs(),
        std::process::id()
    );
    let work = PathBuf::from(env::var_os("HOME").ok_or("HOME is missing")?)
        .join("Library/Caches/agent-watch-update-test")
        .join(unique);
    let share = work.join("share");
    for dir in ["serve/feeds", "old", "new", "out"] {
        mkdir(&share.join(dir))?;
    }
    eprintln!("Update test artifacts: {}", work.display());
    let mut published = None;
    if let Some(tag) = from {
        let release = output(&mut cmd(
            "gh",
            &[
                "release",
                "view",
                "--repo",
                "glockbender/agentwatcher",
                "--json",
                "tagName",
                "--jq",
                ".tagName",
            ],
        ))?;
        if release == tag && masquerade.is_none() {
            return Err(format!(
                "{tag} is already the latest release; supply --as to test an update"
            ));
        }
        let archive = format!("AgentWatch-{}.zip", tag.trim_start_matches('v'));
        checked(
            cmd(
                "gh",
                &[
                    "release",
                    "download",
                    tag,
                    "--repo",
                    "glockbender/agentwatcher",
                    "--pattern",
                    &archive,
                    "--dir",
                ],
            )
            .arg(&work),
        )?;
        checked(
            cmd("ditto", &["-x", "-k"])
                .arg(work.join(&archive))
                .arg(share.join("old")),
        )?;
        if let Some(version) = masquerade {
            let app = share.join("old/AgentWatch.app");
            for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
                replace_plist(&app.join("Contents/Info.plist"), key, version)?;
            }
            sign(&app)?;
        }
        published = Some(release.trim_start_matches('v').to_owned());
    } else {
        local_build(&work, &share)?;
    }
    checked(
        cmd("ditto", &["-c", "-k", "--keepParent"])
            .arg(share.join("old/AgentWatch.app"))
            .arg(share.join("old.zip")),
    )?;
    checked(
        cmd("swiftc", &["-O", "-target", "arm64-apple-macos14", "-o"])
            .arg(share.join("ax"))
            .arg("scripts/update-test/ax.swift"),
    )?;
    io(fs::copy(io(env::current_exe())?, share.join("devtool")))?;
    let interrupted = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for signal in [
        signal_hook::consts::SIGINT,
        signal_hook::consts::SIGTERM,
        signal_hook::consts::SIGHUP,
    ] {
        signal_hook::flag::register(signal, interrupted.clone()).map_err(|e| e.to_string())?;
    }
    checked(&mut cmd("tart", &["clone", &golden, &name]))?;
    let mut vm = Machine {
        name: name.clone(),
        runner: None,
    };
    let log = io(fs::File::create(work.join("tart.log")))?;
    vm.runner = Some(io(Command::new("tart")
        .args(["run", "--no-graphics"])
        .arg(format!("--dir=aw:{}", share.display()))
        .arg(&name)
        .stdout(io(log.try_clone())?)
        .stderr(log)
        .spawn())?);
    let deadline = Instant::now() + Duration::from_secs(180);
    loop {
        if interrupted.load(std::sync::atomic::Ordering::Relaxed) {
            return Err("Interrupted".into());
        }
        if let Some(runner) = vm.runner.as_mut()
            && let Some(status) = io(runner.try_wait())?
        {
            return Err(format!(
                "Tart stopped before graphical login ({status}). See {}/tart.log",
                work.display()
            ));
        }
        if bounded(
            cmd("tart", &["exec", &name, "pgrep", "-x", "Dock"])
                .stdout(Stdio::null())
                .stderr(io(fs::File::create(work.join("guest-login.log")))?),
            Duration::from_secs(12),
            &interrupted,
        )
        .is_ok()
        {
            break;
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "The guest did not report a running Dock within 180 seconds. See {}/guest-login.log",
                work.display()
            ));
        }
        thread::sleep(Duration::from_secs(2));
    }
    thread::sleep(Duration::from_secs(5));
    let mut c = cmd(
        "tart",
        &[
            "exec",
            &name,
            "/Volumes/My Shared Files/aw/devtool",
            "update-guest",
        ],
    );
    if let Some(v) = published {
        c.arg("published").arg(v);
    }
    let result = bounded(&mut c, Duration::from_secs(900), &interrupted);
    let report = fs::read_to_string(share.join("out/result.txt")).map_err(|err| {
        format!(
            "Guest produced no report ({err}). {}. See {}",
            result
                .as_ref()
                .err()
                .map(String::as_str)
                .unwrap_or("Guest exited"),
            work.display()
        )
    })?;
    print!("{report}");
    result?;
    if report.is_empty() || report.lines().any(|l| l.contains(" FAILED")) {
        return Err(format!("Update test failed; see {}", work.display()));
    }
    drop(vm);
    checked(Command::new("/usr/bin/trash").arg(work))
}

pub(super) fn run_guest(args: &[String]) -> R {
    guest::run(args)
}
