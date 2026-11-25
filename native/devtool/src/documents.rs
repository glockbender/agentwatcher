use std::collections::BTreeMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

type Files = BTreeMap<String, String>;

macro_rules! re {
    ($pattern:literal) => {{
        static PATTERN: std::sync::LazyLock<regex::Regex> =
            std::sync::LazyLock::new(|| regex::Regex::new($pattern).unwrap());
        &*PATTERN
    }};
}

mod checks;
mod measurements;
#[cfg(test)]
mod tests;

fn frozen(name: &str) -> bool {
    name.starts_with("docs/research/") || name.starts_with("docs/articles/")
}

fn slug(heading: &str) -> String {
    re!(r"[^\w\- ]")
        .replace_all(&heading.trim().to_lowercase(), "")
        .replace(' ', "-")
}

fn heading(line: &str) -> Option<(usize, &str)> {
    let caps = re!(r"^(#+)\s+(.*?)\s*#*\s*$").captures(line)?;
    Some((caps[1].len(), caps.get(2)?.as_str()))
}

fn numbered_anchor(seen: &mut BTreeMap<String, usize>, title: &str) -> String {
    let base = slug(title);
    let count = seen.entry(base.clone()).or_default();
    let anchor = if *count == 0 {
        base
    } else {
        format!("{base}-{count}")
    };
    *count += 1;
    anchor
}

fn tracked_files() -> Result<Files, String> {
    let mut git = Command::new("git");
    if let Some(index) = std::env::var_os("AGENT_WATCH_VERIFY_INDEX") {
        git.env("GIT_INDEX_FILE", index);
    }
    let list = git
        .args(["ls-files", "-z"])
        .output()
        .map_err(|e| e.to_string())?;
    if !list.status.success() {
        return Err(String::from_utf8_lossy(&list.stderr).into_owned());
    }
    let mut files = Files::new();
    for name in list
        .stdout
        .split(|c| *c == 0)
        .filter_map(|s| std::str::from_utf8(s).ok())
    {
        let path = Path::new(name);
        if !matches!(
            path.extension().and_then(|s| s.to_str()),
            Some("md" | "swift" | "rs" | "kt" | "kts" | "py" | "sh" | "yml" | "plist" | "xml")
        ) {
            continue;
        }
        match fs::read_to_string(path) {
            Ok(text) => {
                files.insert(name.into(), text.replace("\r\n", "\n").replace('\r', "\n"));
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::InvalidData
                ) => {}
            Err(e) => return Err(format!("{name}: {e}")),
        }
    }
    Ok(files)
}

fn finish(errors: Vec<String>) -> Result<(), String> {
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("\n"))
    }
}

pub fn run(command: &str, args: &[String]) -> Result<(), String> {
    match (command, args) {
        ("check-docs", []) => {
            let files = tracked_files()?;
            finish(
                checks::CHECKS
                    .iter()
                    .flat_map(|check| check(&files))
                    .collect(),
            )
        }
        ("check-troubleshooting", []) => {
            let read = |p| fs::read_to_string(p).map_err(|e| format!("{p}: {e}"));
            finish(
                checks::troubleshooting(&read("TROUBLESHOOTING.md")?, &read("README.md")?)
                    .into_iter()
                    .map(|message| format!("TROUBLESHOOTING.md: {message}"))
                    .collect(),
            )
        }
        ("measurements", args) if args.is_empty() || args == ["--check"] => {
            let (rows, mut errors) = measurements::collect(&tracked_files()?);
            let text = measurements::render(rows);
            if args.is_empty() {
                fs::write(measurements::OUTPUT, text).map_err(|e| e.to_string())?;
            } else if fs::read_to_string(measurements::OUTPUT).map_err(|e| e.to_string())? != text {
                errors.push(format!(
                    "{} is stale; run `task measurements`",
                    measurements::OUTPUT
                ));
            }
            finish(errors)
        }
        _ => Err(format!("invalid arguments for {command}: {args:?}")),
    }
}
