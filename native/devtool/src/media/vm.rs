//! Operate the README recording machine. The guest runs the same prebuilt devtool as the host.
mod stand;
use std::{
    env, fs,
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

type R<T = ()> = Result<T, String>;
const STAND: &str = "aw-stand";
const TAKE: &str = "aw-take";
const REPO: &str = "/Users/admin/CommonProjects/agent-watch";
const WORK: &str = "/Users/admin/Library/Caches/agent-watch-media";
const SHARE: &str = "/Volumes/My Shared Files/aw";
const TOOL: &str = "/Users/admin/.local/bin/agent-watch-devtool";
const USAGE: &str = "media vm stand | grant | up [bare] | sync | shoot [step] | run <take> | fetch [take ...] | down | sh <command>";
const STEPS: &[&str] = &[
    "setup",
    "stage",
    "start",
    "menu",
    "order",
    "rows",
    "look",
    "folders",
    "fullscreen",
    "icon",
    "counts",
];

fn io<T>(r: std::io::Result<T>) -> R<T> {
    r.map_err(|e| e.to_string())
}
fn command(name: &str, args: &[&str]) -> Command {
    let mut c = Command::new(name);
    c.args(args);
    c
}
fn check(c: &mut Command) -> R {
    let name = c.get_program().to_string_lossy().into_owned();
    let status = io(c.status())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{name}: {status}"))
    }
}
fn capture(c: &mut Command) -> R<String> {
    let o = io(c.output())?;
    if o.status.success() {
        String::from_utf8(o.stdout)
            .map(|s| s.trim_end().to_owned())
            .map_err(|e| e.to_string())
    } else {
        Err(format!(
            "{}: {}",
            c.get_program().to_string_lossy(),
            String::from_utf8_lossy(&o.stderr).trim()
        ))
    }
}
fn silent(c: &mut Command) -> bool {
    c.stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}
fn guest(vm: &str, args: &[&str]) -> Command {
    let mut c = command("tart", &["exec", vm]);
    c.args(args);
    c
}
fn media(vm: &str, args: &[&str]) -> Command {
    let mut c = guest(
        vm,
        &[
            "env",
            "PATH=/Users/admin/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "AW_PREBUILT=1",
        ],
    );
    c.arg(format!("AW_MEDIA_REPO={REPO}"))
        .arg(format!("AW_DEVTOOL={TOOL}"))
        .arg(format!("AW_CLAUDE_HOOKS={WORK}/claude-hooks.json"))
        .args([TOOL, "media"])
        .args(args);
    c
}
fn stamp() -> String {
    format!(
        "{}-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
        std::process::id()
    )
}
fn running(vm: &str) -> bool {
    capture(&mut command("tart", &["get", vm, "--format", "json"]))
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .is_some_and(|v| v["Running"] == true || v["running"] == true)
}
fn exists(vm: &str) -> bool {
    silent(&mut command("tart", &["get", vm]))
}
fn wait(count: usize, mut f: impl FnMut() -> bool) -> R {
    for _ in 0..count {
        if f() {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(2))
    }
    Err("Timed out waiting for the recording machine".into())
}

