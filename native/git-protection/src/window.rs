use crate::confirmation::Form;
use crate::process::{self, Cancellation};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::process::Command;
use std::time::Instant;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub message: String,
    pub schema: Value,
}

pub fn confirm(form: Form, cancel: &Cancellation, deadline: Instant) -> Result<Value, String> {
    let executable =
        std::env::current_exe().map_err(|_| "The confirmation program is unavailable.")?;
    let request = serde_json::to_string(&Request {
        message: form.message,
        schema: form.schema,
    })
    .map_err(|_| "The confirmation could not be prepared.")?;
    let mut command = Command::new(executable);
    command.args(["--confirmation-window", &request]);
    obtain(&mut command, cancel, deadline)
}

fn obtain(
    command: &mut Command,
    cancel: &Cancellation,
    deadline: Instant,
) -> Result<Value, String> {
    match process::run(command, cancel, deadline, deadline) {
        Ok(output) if output.status.success() && output.stdout.trim().is_empty() => {
            Err("The confirmation window was closed without approval.".into())
        }
        Ok(output) if output.status.success() => serde_json::from_str(&output.stdout)
            .map_err(|_| "The confirmation window returned an invalid answer.".into()),
        Ok(_) => Err("The confirmation window could not finish.".into()),
        Err(process::RunError::NotStarted(_) | process::RunError::SpawnFailed(_)) => {
            Err("The confirmation window could not open or the request was cancelled.".into())
        }
        Err(process::RunError::Interrupted(_)) => {
            Err("The confirmation window was cancelled or expired.".into())
        }
    }
}

/// Show a native window in a short-lived child of the MCP server.
///
/// # Errors
/// Returns an error for an invalid request or an unavailable graphical session.
pub fn show(request: &str) -> Result<Value, String> {
    let request: Request = serde_json::from_str(request).map_err(|_| "Invalid window request.")?;
    if request.message.len() > 32_768 || request.schema.to_string().len() > 8192 {
        return Err("The window request is too large.".into());
    }
    #[cfg(target_os = "macos")]
    {
        appkit::show(&request)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = request;
        Err("Native confirmation windows require macOS.".into())
    }
}

