//! Small decisions shared by local checks and the release workflows.
use std::{env, fs, path::Path, process::Command};

type R<T = ()> = Result<T, String>;
fn tag_version<'a>(tag: &'a str, prefix: &str) -> R<&'a str> {
    tag.strip_prefix(prefix)
        .filter(|v| {
            v.starts_with(|c: char| c.is_ascii_digit())
                && v.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
        })
        .ok_or_else(|| format!("Unexpected release tag {tag:?}"))
}
fn bundle_value(key: &str) -> R<String> {
    let output = Command::new("plutil")
        .args(["-extract", key, "raw", "-o", "-", "Resources/Info.plist"])
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("Missing {key} in Resources/Info.plist"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}
fn check_env(names: &[&str]) -> R {
    let missing: Vec<_> = names
        .iter()
        .filter(|n| env::var_os(n).is_none_or(|v| v.is_empty()))
        .copied()
        .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(format!("Missing release variables: {}", missing.join(", ")))
    }
}
fn status(c: &mut Command) -> R {
    let s = c.status().map_err(|e| e.to_string())?;
    if s.success() {
        Ok(())
    } else {
        Err(format!("{}: {s}", c.get_program().to_string_lossy()))
    }
}
fn draft(tag: &str) -> R {
    let version = tag_version(tag, "v")?;
    let notes = fs::File::create("dist/notes.md").map_err(|e| e.to_string())?;
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    status(
        Command::new(exe)
            .args(["release-notes", version])
            .stdout(notes),
    )?;
    let mut gh = Command::new("gh");
    gh.args([
        "release",
        "create",
        tag,
        "--draft",
        "--title",
        &format!("Agent Watch {version}"),
        "--notes-file",
        "dist/notes.md",
    ]);
    for extension in ["dmg", "dmg.sha256", "zip", "zip.sha256"] {
        gh.arg(format!("dist/AgentWatch-{version}.{extension}"));
    }
    status(gh.arg("dist/appcast.xml"))
}

fn local_plugin() -> R {
    let home = env::var_os("HOME").ok_or("HOME is missing")?;
    let apps = Path::new(&home).join("Applications");
    let installed = [apps.as_path(), Path::new("/Applications")]
        .iter()
        .any(|folder| {
            ["GoLand.app", "IntelliJ IDEA.app"]
                .iter()
                .any(|name| folder.join(name).is_dir())
        });
    if installed {
        return status(Command::new("task").arg("plugin-check"));
    }
    println!(
        "Skipped plugin check: no local IDE. Use task plugin-download to download the build platform."
    );
    Ok(())
}

pub(super) fn run(args: &[String]) -> R {
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["app-version", tag] => {
            let version = tag_version(tag, "v")?;
            let bundle = bundle_value("CFBundleShortVersionString")?;
            if bundle != version { return Err(format!("Tag {tag} differs from bundle version {bundle}")); }
            super::notes::run("changelog", &["check".into(), version.into()])
        }
        ["plugin-version", tag] => {
            let version = tag_version(tag, "plugin-v")?;
            let source = fs::read_to_string("ide-plugin/build.gradle.kts").map_err(|e| e.to_string())?;
            let expected = format!("version = \"{version}\"");
            if !source.lines().any(|line| line == expected) { return Err(format!("Plugin version differs from {tag}")); }
            Ok(())
        }
        ["plugin-signing"] => {
            check_env(&["CERTIFICATE_CHAIN", "PRIVATE_KEY", "PRIVATE_KEY_PASSWORD"])?;
            if env::var("GITHUB_EVENT_NAME").as_deref() == Ok("push") { check_env(&["PUBLISH_TOKEN"])?; }
            Ok(())
        }
        ["app-signing"] => {
            check_env(&["SPARKLE_PRIVATE_KEY"])?;
            bundle_value("SUPublicEDKey").map(|_| ())
        }
        ["draft", tag] => draft(tag),
        ["local-plugin"] => local_plugin(),
        _ => Err("ci app-version TAG | plugin-version TAG | app-signing | plugin-signing | draft TAG | local-plugin".into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn versions_stay_inside_the_artifact_folder() {
        assert_eq!(tag_version("v1.2.0-beta.1", "v"), Ok("1.2.0-beta.1"));
        assert!(tag_version("plugin-v0/../../x", "plugin-v").is_err());
        assert!(tag_version("1", "v").is_err());
    }
}
