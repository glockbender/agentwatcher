use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};
use tempfile::tempfile;

pub(crate) type Env = BTreeMap<OsString, OsString>;

pub(crate) fn executable(name: &str) -> Result<PathBuf> {
    let name = if cfg!(windows) && !name.ends_with(".exe") {
        format!("{name}.exe")
    } else {
        name.to_owned()
    };
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|dir| dir.join(&name))
        .find(|path| path.is_file())
        .with_context(|| format!("Missing {name} in PATH"))
}

pub(crate) fn isolated(program: impl AsRef<OsStr>, cwd: &Path, env: &Env) -> Command {
    let mut cmd = Command::new(program);
    cmd.env_clear()
        .envs(env)
        .current_dir(cwd)
        .stdin(Stdio::null());
    cmd
}

pub(crate) fn wait(child: &mut Child, timeout: Duration) -> Result<ExitStatus> {
    let end = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if Instant::now() >= end {
            let _ = child.kill();
            let _ = child.wait();
            bail!("Process exceeded its {}s deadline", timeout.as_secs());
        }
        std::thread::sleep(Duration::from_millis(35));
    }
}

pub(crate) fn output(cmd: &mut Command, timeout: Duration) -> Result<String> {
    let mut stdout = tempfile()?;
    let mut stderr = tempfile()?;
    let program = cmd.get_program().to_string_lossy();
    let operation = match cmd.get_args().next() {
        Some(arg) => format!("{program} {}", arg.to_string_lossy()),
        None => program.into_owned(),
    };
    let mut child = cmd
        .stdout(stdout.try_clone()?)
        .stderr(stderr.try_clone()?)
        .spawn()
        .with_context(|| format!("Starting {operation}"))?;
    let status = wait(&mut child, timeout).with_context(|| format!("Waiting for {operation}"))?;
    if !status.success() {
        stderr.rewind()?;
        let mut error = String::new();
        stderr.take(8192).read_to_string(&mut error)?;
        bail!("{operation} exited with {status}: {}", error.trim());
    }
    stdout.rewind()?;
    let mut text = String::new();
    stdout.read_to_string(&mut text)?;
    Ok(text.trim_end_matches(['\r', '\n']).to_owned())
}