#[cfg(target_os = "macos")]
mod appkit {
    use super::{Request, Value};
    use muda::{Menu, PredefinedMenuItem, Submenu};
    use objc2::{MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{
        NSAlert, NSAlertSecondButtonReturn, NSAlertStyle, NSApplication,
        NSApplicationActivationPolicy, NSTextField,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};
    use serde_json::json;

    pub fn show(request: &Request) -> Result<Value, String> {
        let parent = nix::unistd::getppid();
        if parent.as_raw() <= 1 {
            return Err("The requesting server is no longer running.".into());
        }
        // SIGKILL cannot run the server's cleanup. An orphan window must not
        // stay actionable after that server is gone; this child never runs Git.
        std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
            loop {
                if nix::unistd::getppid() != parent || std::time::Instant::now() >= deadline {
                    std::process::exit(1);
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        });
        let mtm = MainThreadMarker::new().ok_or("The window requires the main thread.")?;
        let app = NSApplication::sharedApplication(mtm);
        // A helper inside an LSUIElement bundle already starts as an accessory.
        // AppKit can return false when asked to select its current policy.
        if app.activationPolicy() != NSApplicationActivationPolicy::Accessory
            && !app.setActivationPolicy(NSApplicationActivationPolicy::Accessory)
        {
            return Err("The graphical session is unavailable.".into());
        }
        // A standalone AppKit process has no default Edit menu. Standard menu
        // actions route Command-C/V/X/A to the focused field without inspecting
        // the clipboard or introducing custom approval shortcuts.
        let application = Submenu::with_items(
            "Agent Watch",
            true,
            &[&PredefinedMenuItem::quit(Some("Отменить и закрыть"))],
        )
        .map_err(|_| "The application menu could not be created.")?;
        let edit = Submenu::with_items(
            "Правка",
            true,
            &[
                &PredefinedMenuItem::cut(Some("Вырезать")),
                &PredefinedMenuItem::copy(Some("Копировать")),
                &PredefinedMenuItem::paste(Some("Вставить")),
                &PredefinedMenuItem::select_all(Some("Выделить всё")),
            ],
        )
        .map_err(|_| "The edit menu could not be created.")?;
        let menu = Menu::with_items(&[&application, &edit])
            .map_err(|_| "The window menu could not be created.")?;
        menu.init_for_nsapp();
        let alert = NSAlert::new(mtm);
        alert.setAlertStyle(NSAlertStyle::Warning);
        let (heading, detail) = request
            .message
            .split_once("\n\n")
            .ok_or("Invalid window text.")?;
        alert.setMessageText(&NSString::from_str(heading));
        let name = request.schema["properties"].get("repository_name");
        let field = if let Some(property) = name {
            let label = property["title"].as_str().ok_or("Invalid name field.")?;
            alert.setInformativeText(&NSString::from_str(&format!("{detail}\n\n{label}")));
            let field = NSTextField::initWithFrame(
                NSTextField::alloc(mtm),
                NSRect::new(NSPoint::new(0., 0.), NSSize::new(420., 26.)),
            );
            field.setStringValue(&NSString::from_str(""));
            field.setPlaceholderString(Some(&NSString::from_str("Имя репозитория")));
            alert.setAccessoryView(Some(&field));
            Some(field)
        } else {
            alert.setInformativeText(&NSString::from_str(detail));
            None
        };
        let permission = if name.is_some() {
            "Выполнить"
        } else {
            request.schema["properties"]["decision"]["oneOf"]
                .as_array()
                .and_then(|choices| choices.iter().find(|choice| choice["const"] == "continue"))
                .and_then(|choice| choice["title"].as_str())
                .ok_or("Invalid risk choice.")?
        };
        let stop = alert.addButtonWithTitle(&NSString::from_str("Отменить всю операцию"));
        stop.setKeyEquivalent(&NSString::from_str("\u{1b}"));
        let proceed = alert.addButtonWithTitle(&NSString::from_str(permission));
        proceed.setKeyEquivalent(&NSString::from_str(""));
        alert
            .window()
            .setTitle(&NSString::from_str("Agent Watch — подтверждение операции"));
        // AppKit otherwise ignores Quit during a modal alert. This child owns
        // no Git operation; exiting without an answer must cancel the request.
        alert
            .window()
            .setPreventsApplicationTerminationWhenModal(false);
        #[allow(deprecated)]
        app.activateIgnoringOtherApps(true);
        if let Some(field) = &field {
            alert.window().makeFirstResponder(Some(field));
        }
        if alert.runModal() != NSAlertSecondButtonReturn {
            return Ok(json!({"action":"decline"}));
        }
        let content = field.map_or_else(
            || json!({"decision":"continue"}),
            |field| json!({"repository_name":field.stringValue().to_string()}),
        );
        Ok(json!({"action":"accept","content":content}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn malformed_requests_never_open_a_window() {
        for request in [
            "{}",
            "null",
            "{\"message\":\"x\",\"schema\":{},\"approve\":true}",
        ] {
            assert!(show(request).is_err());
        }
        let oversized = serde_json::json!({"message":"x".repeat(32_769),"schema":{}});
        assert!(show(&oversized.to_string()).is_err());
    }

    #[test]
    fn failed_or_corrupt_window_output_cannot_authorize_a_push() {
        for script in ["exit 1", "printf 'not-json'", "kill -TERM $$"] {
            let deadline = Instant::now() + Duration::from_secs(2);
            assert!(
                obtain(
                    Command::new("/bin/sh").args(["-c", script]),
                    &Cancellation::new(),
                    deadline
                )
                .is_err()
            );
        }
    }

    #[test]
    fn quitting_the_window_is_reported_as_closed_without_approval() {
        let deadline = Instant::now() + Duration::from_secs(2);
        let error = obtain(
            Command::new("/bin/sh").args(["-c", "exit 0"]),
            &Cancellation::new(),
            deadline,
        )
        .unwrap_err();
        assert!(error.contains("closed without approval"));
    }

    #[test]
    fn cancelled_and_expired_requests_stop_the_window_process() {
        for expire in [false, true] {
            let pid_file = std::env::temp_dir().join(format!(
                "mothership-window-lifetime-{}-{expire}.pid",
                std::process::id()
            ));
            assert!(!pid_file.exists());
            let script = format!(
                "echo $$ > {0}.tmp && mv {0}.tmp {0} && exec sleep 30",
                crate::domain::quote(pid_file.to_str().unwrap())
            );
            let cancel = Cancellation::new();
            let signal = cancel.clone();
            let ready = pid_file.clone();
            let cancellation = std::thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(2);
                while !ready.exists() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(5));
                }
                if !expire {
                    signal.cancel();
                }
            });
            let started = Instant::now();
            let timeout = if expire {
                Duration::from_secs(1)
            } else {
                Duration::from_secs(5)
            };
            assert!(
                obtain(
                    Command::new("/bin/sh").args(["-c", &script]),
                    &cancel,
                    started + timeout
                )
                .is_err()
            );
            cancellation.join().unwrap();
            assert!(started.elapsed() < Duration::from_secs(5));
            let pid: i32 = std::fs::read_to_string(&pid_file)
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            std::fs::remove_file(pid_file).unwrap();
            assert_eq!(
                nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None),
                Err(nix::errno::Errno::ESRCH)
            );
        }
    }
}
