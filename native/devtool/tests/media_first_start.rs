// The test executable doubles as a fake Claude process; no account, network, or display.
#[cfg(target_os = "macos")]
mod mac {
    use signal_hook::consts::SIGTERM;
    use std::fs;
    use std::io::{IsTerminal, Read, Write};
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    fn mock() {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap());
        fs::write(home.join("pid"), std::process::id().to_string()).unwrap();
        assert!(std::io::stdin().is_terminal());
        let size = Command::new("/bin/stty")
            .arg("size")
            .stdin(Stdio::inherit())
            .output()
            .unwrap();
        assert_eq!(String::from_utf8_lossy(&size.stdout).trim(), "40 120");
        assert!(
            Command::new("/bin/stty")
                .args(["raw", "-echo"])
                .status()
                .unwrap()
                .success()
        );
        let stopped = Arc::new(AtomicBool::new(false));
        signal_hook::flag::register(SIGTERM, stopped.clone()).unwrap();
        // Split a query between two writes; the relay must still answer without reading a model response.
        std::io::stdout().write_all(b"\x1b[6").unwrap();
        std::io::stdout().flush().unwrap();
        std::thread::sleep(Duration::from_millis(80));
        std::io::stdout()
            .write_all(b"n\x1b]10;?\x07\x1b]11;?\x07")
            .unwrap();
        std::io::stdout().flush().unwrap();
        let expected = b"\x1b[1;1R\x1b]10;rgb:ffff/ffff/ffff\x07\x1b]11;rgb:0000/0000/0000\x07";
        let mut received = vec![0; expected.len()];
        std::io::stdin().read_exact(&mut received).unwrap();
        assert_eq!(received, expected);
        if std::env::var("AW_TEST_PROMPT").unwrap() == "managed" {
            print!("\x1b[35mManaged settings require approval\x1b[0m\r\n");
            std::io::stdout().flush().unwrap();
            // Nonblocking read so SIGTERM can end a still-unanswered prompt gracefully.
            let input = std::io::stdin();
            nix::fcntl::fcntl(
                &input,
                nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
            )
            .unwrap();
            let mut byte = [0; 1];
            while !stopped.load(Ordering::Acquire) {
                if input.lock().read(&mut byte).ok() == Some(1) {
                    assert_eq!(byte, b"\r"[..]);
                    fs::write(home.join("approved"), "yes").unwrap();
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        if !stopped.load(Ordering::Acquire) {
            println!("? for shortcuts");
            std::io::stdout().flush().unwrap();
        }
        while !stopped.load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_millis(20));
        }
        fs::write(home.join("terminated"), "yes").unwrap();
    }

    fn case(root: &Path, scenario: &str, approve: bool, ready: bool) {
        let home = root.join(format!("{scenario}-{approve}"));
        fs::create_dir(&home).unwrap();
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_agent-watch-devtool"));
        cmd.env_clear()
            .env("HOME", &home)
            .env("PATH", format!("{}:/usr/bin:/bin", root.display()))
            .env("AW_TEST_PROMPT", scenario)
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .args(["media", "first-start"]);
        if approve {
            cmd.arg("--approve-managed-settings");
        }
        let mut child = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let until = Instant::now() + Duration::from_secs(20);
        while child.try_wait().unwrap().is_none() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(50));
        }
        if child.try_wait().unwrap().is_none() {
            if let Ok(pid) = fs::read_to_string(home.join("pid")) {
                let _ = Command::new("/bin/kill")
                    .args(["-TERM", pid.trim()])
                    .status();
            }
            let _ = child.kill();
            let _ = child.wait();
            panic!("The first-start command did not finish");
        }
        let out = child.wait_with_output().unwrap();
        assert_eq!(
            out.status.success(),
            ready,
            "stdout {:?}, stderr {:?}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(home.join("approved").is_file(), approve);
        assert!(home.join("terminated").is_file());
    }

    pub fn run() {
        if Path::new(&std::env::args_os().next().unwrap())
            .file_name()
            .unwrap()
            == "claude"
        {
            mock();
            return;
        }
        let root = std::env::temp_dir().join(format!(
            "aw-pty-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        symlink(std::env::current_exe().unwrap(), root.join("claude")).unwrap();
        case(&root, "ready", false, true);
        case(&root, "managed", false, false);
        case(&root, "managed", true, true);
        assert!(
            Command::new("/usr/bin/trash")
                .arg(root)
                .status()
                .unwrap()
                .success()
        );
        println!("3 synthetic first-start terminal scenarios passed");
    }
}
fn main() {
    #[cfg(target_os = "macos")]
    mac::run();
}
