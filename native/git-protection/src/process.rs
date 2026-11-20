use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{Signal, killpg};
use nix::sys::stat::{SFlag, fstat};
use nix::unistd::Pid;
use nix::unistd::getppid;
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use std::io::{ErrorKind, Read};
use std::os::fd::AsFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_OUTPUT: usize = 1024 * 1024;

#[derive(Clone)]
pub struct Cancellation {
    cancelled: Arc<Mutex<bool>>,
    caller: Option<Arc<Caller>>,
}

struct Caller {
    parent: Pid,
    pipe_output: bool,
    interrupted: Arc<AtomicBool>,
    signals: Vec<signal_hook::SigId>,
}

impl Drop for Caller {
    fn drop(&mut self) {
        for id in &self.signals {
            signal_hook::low_level::unregister(*id);
        }
    }
}

impl Caller {
    fn disconnected(&self) -> bool {
        self.interrupted.load(Ordering::Acquire)
            || getppid() != self.parent
            || (self.pipe_output && lost_reader(std::io::stdout()))
    }
}

fn lost_reader(output: impl AsFd) -> bool {
    let mut descriptors = [PollFd::new(output.as_fd(), PollFlags::POLLOUT)];
    match poll(&mut descriptors, PollTimeout::ZERO) {
        Ok(_) => descriptors[0].revents().is_none_or(|flags| {
            flags.intersects(PollFlags::POLLHUP | PollFlags::POLLERR | PollFlags::POLLNVAL)
        }),
        Err(nix::errno::Errno::EINTR) => false,
        Err(_) => true,
    }
}

/// What `check` says once the deadline has passed.
pub const EXPIRED: &str = "The confirmation expired.";

impl Cancellation {
    pub fn new() -> Self {
        Self {
            cancelled: Arc::new(Mutex::new(false)),
            caller: None,
        }
    }

    /// Only an interactive shell command is tied to the invoking parent and output pipe.
    /// MCP has its own explicit request cancellation and connection lifecycle.
    pub fn for_command() -> Result<Self, String> {
        let parent = getppid();
        if parent.as_raw() <= 1 {
            return Err("The calling process is no longer available.".into());
        }
        let output = fstat(std::io::stdout()).map_err(|_| "The caller output is unavailable.")?;
        let kind = SFlag::from_bits_truncate(output.st_mode) & SFlag::S_IFMT;
        let mut caller = Caller {
            parent,
            pipe_output: kind == SFlag::S_IFIFO || kind == SFlag::S_IFSOCK,
            interrupted: Arc::new(AtomicBool::new(false)),
            signals: Vec::new(),
        };
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            caller.signals.push(
                signal_hook::flag::register(sig, caller.interrupted.clone())
                    .map_err(|_| "Signal handling could not start.")?,
            );
        }
        Ok(Self {
            caller: Some(Arc::new(caller)),
            ..Self::new()
        })
    }

    fn caller_gone(&self) -> bool {
        self.caller
            .as_ref()
            .is_some_and(|caller| caller.disconnected())
    }

    #[cfg(any(test, feature = "mcp-fixture"))]
    pub fn cancel(&self) {
        *self
            .cancelled
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    }

    pub fn check(&self, deadline: Instant) -> Result<(), String> {
        if self.caller_gone() || *self.cancelled.lock().map_err(|_| "The request stopped.")? {
            Err("The request was cancelled.".into())
        } else if Instant::now() >= deadline {
            Err(EXPIRED.into())
        } else {
            Ok(())
        }
    }
}

pub struct Output {
    pub status: ExitStatus,
    pub stdout: String,
}

pub enum RunError {
    NotStarted(String),
    /// Git itself could not be started: the reason names the system error.
    SpawnFailed(String),
    /// Started, then stopped before it finished: the reason says why.
    Interrupted(String),
}

struct Group(Child);

impl Drop for Group {
    fn drop(&mut self) {
        // The leader may have exited while its hooks still hold the output pipes.
        if let Ok(pid) = i32::try_from(self.0.id()) {
            let _ = killpg(Pid::from_raw(pid), Signal::SIGKILL);
        }
        let _ = self.0.wait();
    }
}

