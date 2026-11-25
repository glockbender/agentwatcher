//! Prepare the reusable camera desktop. Only the explicitly requested VM commands use the account.
use super::*;
use serde_json::{Value, json};
use std::io::Write;

const ITEM: &str = "agent-watch-vm-claude-token";
const AUTH_DB: &str = "/Users/admin/Library/Application Support/com.apple.TCC/TCC.db";
const SHELL_ENV: &str = r#"path=(~/.local/bin /opt/homebrew/bin $path)
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s agent-watch-vm-claude-token -w 2>/dev/null) && export CLAUDE_CODE_OAUTH_TOKEN
"#;
const SHELL_RC: &str = r#"PROMPT='%~ %# '
[[ -n $AW_DEMO_SETTINGS ]] && claude() {
  local demo=(--setting-sources project,local --strict-mcp-config --settings "$AW_DEMO_SETTINGS" --permission-mode default)
  [[ -z $AW_SESSION_NAME ]] || demo+=(--name "$AW_SESSION_NAME")
  command claude "${demo[@]}" "$@"
}
"#;
fn input(vm: &str, path: &str, data: &[u8]) -> R {
    let mut child = io(command("tart", &["exec", "-i", vm, "tee", path])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn())?;
    io(child
        .stdin
        .take()
        .ok_or("Missing guest stdin")?
        .write_all(data))?;
    if io(child.wait())?.success() {
        Ok(())
    } else {
        Err(format!("Cannot write {path} in {vm}"))
    }
}
pub(super) fn token(vm: &str) -> R {
    // The two security tools communicate through pipes. No token in arguments, output or the shared folder.
    let mut source = io(command(
        "/usr/bin/security",
        &["find-generic-password", "-s", ITEM, "-w"],
    )
    .stdout(Stdio::piped())
    .spawn())?;
    let script = r#"IFS= read -r t && [[ -n $t && $t != *[^A-Za-z0-9_.~+/=-]* ]] && print -r -- "add-generic-password -U -a admin -s agent-watch-vm-claude-token -w $t" | /usr/bin/security -i >/dev/null 2>&1"#;
    let result = check(
        command("tart", &["exec", "-i", vm, "/bin/zsh", "-c", script])
            .stdin(source.stdout.take().ok_or("Missing pipe")?),
    );
    let read = io(source.wait())?;
    if !read.success() {
        return Err("Recording account is unavailable; see vm.md".into());
    }
    result?;
    if !silent(&mut guest(
        vm,
        &["security", "find-generic-password", "-s", ITEM],
    )) {
        return Err("Recording account was not installed in the guest".into());
    }
    Ok(())
}
fn edit_json(path: &std::path::Path, edit: impl FnOnce(&mut Value)) -> R {
    use std::os::unix::fs::OpenOptionsExt;
    let mut value = match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string())?,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => json!({}),
        Err(err) => return Err(err.to_string()),
    };
    edit(&mut value);
    let temp = path.with_extension(format!("new-{}", stamp()));
    let mut file = io(fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temp))?;
    serde_json::to_writer_pretty(&mut file, &value).map_err(|e| e.to_string())?;
    io(file.flush())?;
    io(fs::rename(temp, path))
}
fn configure(vm: &str, args: &[&str]) -> R {
    let mut cmd = vec!["vm", "configure-guest"];
    cmd.extend_from_slice(args);
    check(&mut media(vm, &cmd))
}
pub(super) fn configure_guest(args: &[&str]) -> R {
    if capture(&mut command("sysctl", &["-n", "kern.hv_vmm_present"]))?.as_str() != "1"
        || !PathBuf::from(SHARE).is_dir()
    {
        return Err("Configuration requires the mounted disposable recording guest".into());
    }
    let home = PathBuf::from(env::var_os("HOME").ok_or("Missing HOME")?);
    let profile = home.join(".claude.json");
    match args {
        ["setup", version] => {
            edit_json(&home.join(".claude/settings.json"), |v| {
                v["spinnerVerbs"] =
                    json!({"mode":"replace","verbs":["Working","Thinking","Reading"]});
                v["spinnerTipsEnabled"] = false.into();
                v["preferredNotifChannel"] = "notifications_disabled".into();
                // The default footer was “auto mode on” (measured on Claude Code 2.1.294).
                v["permissions"]["defaultMode"] = "default".into();
            })?;
            edit_json(&profile, |v| {
                v["hasCompletedOnboarding"] = true.into();
                v["lastOnboardingVersion"] = (*version).into();
                v["lastReleaseNotesSeen"] = (*version).into();
                v["theme"] = "dark".into();
                v["autoUpdates"] = false.into();
                v["numStartups"] = 10.into();
                for key in [
                    "hasTrustDialogAccepted",
                    "hasClaudeMdExternalIncludesApproved",
                    "hasClaudeMdExternalIncludesWarningShown",
                ] {
                    v["projects"][REPO][key] = true.into();
                }
            })
        }
        [action @ ("scrub" | "clear-starts")] => edit_json(&profile, |v| {
            let keys: &[&str] = if *action == "scrub" {
                &[
                    "oauthAccount",
                    "userID",
                    "anonymousId",
                    "claudeCodeFirstTokenDate",
                ]
            } else {
                // Leftover starts count as failed attempts to use the fullscreen renderer (measured on Claude Code 2.1.294).
                &["fullscreenBootStrikes", "fullscreenBootPending"]
            };
            if let Some(obj) = v.as_object_mut() {
                for &key in keys {
                    obj.remove(key);
                }
            }
        }),
        _ => Err("Invalid recording guest operation".into()),
    }
}
fn scrub(vm: &str) -> R {
    const ITEM_NOT_FOUND: i32 = (-25300_i32) & 255;
    for operation in ["delete-generic-password", "find-generic-password"] {
        let status = io(guest(vm, &["security", operation, "-s", ITEM])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status())?;
        if status.code() != Some(ITEM_NOT_FOUND)
            && (operation == "find-generic-password" || !status.success())
        {
            return Err(format!(
                "Cannot confirm the recording account was removed from {vm}: {operation} returned {status}"
            ));
        }
    }
    configure(vm, &["scrub"])
}
fn with_account(action: impl FnOnce() -> R) -> R {
    use signal_hook::{
        consts::{SIGHUP, SIGINT, SIGTERM},
        iterator::Signals,
    };
    let mut signals = Signals::new([SIGINT, SIGTERM, SIGHUP]).map_err(|e| e.to_string())?;
    let handle = signals.handle();
    let import = std::sync::Arc::new(std::sync::Mutex::new(()));
    let import_finished = import.clone();
    let importing = import.lock().map_err(|_| "Cannot start account transfer")?;
    let cleaner = thread::spawn(move || {
        if let Some(signal) = signals.forever().next() {
            // Do not remove the guest item until the import process has finished writing it.
            let _import = import_finished.lock();
            if let Err(error) = scrub(STAND) {
                eprintln!("Guest cleanup: {error}");
            }
            std::process::exit(128 + signal);
        }
    });
    let imported = token(STAND);
    drop(importing);
    let result = imported.and_then(|()| action());
    let cleanup = scrub(STAND);
    handle.close();
    cleaner.join().map_err(|_| "Guest cleanup thread stopped")?;
    cleanup.and(result)
}
pub(super) fn quit_ghostty(vm: &str) -> R {
    if let Ok(pids) = capture(&mut guest(vm, &["pgrep", "-x", "ghostty"])) {
        for pid in pids.lines() {
            check(&mut media(vm, &["aw", "quit", pid]))?
        }
        thread::sleep(Duration::from_secs(2));
    }
    Ok(())
}
fn copy_app(m: &Machine, name: &str) -> R {
    let bundle = format!("/Applications/{name}.app");
    let plist = format!("{bundle}/Contents/Info.plist");
    let query = ["defaults", "read", &plist, "CFBundleShortVersionString"];
    let version = capture(&mut command(query[0], &query[1..]))?;
    if capture(&mut guest(STAND, &query)).ok().as_ref() == Some(&version) {
        return Ok(());
    }
    let zip = format!("{name}-{}.zip", stamp());
    check(command("ditto", &["-c", "-k", "--keepParent", &bundle]).arg(m.share.join(&zip)))?;
    if silent(&mut guest(STAND, &["test", "-e", &bundle])) {
        check(&mut guest(STAND, &["sudo", "trash", &bundle]))?;
    }
    check(&mut guest(
        STAND,
        &[
            "sudo",
            "ditto",
            "-x",
            "-k",
            &format!("{SHARE}/{zip}"),
            "/Applications",
        ],
    ))?;
    if name == "Claude" {
        check(&mut guest(
            STAND,
            &[
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                "-f",
                &bundle,
            ],
        ))?;
    }
    super::super::discard(&m.share.join(zip), &m.home)
}
pub(super) fn prepare(m: &Machine) -> R {
    if !exists(STAND) {
        check(&mut command("tart", &["clone", "aw-golden", STAND]))?
    }
    if !running(STAND) {
        check(&mut command(
            "tart",
            &[
                "set",
                STAND,
                "--cpu",
                "8",
                "--memory",
                "16384",
                "--display",
                "1152x720pt",
            ],
        ))?
    }
    m.boot(STAND, false)?;
    m.checkout(STAND)?;
    m.screen(STAND)?;
    check(&mut media(
        STAND,
        &[
            "aw",
            "wallpaper",
            "/System/Library/Desktop Pictures/Solid Colors/Stone.png",
        ],
    ))?;
    check(&mut guest(
        STAND,
        &[
            "defaults",
            "write",
            "-g",
            "AppleInterfaceStyle",
            "-string",
            "Dark",
        ],
    ))?;
    check(&mut guest(
        STAND,
        &[
            "defaults",
            "write",
            "com.apple.dock",
            "autohide",
            "-bool",
            "true",
        ],
    ))?;
    check(&mut guest(STAND, &["killall", "Dock"]))?;
    if !silent(&mut guest(
        STAND,
        &["/opt/homebrew/bin/brew", "list", "ffmpeg"],
    )) {
        check(&mut guest(
            STAND,
            &[
                "env",
                "HOMEBREW_NO_AUTO_UPDATE=1",
                "HOMEBREW_NO_ANALYTICS=1",
                "/opt/homebrew/bin/brew",
                "install",
                "--quiet",
                "ffmpeg",
            ],
        ))?
    }
    copy_app(m, "Ghostty")?;
    copy_app(m, "Claude")?;
    let config = "Library/Application Support/com.mitchellh.ghostty";
    let mut bytes = io(fs::read(m.home.join(config).join("config")))?;
    bytes.extend_from_slice(b"\nauto-update = off\n");
    check(&mut guest(
        STAND,
        &["mkdir", "-p", &format!("/Users/admin/{config}")],
    ))?;
    input(STAND, &format!("/Users/admin/{config}/config"), &bytes)?;
    let cli = io(fs::canonicalize(m.home.join(".local/bin/claude")))?;
    let version = cli
        .file_name()
        .and_then(|x| x.to_str())
        .ok_or("Cannot identify Claude version")?
        .to_owned();
    let task = env::split_paths(&env::var_os("PATH").unwrap_or_default())
        .map(|p| p.join("task"))
        .find(|p| p.is_file())
        .ok_or("Cannot find task")?;
    for (source, name) in [(&cli, "claude"), (&task, "task")] {
        // Homebrew can install the source read-only. A second run replaces that copy.
        check(
            command("/bin/cp", &["-f"])
                .arg(source)
                .arg(m.share.join(name)),
        )?;
    }
    let versions = "/Users/admin/.local/share/claude/versions";
    let bin = "/Users/admin/.local/bin";
    check(&mut guest(
        STAND,
        &["mkdir", "-p", versions, bin, "/Users/admin/.claude"],
    ))?;
    check(&mut guest(
        STAND,
        &[
            "cp",
            "-f",
            &format!("{SHARE}/claude"),
            &format!("{versions}/{version}"),
        ],
    ))?;
    check(&mut guest(
        STAND,
        &[
            "ln",
            "-sf",
            &format!("{versions}/{version}"),
            &format!("{bin}/claude"),
        ],
    ))?;
    check(&mut guest(
        STAND,
        &["cp", "-f", &format!("{SHARE}/task"), &format!("{bin}/task")],
    ))?;
    input(STAND, "/Users/admin/.zshenv", SHELL_ENV.as_bytes())?;
    input(STAND, "/Users/admin/.zshrc", SHELL_RC.as_bytes())?;
    check(&mut guest(STAND, &["touch", "/Users/admin/.hushlogin"]))?;
    configure(STAND, &["setup", &version])?;
    with_account(|| {
        // Login shell supplies the recording account and runs the PTY driver in the filmed checkout.
        let suffix = if env::var("AW_APPROVE_MANAGED_SETTINGS").as_deref() == Ok("1") {
            " --approve-managed-settings"
        } else {
            ""
        };
        check(&mut guest(
            STAND,
            &[
                "zsh",
                "-lc",
                &format!("cd {REPO} && exec {TOOL} media first-start{suffix}"),
            ],
        ))
    })?;
    configure(STAND, &["clear-starts"])?;
    check(&mut guest(STAND, &["open", "-a", "Ghostty"]))?;
    thread::sleep(Duration::from_secs(6));
    quit_ghostty(STAND)?;
    check(&mut media(STAND, &["aw", "clear-notifications"]))?;
    check(&mut command("tart", &["stop", STAND]))
}
pub(super) fn grant(m: &Machine) -> R {
    m.boot(STAND, true)?;
    m.checkout(STAND)?;
    m.screen(STAND)?;
    m.app(STAND)?;
    with_account(|| {
        println!("Allow tart-guest-agent to control Ghostty in the VM");
        check(&mut guest(STAND, &["open", "-a", "Ghostty"]))?;
        thread::sleep(Duration::from_secs(3));
        wait(300, || {
            silent(&mut guest(
                STAND,
                &[
                    "osascript",
                    "-e",
                    "tell application \"Ghostty\" to count windows",
                ],
            ))
        })?;
        quit_ghostty(STAND)?;
        check(&mut media(STAND, &["stage", "up"]))?;
        println!("Allow Agent Watch to control Ghostty in the VM");
        let result=check(&mut media(STAND,&["focus-asking-row"])).and_then(|()|wait(300,||{
            capture(&mut guest(STAND,&["sqlite3",AUTH_DB,"select auth_value from access where client = 'com.glockbender.agentwatch' and indirect_object_identifier = 'com.mitchellh.ghostty'"])).as_deref()==Ok("2")
        }));
        check(&mut media(STAND, &["stage", "down"]))?;
        result
    })?;
    quit_ghostty(STAND)?;
    check(&mut command("tart", &["stop", STAND]))
}
