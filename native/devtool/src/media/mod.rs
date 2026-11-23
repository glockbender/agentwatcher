//! README recordings share a Swift screen driver and a disposable demo stage.
mod cut;
mod first_start;
mod frames;
mod recording;
mod scene;
mod stage;
mod takes;
mod vm;

use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

type Result<T = ()> = std::result::Result<T, String>;
const NAMES: [&str; 7] = [
    "Check the task list",
    "List the targets",
    "Explain the architecture",
    "Review the README",
    "Find the TODOs",
    "Count the tests",
    "Sum up the plan",
];
const USAGE: &str = "media aw <driver arguments> | stage up|down|reset-settings|status | take setup|start|menu|order|rows|look|folders|fullscreen|icon [counts] | cut [--sheet] [--publish] [clip ...] | activity <take> [from] [to] | first-start [--approve-managed-settings] | vm <command>";

macro_rules! args { ($($value:expr),* $(,)?) => { &[$($value.to_string()),*] }; }
use args;

fn sleep(seconds: f64) {
    std::thread::sleep(Duration::from_secs_f64(seconds));
}

fn output(program: impl AsRef<OsStr>, args: &[impl AsRef<OsStr>]) -> Result<String> {
    let program = program.as_ref();
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("{}: {e}", program.to_string_lossy()))?;
    if !output.status.success() {
        return Err(format!(
            "{} {}: {}",
            program.to_string_lossy(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end_matches(['\r', '\n'])
        .to_owned())
}

fn read(path: &Path) -> Result<String> {
    fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn discard(path: &Path, home: &Path) -> Result {
    if path == home
        || !path.starts_with(home)
        || path
            .components()
            .any(|c| c == std::path::Component::ParentDir)
    {
        return Err(format!("Refusing to discard {}", path.display()));
    }
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    if std::env::var("AW_DISCARD").as_deref() == Ok("delete") {
        let result = if meta.is_dir() {
            fs::remove_dir_all(path)
        } else {
            fs::remove_file(path)
        };
        result.map_err(|e| format!("{}: {e}", path.display()))
    } else {
        output("/usr/bin/trash", &[path]).map(|_| ())
    }
}

fn driver(root: &Path, work: &Path) -> Result<PathBuf> {
    let src = root.join(".claude/skills/readme-media/scripts/aw-media.swift");
    let dest = work.join("aw-media");
    let modified = |p: &Path| {
        fs::metadata(p)
            .and_then(|m| m.modified())
            .map_err(|e| format!("{}: {e}", p.display()))
    };
    if !fs::metadata(&dest).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        || modified(&src)? > modified(&dest)?
    {
        fs::create_dir_all(work).map_err(|e| e.to_string())?;
        let tmp = work.join(format!("aw-media.{}.tmp", std::process::id()));
        output("swiftc", &[Path::new("-O"), &src, Path::new("-o"), &tmp])?;
        fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    }
    Ok(dest)
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn wait(mut check: impl FnMut() -> bool, count: usize, interval: f64) -> bool {
    for _ in 0..count {
        if check() {
            return true;
        }
        sleep(interval);
    }
    check()
}

pub(super) fn run(args: &[String]) -> Result {
    let Some((command, rest)) = args.split_first() else {
        return Err(USAGE.into());
    };
    if matches!(command.as_str(), "--help" | "-h") {
        println!("{USAGE}");
        return Ok(());
    }
    if command == "vm" {
        return vm::run(rest);
    }
    let root = std::env::current_dir().map_err(|e| e.to_string())?;
    let home = PathBuf::from(std::env::var_os("HOME").ok_or("HOME is not set")?);
    let work = home.join("Library/Caches/agent-watch-media");
    match command.as_str() {
        "cut" => cut::run(&root, &work, rest),
        "activity" => frames::activity(&work, rest),
        "first-start" => first_start::run(rest),
        "first-start-child" if rest.is_empty() => first_start::child(),
        "aw" => {
            use std::os::unix::process::CommandExt;
            let error = Command::new(driver(&root, &work)?).args(rest).exec();
            Err(error.to_string())
        }
        "stage" if matches!(rest,[cmd] if matches!(cmd.as_str(),"up"|"down"|"status"|"reset-settings")) => {
            stage::run(&mut scene::Scene::load(root, home)?, &rest[0])
        }
        "take"
            if matches!(rest, [name] if takes::NAMES.contains(&name.as_str()))
                || matches!(rest,[name, style] if name=="icon" && matches!(style.as_str(),"counts"|"sphere")) =>
        {
            let mut scene = scene::Scene::load(root, home)?;
            takes::run(
                &mut scene,
                &rest[0],
                rest.get(1).is_some_and(|v| v == "counts"),
            )
        }
        "focus-asking-row" if rest.is_empty() => {
            let scene = scene::Scene::load(root, home)?;
            scene.show_widget(true)?;
            let row = scene.find("find", NAMES[0])?;
            scene
                .driver(args!["glide", row[0], row[1], "click"])
                .map(|_| ())
        }
        _ => Err(USAGE.into()),
    }
}
