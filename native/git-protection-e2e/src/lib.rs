use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::Result;
use clap::{Parser, Subcommand, ValueEnum};

#[cfg(target_os = "macos")]
mod clients;
mod execution;
mod fixture;
#[cfg(target_os = "macos")]
mod guest;
#[cfg(target_os = "macos")]
mod model;
#[cfg(target_os = "macos")]
mod upgrade;

#[derive(Clone, Copy, ValueEnum, Debug, PartialEq, Eq)]
enum Client {
    Claude,
    Codex,
}

#[derive(Parser)]
#[command(
    name = "git-e2e",
    about = "Test Git protection with local repositories and isolated client profiles"
)]
struct Options {
    #[command(subcommand)]
    operation: Operation,
}

#[derive(Subcommand)]
enum Operation {
    /// Prepare or inspect a disposable Git project, including on Windows.
    Fixture {
        #[command(subcommand)]
        action: FixtureAction,
    },
    /// Close a live chat while a destructive Git operation is waiting for approval.
    Close {
        client: Client,
        #[arg(long)]
        binary: PathBuf,
        #[arg(long)]
        windows: PathBuf,
    },
    /// Replace the signed application at the same installation path.
    Upgrade {
        #[arg(long)]
        bundle: PathBuf,
        #[arg(long)]
        previous_bundle: Option<PathBuf>,
        #[arg(long)]
        windows: PathBuf,
    },
}

#[derive(Subcommand)]
enum FixtureAction {
    Prepare { folder: PathBuf },
    Status { folder: PathBuf },
}

/// Test-tool entry point. Arguments start at the operation, without argv[0].
pub fn run(args: &[String]) -> ExitCode {
    let options = match Options::try_parse_from(
        std::iter::once("git-e2e").chain(args.iter().map(String::as_str)),
    ) {
        Ok(options) => options,
        Err(err) if !err.use_stderr() => {
            print!("{err}");
            return ExitCode::SUCCESS;
        }
        Err(err) => {
            eprint!("{err}");
            return ExitCode::from(2);
        }
    };
    let failure_code = if matches!(options.operation, Operation::Fixture { .. }) {
        2
    } else {
        1
    };
    match execute(options.operation) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::from(failure_code)
        }
    }
}

fn execute(operation: Operation) -> Result<u8> {
    match operation {
        Operation::Fixture {
            action: FixtureAction::Prepare { folder },
        } => fixture::prepare(&folder).map(|_| 0),
        Operation::Fixture {
            action: FixtureAction::Status { folder },
        } => fixture::status(&folder).map(|unchanged| u8::from(!unchanged)),
        #[cfg(target_os = "macos")]
        Operation::Close {
            client,
            binary,
            windows,
        } => guest::close(client, &binary, &windows).map(|()| 0),
        #[cfg(target_os = "macos")]
        Operation::Upgrade {
            bundle,
            previous_bundle,
            windows,
        } => upgrade::run(
            &bundle,
            previous_bundle
                .or_else(|| std::env::var_os("AGENT_WATCH_PREVIOUS_BUNDLE").map(PathBuf::from))
                .as_deref(),
            &windows,
        )
        .map(|()| 0),
        #[cfg(not(target_os = "macos"))]
        _ => anyhow::bail!(
            "Run the chat and upgrade checks in a disposable macOS guest with a graphical login."
        ),
    }
}