struct Machine {
    home: PathBuf,
    work: PathBuf,
    share: PathBuf,
    vm: String,
}
impl Machine {
    fn new() -> R<Self> {
        let home = PathBuf::from(env::var_os("HOME").ok_or("HOME is missing")?);
        let work = home.join("Library/Caches/agent-watch-media");
        let share = work.join("vm-share");
        io(fs::create_dir_all(&share))?;
        Ok(Self {
            home,
            work,
            share,
            vm: env::var("AW_VM").unwrap_or_else(|_| TAKE.into()),
        })
    }
    fn boot(&self, vm: &str, window: bool) -> R {
        if !running(vm) {
            let log = io(fs::File::create(self.work.join(format!("{vm}.log"))))?;
            let mut c = command("tart", &["run"]);
            c.arg(format!("--dir=aw:{}", self.share.display()));
            if !window {
                c.arg("--no-graphics");
            }
            use std::os::unix::process::CommandExt;
            io(c.arg(vm)
                .process_group(0)
                .stdin(Stdio::null())
                .stdout(io(log.try_clone())?)
                .stderr(log)
                .spawn())?;
        }
        wait(90, || silent(&mut guest(vm, &["pgrep", "-x", "Dock"])))?;
        thread::sleep(Duration::from_secs(5));
        Ok(())
    }
    fn tool(&self, vm: &str) -> R {
        let file = format!("devtool-{}", stamp());
        let copy = self.share.join(&file);
        io(fs::copy(io(env::current_exe())?, &copy))?;
        check(&mut guest(vm, &["mkdir", "-p", "/Users/admin/.local/bin"]))?;
        check(&mut guest(
            vm,
            &["cp", &format!("{SHARE}/{file}"), &format!("{TOOL}.new")],
        ))?;
        check(&mut guest(vm, &["mv", &format!("{TOOL}.new"), TOOL]))?;
        io(fs::remove_file(copy))
    }
    fn checkout(&self, vm: &str) -> R {
        self.tool(vm)?;
        let branch = capture(&mut command("git", &["symbolic-ref", "--short", "HEAD"]))?;
        let bundle = self.share.join("repo.bundle");
        check(
            command("git", &["bundle", "create", "-q"])
                .arg(&bundle)
                .arg(&branch),
        )?;
        let diff = self.share.join("repo.diff");
        check(command("git", &["diff", "HEAD", "--binary"]).stdout(io(fs::File::create(diff))?))?;
        let others = self.share.join("untracked");
        check(
            command("git", &["ls-files", "--others", "--exclude-standard", "-z"])
                .stdout(io(fs::File::create(&others))?),
        )?;
        check(
            command("tar", &["-cf"])
                .arg(self.share.join("untracked.tar"))
                .arg("--null")
                .arg("-T")
                .arg(others),
        )?;
        if silent(&mut guest(vm, &["test", "-e", REPO])) {
            check(&mut guest(vm, &["trash", REPO]))?
        }
        check(&mut guest(
            vm,
            &["mkdir", "-p", "/Users/admin/CommonProjects"],
        ))?;
        check(&mut guest(
            vm,
            &[
                "git",
                "clone",
                "-q",
                "-b",
                &branch,
                &format!("{SHARE}/repo.bundle"),
                REPO,
            ],
        ))?;
        check(&mut guest(
            vm,
            &["git", "-C", REPO, "checkout", "-q", "-B", "main"],
        ))?;
        if io(fs::metadata(self.share.join("repo.diff")))?.len() > 0 {
            check(&mut guest(
                vm,
                &["git", "-C", REPO, "apply", &format!("{SHARE}/repo.diff")],
            ))?
        }
        check(&mut guest(
            vm,
            &["tar", "-C", REPO, "-xf", &format!("{SHARE}/untracked.tar")],
        ))
    }
    fn sync(&self) -> R {
        self.tool(&self.vm)?;
        let name = format!("skill-{}.tar", stamp());
        let archive = self.share.join(&name);
        check(
            command("tar", &["-cf"])
                .arg(&archive)
                .arg(".claude/skills/readme-media"),
        )?;
        check(&mut guest(
            &self.vm,
            &["tar", "-C", REPO, "-xf", &format!("{SHARE}/{name}")],
        ))?;
        io(fs::remove_file(archive))
    }
    fn screen(&self, vm: &str) -> R {
        check(&mut media(vm, &["aw", "display", "1152", "720"]))?;
        let size = capture(&mut media(vm, &["aw", "screen"]))?;
        if size.split_whitespace().skip(2).take(2).eq(["1152", "720"]) {
            Ok(())
        } else {
            Err(format!("Unexpected screen: {size}"))
        }
    }
    fn app(&self, vm: &str) -> R {
        let bundle = self.work.join("build/AgentWatch.app");
        let zip = self.share.join("AgentWatch.zip");
        let log = io(fs::File::create(self.work.join("vm-build.log")))?;
        check(
            Command::new(io(env::current_exe())?)
                .env("AGENT_WATCH_FLAVOR", "production")
                .args(["build-app", "debug"])
                .arg(&bundle)
                .stdout(io(log.try_clone())?)
                .stderr(log),
        )?;
        check(
            command("ditto", &["-c", "-k", "--keepParent"])
                .arg(bundle)
                .arg(zip),
        )?;
        io(fs::copy(
            self.home
                .join(".claude/skills/agent-watch/hooks/hooks.json"),
            self.share.join("claude-hooks.json"),
        ))?;
        check(&mut guest(vm, &["mkdir", "-p", WORK]))?;
        let old = format!("{WORK}/AgentWatch.app");
        if silent(&mut guest(vm, &["test", "-e", &old])) {
            check(&mut guest(vm, &["trash", &old]))?
        }
        check(&mut guest(
            vm,
            &[
                "ditto",
                "-x",
                "-k",
                &format!("{SHARE}/AgentWatch.zip"),
                WORK,
            ],
        ))?;
        check(&mut guest(
            vm,
            &["cp", &format!("{SHARE}/claude-hooks.json"), WORK],
        ))
    }
    fn up(&self, bare: bool) -> R {
        if exists(TAKE) {
            return Err(format!("{TAKE} already exists; use vm down first"));
        }
        if running(STAND) {
            return Err(format!("Stop {STAND} before cloning it"));
        }
        check(&mut command("tart", &["clone", STAND, TAKE]))?;
        self.boot(TAKE, false)?;
        self.checkout(TAKE)?;
        self.screen(TAKE)?;
        self.app(TAKE)?;
        stand::token(TAKE)?;
        stand::quit_ghostty(TAKE)?;
        if !bare {
            check(&mut media(TAKE, &["stage", "up"]))?
        }
        Ok(())
    }
    fn down(&self) -> R {
        if running(TAKE) {
            let _ = check(&mut media(TAKE, &["stage", "down"]));
            check(&mut command("tart", &["stop", TAKE]))?;
        }
        if exists(TAKE) {
            check(&mut command("tart", &["delete", TAKE]))?
        }
        Ok(())
    }
    fn fetch(&self, requested: &[&str]) -> R {
        let id = format!("fetch-{}", stamp());
        let local = self.share.join(&id);
        let remote = format!("{SHARE}/{id}");
        io(fs::create_dir(&local))?;
        check(&mut guest(
            &self.vm,
            &[
                "find",
                WORK,
                "-maxdepth",
                "1",
                "-type",
                "f",
                "-name",
                "*.marks",
                "-exec",
                "cp",
                "{}",
                &remote,
                ";",
            ],
        ))?;
        let mut takes = Vec::new();
        for f in io(fs::read_dir(&local))? {
            let path = io(f)?.path();
            let name = path
                .file_stem()
                .and_then(|n| n.to_str())
                .ok_or("Invalid take name")?;
            let marks = io(fs::read(&path))?;
            if requested.contains(&name)
                || requested.is_empty()
                    && fs::read(self.work.join(path.file_name().unwrap()))
                        .ok()
                        .as_ref()
                        != Some(&marks)
                    && !marks.split(|&b| b == b'\n').any(|l| l == b"failed")
            {
                takes.push(name.to_owned())
            }
        }
        if let Some(missing) = requested.iter().find(|n| !takes.iter().any(|t| t == **n)) {
            return Err(format!("Missing marks for {missing}"));
        }
        for n in &takes {
            check(&mut guest(
                &self.vm,
                &["cp", &format!("{WORK}/{n}.mov"), &remote],
            ))?;
            io(fs::rename(
                local.join(format!("{n}.mov")),
                self.work.join(format!("{n}.mov")),
            ))?;
            io(fs::copy(
                local.join(format!("{n}.marks")),
                self.work.join(format!("{n}.marks")),
            ))?;
        }
        super::discard(&local, &self.home)?;
        println!("Fetched: {}", takes.join(", "));
        Ok(())
    }
}
fn take_args<'a>(name: &'a str, extra: &'a [&'a str]) -> R<Vec<&'a str>> {
    let name = name.strip_prefix("./").unwrap_or(name);
    if matches!(name, "stage.sh" | "stage" | "aw-media") {
        let mut args = vec![if name == "aw-media" { "aw" } else { "stage" }];
        args.extend_from_slice(extra);
        return Ok(args);
    }
    let name = name.strip_prefix("takes/").unwrap_or(name);
    let name = name.strip_suffix(".sh").unwrap_or(name);
    if !STEPS.contains(&name) || name == "stage" || name == "counts" {
        return Err(format!("Unknown take: {name}"));
    }
    let mut args = vec!["take", name];
    args.extend_from_slice(extra);
    Ok(args)
}

