use super::*;
use regex::Regex;
use std::io::Write;

struct Suite {
    share: PathBuf,
    out: PathBuf,
    home: PathBuf,
    copy: PathBuf,
    ax: PathBuf,
}

impl Suite {
    fn pid(&self) -> Option<String> {
        let target = self.copy.join("Contents/MacOS/AgentWatch");
        output(&mut cmd("ps", &["-axo", "pid=,comm="]))
            .ok()?
            .lines()
            .find_map(|line| {
                let (pid, path) = line.trim().split_once(char::is_whitespace)?;
                (path.trim() == target.to_str()?).then(|| pid.to_owned())
            })
    }
    fn quit(&self) -> R {
        if let Some(pid) = self.pid() {
            checked(&mut cmd("kill", &[&pid]))?;
            if wait(10, || self.pid().is_none()).is_err() && self.pid().as_ref() == Some(&pid) {
                checked(&mut cmd("kill", &["-KILL", &pid]))?;
                wait(3, || self.pid().is_none())?;
            }
        }
        Ok(())
    }
    fn fresh(&self) -> R {
        self.quit()?;
        if self.copy.exists() {
            checked(Command::new("/usr/bin/trash").arg(&self.copy))?;
        }
        mkdir(self.copy.parent().ok_or("Missing app directory")?)?;
        checked(
            cmd("ditto", &["-x", "-k"])
                .arg(self.share.join("old.zip"))
                .arg(self.copy.parent().ok_or("Missing app directory")?),
        )?;
        let _ = cmd("defaults", &["delete", "com.glockbender.agentwatch"]).output();
        io(fs::write(self.out.join("case-start"), []))?;
        let cache = self.home.join("Library/Caches/com.glockbender.agentwatch");
        if cache.exists() {
            checked(Command::new("/usr/bin/trash").arg(cache))?;
        }
        Ok(())
    }
    fn launch(&self, case: &str, feed: Option<&str>) -> R<String> {
        let mut c = Command::new("open");
        if let Some(feed) = feed {
            c.arg("--env")
                .arg(format!("AGENT_WATCH_UPDATE_FEED={feed}"))
                .args(["--env", "AGENT_WATCH_UPDATE_DIAGNOSTICS=1"]);
        }
        checked(
            c.arg("--stderr")
                .arg(self.out.join(format!("{case}-stderr.log")))
                .arg(&self.copy),
        )?;
        wait(15, || self.pid().is_some())?;
        self.pid().ok_or("The app quit during launch".into())
    }
    fn text(&self, pid: &str) -> String {
        output(&mut cmd(&self.ax, &["text", pid])).unwrap_or_default()
    }
    fn has(&self, pid: &str, pattern: &Regex) -> bool {
        pattern.is_match(&self.text(pid))
    }
    fn press(&self, pid: &str, title: &str) -> R {
        checked(&mut cmd(&self.ax, &["press", pid, title]))
    }
    fn version(&self) -> R<String> {
        output(
            cmd(
                "plutil",
                &["-extract", "CFBundleShortVersionString", "raw", "-o", "-"],
            )
            .arg(self.copy.join("Contents/Info.plist")),
        )
    }
    fn evidence(&self, case: &str, pid: &str) {
        let _ = cmd("screencapture", &["-x"])
            .arg(self.out.join(format!("{case}.png")))
            .status();
        let _ = fs::write(self.out.join(format!("{case}.txt")), self.text(pid));
    }
    fn intact(&self, pid: &str) -> R {
        if self.version()? != "0.9.0" || self.pid().as_deref() != Some(pid) {
            return Err("Original version or running process changed".into());
        }
        checked(cmd("codesign", &["--verify", "--strict"]).arg(&self.copy))?;
        let cache = self
            .home
            .join("Library/Caches/com.glockbender.agentwatch/org.sparkle-project.Sparkle");
        if cache.is_dir() {
            for child in io(fs::read_dir(cache))? {
                let path = io(child)?.path();
                if path.is_dir() && io(fs::read_dir(path))?.next().is_some() {
                    return Err("Sparkle left update files behind".into());
                }
            }
        }
        Ok(())
    }
    fn quiet_failure(&self, case: &str, url: &str) -> R {
        self.fresh()?;
        let pid = self.launch(case, Some(url))?;
        thread::sleep(Duration::from_secs(15));
        if self.has(&pid, &regex("Install Update|error")?) {
            self.evidence(case, &pid);
            return Err("Unexpected update window".into());
        }
        self.intact(&pid)
    }
    // A download cut short leaves its part in the temp folder (measured on macOS 15.7.7).
    fn failed_download(&self, case: &str, url: &str, seconds: u64) -> R {
        self.fresh()?;
        let pid = self.launch(case, Some(url))?;
        self.offer(&pid)?;
        self.press(&pid, "Install Update")?;
        let error = regex("error|could not|failed|improperly")?;
        let shown = wait(seconds, || self.has(&pid, &error));
        self.evidence(case, &pid);
        let marker = io(fs::metadata(self.out.join("case-start")).and_then(|m| m.modified()))?;
        if let Ok(temp) = output(&mut cmd("getconf", &["DARWIN_USER_TEMP_DIR"]))
            && let Ok(files) = fs::read_dir(temp)
        {
            let count = files
                .flatten()
                .filter(|f| {
                    f.file_name()
                        .to_string_lossy()
                        .starts_with("CFNetworkDownload_")
                        && f.metadata()
                            .and_then(|m| m.modified())
                            .is_ok_and(|t| t > marker)
                })
                .count();
            io(fs::write(
                self.out.join(format!("{case}-partial-downloads.txt")),
                count.to_string(),
            ))?;
        }
        shown?;
        if self.has(&pid, &regex("Install and Relaunch")?) {
            return Err("Failed download offered installation".into());
        }
        self.press(&pid, "OK")
            .or_else(|_| self.press(&pid, "Cancel"))?;
        thread::sleep(Duration::from_secs(1));
        self.intact(&pid)
    }
    fn offer(&self, pid: &str) -> R {
        let offer = regex("Install Update")?;
        wait(30, || self.has(pid, &offer))
    }
    fn relaunch(&self, case: &str, old: &str, version: &str) -> R {
        let install = regex("Install and Relaunch")?;
        wait(120, || self.has(old, &install))?;
        wait(20, || {
            self.pid().as_deref() != Some(old) || self.press(old, "Install and Relaunch").is_ok()
        })?;
        wait(60, || self.pid().is_some_and(|p| p != old))?;
        thread::sleep(Duration::from_secs(2));
        self.evidence(case, &self.pid().ok_or("Updated app exited")?);
        if self.version()? != version {
            return Err(format!("Expected installed version {version}"));
        }
        checked(cmd("codesign", &["--verify", "--strict"]).arg(&self.copy))?;
        // `log show` writes its own command line, the predicate in it, into the log it reads: without
        // `process != "log"` it finds itself (measured on macOS 15.7.7).
        let logs = output(&mut cmd(
            "/usr/bin/log",
            &[
                "show",
                "--last",
                "5m",
                "--style",
                "compact",
                "--predicate",
                "eventMessage CONTAINS[c] \"prevented from modifying apps\" AND process != \"log\"",
            ],
        ))?;
        if logs
            .to_lowercase()
            .contains("prevented from modifying apps")
        {
            return Err("macOS blocked app replacement".into());
        }
        Ok(())
    }
    fn retry(&self, url: &str, record_notes: impl FnOnce(R) -> R) -> R {
        self.quit()?;
        let pid = self.launch("retry-after-failure", Some(url))?;
        self.offer(&pid)?;
        self.evidence("offer", &pid);
        let text = self.text(&pid);
        let notes_present = [
            "PROBE-NEWEST",
            "PROBE-SKIPPED",
            "never installed, wrapped onto a second line",
        ]
        .iter()
        .all(|s| text.contains(s))
            && !text.contains("PROBE-INSTALLED")
            && !text.to_lowercase().contains("automatically download");
        record_notes(if notes_present {
            Ok(())
        } else {
            Err("Update notes or controls differ from the expected offer".into())
        })?;
        self.press(&pid, "Install Update")?;
        self.relaunch("retry-after-failure", &pid, "0.9.2")
    }
    fn published(&self, version: &str) -> R {
        self.fresh()?;
        let pid = self.launch("published", None)?;
        let offer = regex(&format!("{} is (now )?available", regex::escape(version)))?;
        wait(90, || self.has(&pid, &offer))?;
        self.evidence("offer", &pid);
        self.press(&pid, "Install Update")
            .or_else(|_| self.press(&pid, "Download"))?;
        self.relaunch("published", &pid, version)
    }
    // The copy sits in a folder this account cannot write to, as when another administrator installed
    // it: Sparkle asks for an administrator's password, right after the download (measured on macOS 15.7.7).
    fn read_only(&mut self, url: &str) -> R {
        self.quit()?;
        let original = std::mem::replace(&mut self.copy, self.home.join("ReadOnly/AgentWatch.app"));
        let parent = self.copy.parent().unwrap().to_owned();
        self.fresh()?;
        let permissions = io(fs::metadata(&parent))?.permissions();
        checked(cmd("chmod", &["555"]).arg(&parent))?;
        let test = (|| {
            let pid = self.launch("no-write-access", Some(url))?;
            self.offer(&pid)?;
            self.press(&pid, "Install Update")?;
            let form = regex("wants permission to update")?;
            let mut agent = String::new();
            wait(60, || {
                agent = output(&mut cmd("pgrep", &["-x", "SecurityAgent"]))
                    .unwrap_or_default()
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_owned();
                !agent.is_empty() && self.has(&agent, &form)
            })?;
            self.evidence("no-write-access", &agent);
            self.press(&agent, "Cancel")?;
            thread::sleep(Duration::from_secs(5));
            if self.has(&pid, &regex("Install Update|Install and Relaunch|error")?) {
                self.evidence("no-write-access-after", &pid);
                return Err("Update window remained open after Cancel".into());
            }
            self.intact(&pid)
        })();
        let restore = fs::set_permissions(parent, permissions);
        let quit = self.quit();
        self.copy = original;
        io(restore)?;
        quit?;
        test
    }
}

