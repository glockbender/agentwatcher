//! Claude and Codex use the same `PreToolUse` decision for shell commands.
mod commands;
mod policy;
mod shell;

use crate::process::{Cancellation, EXPIRED};
use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use serde_json::{Value, json};
use std::io::Write;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const TIMEOUT: &str = "The repository could not be inspected before the hook deadline.";
const MAX_EVENT_BYTES: usize = 16 * 1024 * 1024;
const MAX_COMMAND_CHARS: usize = 1_000_000;
const GUIDANCE: &str = "with repository (absolute working tree path), destination (refs/heads/name or refs/tags/name), remote (configured name, default origin), and reason. For deletion set delete to true and omit source and force. For an update use source (default HEAD) and set force to true only when explicitly requested. The CLI shows the user an approval window and executes the approved operation itself. Never answer the window, retry a refusal or execute a fallback push.";

fn inspect(
    payload: &Value,
    binary: &Path,
    cancel: &Cancellation,
    deadline: Instant,
) -> Result<Option<String>, String> {
    let payload = payload.as_object().ok_or("Expected a hook event object.")?;
    let Some(tool) = payload.get("tool_input").and_then(Value::as_object) else {
        return Ok(None);
    };
    let Some(command) = tool
        .get("command")
        .or_else(|| tool.get("cmd"))
        .and_then(Value::as_str)
    else {
        return Ok(None);
    };
    if command.trim().is_empty() {
        return Ok(None);
    }
    if command.len() > MAX_COMMAND_CHARS && command.chars().count() > MAX_COMMAND_CHARS {
        return Err("The command is too long to check. Split it into smaller commands.".into());
    }
    let cwd = match payload
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
    {
        Some(path) => PathBuf::from(path),
        None => std::env::current_dir().map_err(|_| "The current folder is unavailable.")?,
    };
    let cwd = match tool.get("workdir") {
        Some(Value::String(path)) => cwd.join(path),
        None | Some(Value::Null) => cwd,
        _ => return Err("Invalid command working folder.".into()),
    };
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("~"), PathBuf::from);
    let parsed = shell::parse(command, deadline)?;
    let reason = policy::check(parsed, &cwd, &home, cancel, deadline)?;
    Ok(reason.map(|reason| {
        format!(
            "{reason}. For one intended reference call {} push '<JSON object>' {GUIDANCE}",
            crate::domain::quote(&binary.to_string_lossy())
        )
    }))
}

fn read_event(input: impl AsFd, cancel: &Cancellation, deadline: Instant) -> Result<Value, String> {
    let mut bytes = Vec::new();
    let mut buffer = [0; 8192];
    let mut source = [PollFd::new(input.as_fd(), PollFlags::POLLIN)];
    loop {
        cancel.check(deadline).map_err(|reason| {
            if reason == EXPIRED {
                TIMEOUT.into()
            } else {
                reason
            }
        })?;
        let wait = deadline.saturating_duration_since(Instant::now());
        let timeout =
            PollTimeout::try_from(wait.min(Duration::from_millis(100))).map_err(|_| TIMEOUT)?;
        match poll(&mut source, timeout) {
            Ok(0) | Err(Errno::EINTR) => continue,
            Ok(_) => {}
            Err(_) => return Err("The hook could not read the event.".into()),
        }
        match nix::unistd::read(&input, &mut buffer) {
            Ok(0) => break,
            Ok(count) if bytes.len() + count <= MAX_EVENT_BYTES => {
                bytes.extend_from_slice(&buffer[..count]);
            }
            Ok(_) => return Err("The hook event is too large to inspect.".into()),
            Err(Errno::EINTR | Errno::EAGAIN) => {}
            Err(_) => return Err("The hook could not read the event.".into()),
        }
    }
    serde_json::from_slice(&bytes).map_err(|_| "The hook could not read the event.".into())
}

fn inspect_event() -> Result<Option<String>, String> {
    let deadline = Instant::now() + Duration::from_secs(6);
    let cancel = Cancellation::for_command()?;
    let event = read_event(std::io::stdin(), &cancel, deadline)?;
    let path =
        std::env::current_exe().map_err(|_| "The Agent Watch Git executable is unavailable.")?;
    inspect(&event, &path, &cancel, deadline)
}

pub(super) fn run(args: &[String]) -> Result<(), String> {
    if args == ["--check"] {
        return writeln!(std::io::stdout().lock(), "agent-watch-git-hook-ok")
            .map_err(|_| "The hook output is unavailable.".into());
    }
    let decision = if args.is_empty()
        || matches!(args, [flag, host] if flag == "--host" && matches!(host.as_str(), "codex" | "claude"))
    {
        inspect_event()
    } else {
        Err("Unexpected hook configuration.".into())
    };
    if let Some(reason) = decision.unwrap_or_else(Some) {
        writeln!(std::io::stdout().lock(),
            "{}",
            json!({"hookSpecificOutput":{
                "hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":format!("Agent Watch Git: {reason}")
            }})
        ).map_err(|_| "The hook output is unavailable.")?;
    }
    Ok(())
}
