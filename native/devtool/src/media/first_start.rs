//! The recording guest rehearses Claude's first start on a real controlling terminal.
use super::Result;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{Signal, kill, killpg};
use nix::unistd::Pid;
use regex::bytes::Regex;
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{
    Arc, LazyLock,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

const HELLO: &str = "agent-watch-media-child ";
const OUTPUT_LIMIT: usize = 256 * 1024;
static ANSI: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]",
    )
    .unwrap()
});

fn visible(raw: &[u8]) -> String {
    String::from_utf8_lossy(&ANSI.replace_all(raw, &b""[..])).into_owned()
}

pub(super) fn child() -> Result {
    if !std::io::IsTerminal::is_terminal(&std::io::stdin()) {
        return Err("The first-start worker requires a terminal".into());
    }
    println!("{HELLO}{}", std::process::id());
    std::io::stdout().flush().map_err(|e| e.to_string())?;
    let size = Command::new("/bin/stty")
        .args(["rows", "40", "cols", "120"])
        .status()
        .map_err(|e| e.to_string())?;
    if !size.success() {
        return Err("Cannot set the terminal size".into());
    }
    let err = Command::new("claude")
        .args([
            "--setting-sources",
            "project,local",
            "--strict-mcp-config",
            "--permission-mode",
            "default",
        ])
        .env("TERM", "xterm-256color")
        .env("IS_DEMO", "1")
        .exec();
    Err(format!("Claude did not start: {err}"))
}

#[derive(PartialEq)]
enum Input {
    Data,
    Idle,
    End,
}

struct Terminal {
    script: Child,
    output: ChildStdout,
    input: Option<ChildStdin>,
    worker: Option<Pid>,
    raw: Vec<u8>,
    signals: Vec<signal_hook::SigId>,
    interrupted: Arc<AtomicBool>,
    reaped: bool,
}