pub(super) fn run(args: &[String]) -> R {
    let a: Vec<_> = args.iter().map(String::as_str).collect();
    if matches!(a.as_slice(), ["--help"] | ["-h"]) {
        println!("{USAGE}");
        return Ok(());
    }
    if let ["configure-guest", rest @ ..] = a.as_slice() {
        return stand::configure_guest(rest);
    }
    let m = Machine::new()?;
    match a.as_slice() {
        ["stand"] => stand::prepare(&m),
        ["grant"] => stand::grant(&m),
        ["up"] => m.up(false),
        ["up", "bare"] => m.up(true),
        ["sync"] => m.sync(),
        ["down"] => m.down(),
        ["fetch", rest @ ..] => m.fetch(rest),
        ["sh", rest @ ..] if !rest.is_empty() => {
            check(&mut guest(&m.vm, &["zsh", "-lc", &rest.join(" ")]))
        }
        ["run", name, rest @ ..] => check(&mut media(&m.vm, &take_args(name, rest)?)),
        ["shoot", rest @ ..] if rest.len() <= 1 => {
            let from = rest.first().copied().unwrap_or("setup");
            let start = STEPS
                .iter()
                .position(|s| *s == from)
                .ok_or_else(|| format!("Unknown step: {from}"))?;
            for &step in &STEPS[start..] {
                println!("Recording {step}");
                if step == "stage" {
                    check(&mut media(&m.vm, &["stage", "down"]))?;
                    check(&mut media(&m.vm, &["stage", "up"]))?;
                    continue;
                }
                if ["order", "rows", "look", "folders", "fullscreen"].contains(&step) {
                    check(&mut media(&m.vm, &["stage", "reset-settings"]))?
                }
                let args = if step == "counts" {
                    vec!["take", "icon", "counts"]
                } else {
                    take_args(step, &[])?
                };
                check(&mut media(&m.vm, &args))?;
            }
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::take_args;

    #[test]
    fn guest_commands_accept_the_existing_skill_paths() {
        assert_eq!(
            take_args("stage.sh", &["reset-settings"]).unwrap(),
            ["stage", "reset-settings"]
        );
        assert_eq!(
            take_args("./takes/icon.sh", &["counts"]).unwrap(),
            ["take", "icon", "counts"]
        );
        assert_eq!(
            take_args("aw-media", &["screen"]).unwrap(),
            ["aw", "screen"]
        );
    }
}