fn drain(pipe: &mut impl Read, output: &mut Vec<u8>) -> Result<bool, String> {
    let mut buffer = [0; 8192];
    // Limit each turn so a noisy child cannot delay cancellation indefinitely.
    for _ in 0..32 {
        match pipe.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                output.extend_from_slice(&buffer[..count]);
                if output.len() > MAX_OUTPUT {
                    return Err("Git produced too much output.".into());
                }
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => return Err("Git output could not be read.".into()),
        }
    }
    Ok(false)
}

pub fn run(
    command: &mut Command,
    cancel: &Cancellation,
    deadline: Instant,
    start_deadline: Instant,
) -> Result<Output, RunError> {
    let child =
        {
            // Starting Git and accepting cancellation are serialized; consent cannot
            // start another process after cancellation has already been observed.
            let cancelled = cancel
                .cancelled
                .lock()
                .map_err(|_| RunError::NotStarted("The request stopped.".into()))?;
            if *cancelled || cancel.caller_gone() || Instant::now() >= start_deadline {
                return Err(RunError::NotStarted(
                    "The request was cancelled or expired.".into(),
                ));
            }
            command
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            command.process_group(0);
            Group(command.spawn().map_err(|error| {
                RunError::SpawnFailed(format!("Git could not be started: {error}"))
            })?)
        };
    collect(child, cancel, deadline).map_err(RunError::Interrupted)
}

fn collect(mut child: Group, cancel: &Cancellation, deadline: Instant) -> Result<Output, String> {
    let mut stdout = child.0.stdout.take().ok_or("Git stdout is unavailable.")?;
    let mut stderr = child.0.stderr.take().ok_or("Git stderr is unavailable.")?;
    for fd in [
        &stdout as &dyn std::os::fd::AsFd,
        &stderr as &dyn std::os::fd::AsFd,
    ] {
        fcntl(fd, FcntlArg::F_SETFL(OFlag::O_NONBLOCK))
            .map_err(|_| "Git pipes could not be configured.")?;
    }
    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut status = None;
    loop {
        cancel.check(deadline)?;
        let out_closed = drain(&mut stdout, &mut out)?;
        let err_closed = drain(&mut stderr, &mut err)?;
        if status.is_none() {
            status = child.0.try_wait().map_err(|_| "Git could not be reaped.")?;
        }
        if let Some(status) = status.filter(|_| out_closed && err_closed) {
            return Ok(Output {
                status,
                stdout: String::from_utf8(out).map_err(|_| "Git returned invalid text.")?,
            });
        }
        // Wait for output or exit instead of waking 100 times a second during a human prompt.
        // A short bound also lets us notice parent loss and disconnected clients.
        let mut open_pipes = [
            PollFd::new(stdout.as_fd(), PollFlags::POLLIN),
            PollFd::new(stderr.as_fd(), PollFlags::POLLIN),
        ];
        let open = match (out_closed, err_closed) {
            (false, false) => &mut open_pipes[..],
            (false, true) => &mut open_pipes[..1],
            (true, false) => &mut open_pipes[1..],
            (true, true) => {
                // Pipe closure can precede the exit status by one scheduler turn.
                thread::sleep(Duration::from_millis(2));
                continue;
            }
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        let timeout = PollTimeout::try_from(remaining.min(Duration::from_millis(100)))
            .map_err(|_| "Invalid process deadline.")?;
        match poll(open, timeout) {
            Ok(_) | Err(nix::errno::Errno::EINTR) => {}
            Err(_) => return Err("Git pipes could not be monitored.".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelled_or_expired_calls_never_start_a_process() {
        let cancelled = Cancellation::new();
        cancelled.cancel();
        let mut command = Command::new("this-command-must-never-be-started");
        let error = run(
            &mut command,
            &cancelled,
            Instant::now() + Duration::from_secs(1),
            Instant::now() + Duration::from_secs(1),
        )
        .err()
        .unwrap();
        assert!(matches!(error, RunError::NotStarted(reason) if reason.contains("cancelled")));
        let error = run(
            &mut command,
            &Cancellation::new(),
            Instant::now(),
            Instant::now(),
        )
        .err()
        .unwrap();
        assert!(matches!(error, RunError::NotStarted(reason) if reason.contains("expired")));
    }
}