fn regex(pattern: &str) -> R<Regex> {
    Regex::new(&format!("(?i){pattern}")).map_err(|e| e.to_string())
}
fn wait(seconds: u64, mut predicate: impl FnMut() -> bool) -> R {
    let end = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < end {
        if predicate() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(500));
    }
    Err(format!("Timed out after {seconds} seconds"))
}
pub(super) fn run(args: &[String]) -> R {
    if output(&mut cmd("sysctl", &["-n", "kern.hv_vmm_present"]))? != "1" {
        return Err("Run update-guest only inside the disposable macOS guest".into());
    }
    let share = PathBuf::from("/Volumes/My Shared Files/aw");
    if !share.join("old.zip").is_file() {
        return Err("Missing mounted update fixture".into());
    }
    let home = PathBuf::from(env::var_os("HOME").ok_or("HOME is missing")?);
    let ax = home.join("ax");
    io(fs::copy(share.join("ax"), &ax))?;
    let out = share.join("out");
    mkdir(&out)?;
    let mut suite = Suite {
        share,
        out: out.clone(),
        home,
        copy: PathBuf::from("/Applications/AgentWatch.app"),
        ax,
    };
    let mut report = io(fs::File::create(out.join("result.txt")))?;
    let mut failed = false;
    let mut record = |case: &str, status: R| -> R {
        if let Err(error) = status {
            failed = true;
            io(writeln!(report, "{case} FAILED — {error}"))?;
        } else {
            io(writeln!(report, "{case} passed"))?;
        }
        io(report.flush())
    };
    let url = |name: &str| format!("http://127.0.0.1:8123/feed/{name}.xml");
    match args {
        [command, v] if command == "published" => record("published", suite.published(v))?,
        [] => {
            super::server::start(suite.share.join("serve"))?;
            for (name, url) in [
                ("feed-broken", url("broken")),
                (
                    "feed-unreachable",
                    "http://127.0.0.1:9/appcast.xml".to_owned(),
                ),
            ] {
                record(name, suite.quiet_failure(name, &url))?;
            }
            for (name, feed, timeout) in [
                ("download-error", "error", 30),
                ("download-dropped", "drop", 30),
                ("download-stalled", "stall", 120),
                ("bad-signature", "badsig", 30),
            ] {
                record(name, suite.failed_download(name, &url(feed), timeout))?;
            }
            let installation = suite.retry(&url("good"), |notes| record("changes-listed", notes));
            record("retry-after-failure", installation)?;
            record("no-write-access", suite.read_only(&url("good")))?;
        }
        _ => return Err("Usage: update-guest [published VERSION]".into()),
    }
    suite.quit()?;
    if failed {
        Err("One or more update scenarios failed".into())
    } else {
        Ok(())
    }
}
