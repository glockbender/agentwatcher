mod bundle;
mod distribution;

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

type Result<T = ()> = std::result::Result<T, String>;

fn cmd(program: impl AsRef<OsStr>) -> Command {
    let mut command = Command::new(program);
    command.env_remove("SPARKLE_PRIVATE_KEY");
    command
}

fn run_cmd(command: &mut Command) -> Result {
    let status = command.status().map_err(|e| format!("{command:?}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{command:?}: {status}"))
    }
}

fn output(command: &mut Command) -> Result<String> {
    let result = command.output().map_err(|e| format!("{command:?}: {e}"))?;
    if !result.status.success() {
        return Err(format!(
            "{command:?}: {}\n{}",
            result.status,
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    String::from_utf8(result.stdout)
        .map(|s| s.trim_end().to_owned())
        .map_err(|e| e.to_string())
}

fn io<T>(operation: std::io::Result<T>, path: &Path) -> Result<T> {
    operation.map_err(|e| format!("{}: {e}", path.display()))
}

fn dirs(path: &Path) -> Result {
    io(fs::create_dir_all(path), path)
}

fn copy(from: &Path, to: &Path) -> Result {
    fs::copy(from, to).map_err(|e| format!("copy {} to {}: {e}", from.display(), to.display()))?;
    Ok(())
}

fn plist(path: &Path, key: &str) -> Result<String> {
    output(
        cmd("plutil")
            .args(["-extract", key, "raw", "-o", "-"])
            .arg(path),
    )
}

fn scratch(parent: &Path) -> Result<PathBuf> {
    dirs(parent)?;
    output(
        cmd("mktemp")
            .arg("-d")
            .arg(parent.join("agent-watch.XXXXXXXX")),
    )
    .map(PathBuf::from)
}

fn trash(path: &Path) -> Result {
    match fs::symlink_metadata(path) {
        Ok(_) => run_cmd(cmd("/usr/bin/trash").arg(path)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

pub fn run(command: &str, args: &[String]) -> Result {
    let root = std::env::current_dir().map_err(|e| e.to_string())?;
    match command {
        "build-app" if args.len() <= 2 => {
            let settings = bundle::Settings::from_env()?;
            let configuration = args.first().map_or("debug", String::as_str);
            let app = settings.build(&root, configuration, args.get(1).map(Path::new))?;
            println!("{}", app.display());
        }
        "dev" if args.is_empty() || args == ["--git"] => bundle::dev(&root, !args.is_empty())?,
        "release" if args.is_empty() => distribution::release(&root)?,
        "sparkle-tools" if args.is_empty() => {
            println!("{}", distribution::sparkle_tools(&root)?.display())
        }
        "probe-release" if args.len() <= 1 => {
            distribution::probe(&root, args.first().map(String::as_str))?
        }
        _ => return Err(format!("invalid arguments for {command}: {args:?}")),
    }
    Ok(())
}