impl Terminal {
    fn start() -> Result<Self> {
        let mut script = Command::new("/usr/bin/script")
            .args(["-q", "/dev/null"])
            .arg(std::env::current_exe().map_err(|e| e.to_string())?)
            .args(["media", "first-start-child"])
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        let output = script.stdout.take().expect("piped output");
        let input = script.stdin.take().expect("piped input");
        let mut term = Self {
            script,
            output,
            input: Some(input),
            worker: None,
            raw: Vec::new(),
            signals: Vec::new(),
            interrupted: Arc::new(AtomicBool::new(false)),
            reaped: false,
        };
        fcntl(&term.output, FcntlArg::F_SETFL(OFlag::O_NONBLOCK)).map_err(|e| e.to_string())?;
        fcntl(
            term.input.as_ref().unwrap(),
            FcntlArg::F_SETFL(OFlag::O_NONBLOCK),
        )
        .map_err(|e| e.to_string())?;
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            term.signals.push(
                signal_hook::flag::register(sig, term.interrupted.clone())
                    .map_err(|e| e.to_string())?,
            );
        }
        Ok(term)
    }
    fn send(&mut self, bytes: &[u8]) -> Result {
        self.input
            .as_mut()
            .ok_or("Closed pseudo-terminal")?
            .write_all(bytes)
            .map_err(|e| format!("Cannot answer terminal: {e}"))
    }
    fn receive(&mut self, answer_queries: bool) -> Result<Input> {
        let mut readable = [PollFd::new(self.output.as_fd(), PollFlags::POLLIN)];
        match poll(&mut readable, PollTimeout::from(200u16)) {
            Ok(0) | Err(nix::errno::Errno::EINTR) => return Ok(Input::Idle),
            Err(error) => return Err(error.to_string()),
            Ok(_) => {}
        }
        let mut bytes = [0; 65536];
        let n = match self.output.read(&mut bytes) {
            Ok(0) => return Ok(Input::End),
            Ok(n) => n,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) =>
            {
                return Ok(Input::Idle);
            }
            Err(e) => return Err(e.to_string()),
        };
        let previous = self.raw.len();
        self.raw.extend_from_slice(&bytes[..n]);
        if self.worker.is_none()
            && let Some(end) = self.raw.iter().position(|b| *b == b'\n')
        {
            let first = std::str::from_utf8(&self.raw[..end])
                .map_err(|_| "Invalid terminal worker handshake")?;
            let pid = first
                .trim_end_matches('\r')
                .strip_prefix(HELLO)
                .and_then(|p| p.parse::<i32>().ok())
                .filter(|p| *p > 1)
                .ok_or("Invalid terminal worker handshake")?;
            self.worker = Some(Pid::from_raw(pid));
        }
        if answer_queries {
            for (query, reply) in [
                (&b"\x1b[6n"[..], &b"\x1b[1;1R"[..]),
                (&b"\x1b]10;?"[..], &b"\x1b]10;rgb:ffff/ffff/ffff\x07"[..]),
                (&b"\x1b]11;?"[..], &b"\x1b]11;rgb:0000/0000/0000\x07"[..]),
            ] {
                let span = &self.raw[previous.saturating_sub(query.len() - 1)..];
                if span.windows(query.len()).any(|s| s == query) {
                    self.send(reply)?;
                }
            }
        }
        if self.raw.len() > OUTPUT_LIMIT {
            self.raw.drain(..self.raw.len() - OUTPUT_LIMIT);
        }
        Ok(Input::Data)
    }
    fn end(&mut self) {
        if self.reaped {
            return;
        }
        // A signal may have arrived between starting the relay and observing its child's PID.
        let handshake = Instant::now() + Duration::from_secs(2);
        while self.worker.is_none()
            && Instant::now() < handshake
            && self.receive(false).unwrap_or(Input::End) != Input::End
        {}
        if self.script.try_wait().ok().flatten().is_none() {
            if let Some(pid) = self.worker {
                // Measured on Claude Code 2.1.294: repeated unclean exits disable the fullscreen renderer; give Claude time to exit on SIGTERM.
                let _ = kill(pid, Signal::SIGTERM);
            }
            let end = Instant::now() + Duration::from_secs(5);
            while self.script.try_wait().ok().flatten().is_none() && Instant::now() < end {
                if self.receive(false).unwrap_or(Input::End) == Input::End {
                    super::sleep(0.025);
                }
            }
            if self.script.try_wait().ok().flatten().is_none() {
                if let Some(pid) = self.worker {
                    let _ = kill(pid, Signal::SIGKILL);
                }
                let _ = killpg(Pid::from_raw(self.script.id() as i32), Signal::SIGKILL);
            }
        }
        self.input.take();
        let _ = self.script.wait();
        self.reaped = true;
        for id in self.signals.drain(..) {
            signal_hook::low_level::unregister(id);
        }
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.end();
    }
}

pub(super) fn run(args: &[String]) -> Result {
    let approve = match args {
        [] => false,
        [s] if s == "--approve-managed-settings" => true,
        _ => return Err("media first-start [--approve-managed-settings]".into()),
    };
    let mut terminal = Terminal::start()?;
    let mut approved = false;
    let mut ready = false;
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline && !terminal.interrupted.load(Ordering::Acquire) {
        match terminal.receive(true)? {
            Input::Idle => continue,
            Input::End => break,
            Input::Data => {}
        }
        let flat = visible(&terminal.raw).replace(' ', "");
        if !approved && flat.contains("Managedsettingsrequireapproval") {
            if !approve {
                break;
            }
            super::sleep(0.5);
            if terminal.interrupted.load(Ordering::Acquire) {
                break;
            }
            terminal.send(b"\r")?;
            approved = true;
        }
        if flat.contains("forshortcuts") {
            ready = true;
            break;
        }
    }
    let screen = visible(&terminal.raw);
    terminal.end();
    let lines = screen
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with(HELLO))
        .collect::<Vec<_>>();
    for l in &lines[lines.len().saturating_sub(25)..] {
        println!("{l}");
    }
    println!("--- approved managed settings: {approved}; prompt ready: {ready}");
    if ready {
        Ok(())
    } else {
        Err("Claude did not reach the input prompt".into())
    }
}

#[cfg(test)]
mod tests {
    use super::visible;
    #[test]
    fn strips_terminal_colours_and_titles() {
        assert_eq!(
            visible(b"\x1b]0;title\x07\x1b[31mManaged settings\x1b[0m"),
            "Managed settings"
        );
    }
}
