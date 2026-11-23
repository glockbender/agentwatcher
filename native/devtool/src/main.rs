mod ci;
mod documents;
mod gates;
mod git_tests;
mod media;
mod notes;
mod packaging;
mod update;

use std::{env, path::Path, process::ExitCode};

const USAGE: &str = "\
Usage: scripts/devtool COMMAND [arguments]

Build and run        build-app [debug|release] [output.app], dev [--git]
Release              release, release-notes VERSION, probe-release [TAG], sparkle-tools
Release files        changelog check|section VERSION [FILE], appcast VERSION URL SIGNATURE [FILE]
Repository checks    check-docs, check-troubleshooting, measurements [--check], pre-commit, pre-push
Client tests         git-e2e --help, test-cli-close, test-git-upgrade
Update tests         e2e-update [--from TAG [--as OLDER_VERSION]]
README recordings    media --help
CI checks            ci app-version|plugin-version TAG, ci local-plugin, ci app-signing|plugin-signing, ci draft TAG";

fn run() -> Result<(), String> {
    let args: Vec<_> = env::args().skip(1).collect();
    let Some((command, rest)) = args.split_first() else {
        return Err(USAGE.into());
    };
    if command == "--help" || command == "-h" {
        println!("{USAGE}");
        return Ok(());
    }
    if command == "update-guest" {
        return update::run_guest(rest);
    }
    if command == "media"
        && let Some(repo) = env::var_os("AW_MEDIA_REPO")
    {
        env::set_current_dir(repo).map_err(|e| format!("AW_MEDIA_REPO: {e}"))?;
    }
    let cwd = env::current_dir().map_err(|e| e.to_string())?;
    let root = cwd
        .ancestors()
        .find(|p| p.join("native/devtool/Cargo.toml").is_file())
        .or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2))
        .ok_or("Cannot locate the Agent Watch checkout")?;
    env::set_current_dir(root).map_err(|e| format!("{}: {e}", root.display()))?;
    match command.as_str() {
        "media" => media::run(rest),
        "ci" => ci::run(rest),
        "changelog" | "appcast" | "release-notes" => notes::run(command, rest),
        "build-app" | "dev" | "release" | "probe-release" | "sparkle-tools" => {
            packaging::run(command, rest)
        }
        "git-e2e" | "test-cli-close" | "test-git-upgrade" => git_tests::run(command, rest),
        "check-docs" | "check-troubleshooting" | "measurements" => documents::run(command, rest),
        "e2e-update" => update::host(rest),
        "pre-commit" | "pre-push" => gates::run(command),
        _ => Err(USAGE.into()),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
