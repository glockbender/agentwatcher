use crate::{
    Client,
    execution::{Env, executable, isolated, output, wait},
    fixture::Fixture,
    model::{Model, Plan},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

pub(crate) struct Profiles {
    pub env: Env,
    pub claude: PathBuf,
    pub codex: PathBuf,
    pub repo: PathBuf,
    pub home: PathBuf,
}

impl Profiles {
    pub fn new(f: &Fixture, clients: &[Client]) -> Result<Self> {
        let home = f.home();
        let mut env = f.env.clone();
        for (k, v) in [
            ("SHELL", "/bin/bash"),
            ("TERM", "xterm-256color"),
            ("LANG", "en_US.UTF-8"),
            ("ANTHROPIC_API_KEY", "fixture-only"),
            ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
            ("DISABLE_AUTOUPDATER", "1"),
        ] {
            env.insert(k.into(), v.into());
        }
        for (k, sub) in [("CLAUDE_CONFIG_DIR", ".claude"), ("CODEX_HOME", ".codex")] {
            let path = home.join(sub);
            fs::create_dir(&path)?;
            env.insert(k.into(), path.into());
        }
        let binary = |which: Client, name: &str, key: &str| -> Result<PathBuf> {
            if !clients.contains(&which) {
                return Ok(PathBuf::new());
            }
            if let Some(value) = std::env::var_os(key) {
                return Ok(std::path::absolute(value)?);
            }
            executable(name)
        };
        let profiles = Self {
            claude: binary(Client::Claude, "claude", "CLAUDE_BIN")?,
            codex: binary(Client::Codex, "codex", "CODEX_BIN")?,
            env,
            home,
            repo: f.repo.clone(),
        };
        for c in clients {
            let exe = match c {
                Client::Codex => &profiles.codex,
                Client::Claude => &profiles.claude,
            };
            // macOS can verify a newly copied client before its first instruction runs.
            let version = output(profiles.cmd(exe).arg("--version"), Duration::from_secs(180))?;
            println!("{version}");
            if *c == Client::Claude {
                let config = json!({"hasCompletedOnboarding":true,"lastOnboardingVersion":version.split_whitespace().next(),
                    "theme":"dark","autoUpdates":false,"customApiKeyResponses":{"approved":["fixture-only"]},
                    "projects":{profiles.repo.to_string_lossy().as_ref():{"hasTrustDialogAccepted":true}}});
                fs::write(
                    profiles.home.join(".claude/.claude.json"),
                    serde_json::to_vec(&config)?,
                )?;
            }
        }
        Ok(profiles)
    }

    pub fn cmd(&self, exe: &Path) -> Command {
        isolated(exe, &self.repo, &self.env)
    }
    pub fn profile(&self, c: Client) -> PathBuf {
        self.home.join(match c {
            Client::Claude => ".claude",
            Client::Codex => ".codex",
        })
    }
}

pub(crate) struct Rpc {
    process: Child,
    input: Option<ChildStdin>,
    responses: Receiver<Result<Value, String>>,
    stderr: File,
    sequence: u32,
}

impl Rpc {
    pub fn start(p: &Profiles, experimental: bool) -> Result<Self> {
        let stderr = tempfile::tempfile()?;
        let mut process = p
            .cmd(&p.codex)
            .args(["app-server", "--stdio"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(stderr.try_clone()?)
            .spawn()?;
        let input = process.stdin.take();
        let stdout = process.stdout.take().context("Codex stdout missing")?;
        let (tx, responses) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let msg = line
                    .map_err(|e| e.to_string())
                    .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()));
                if tx.send(msg).is_err() {
                    break;
                }
            }
        });
        let mut rpc = Self {
            process,
            input,
            responses,
            stderr,
            sequence: 0,
        };
        let mut init = json!({"clientInfo":{"name":"agent-watch-probe","version":"1"}});
        if experimental {
            init["capabilities"] = json!({"experimentalApi":true});
        }
        rpc.call("initialize", init)?;
        rpc.send(json!({"method":"initialized"}))?;
        Ok(rpc)
    }

    fn send(&mut self, msg: Value) -> Result<()> {
        let dest = self.input.as_mut().context("Closed Codex connection")?;
        writeln!(dest, "{msg}")?;
        dest.flush()?;
        Ok(())
    }

    fn diagnostic(&mut self) -> String {
        let mut tail = String::new();
        if let Ok(meta) = self.stderr.metadata() {
            let _ = self
                .stderr
                .seek(SeekFrom::Start(meta.len().saturating_sub(4096)));
            let _ = (&self.stderr).take(4096).read_to_string(&mut tail);
        }
        let lines = tail
            .lines()
            .filter(|line| {
                let lower = line.to_lowercase();
                ![
                    "authorization",
                    "bearer",
                    "api_key",
                    "secret",
                    "password",
                    "token",
                    "sk-",
                ]
                .iter()
                .any(|s| lower.contains(s))
            })
            .rev()
            .take(4)
            .collect::<Vec<_>>();
        lines
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join("\n")
            .chars()
            .take(900)
            .collect()
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        println!("Codex request: {method}");
        self.sequence += 1;
        let id = self.sequence;
        self.send(json!({"method":method,"id":id,"params":params}))?;
        let seconds = match method {
            "initialize" | "thread/start" | "turn/start" => 180,
            _ => 40,
        };
        let end = Instant::now() + Duration::from_secs(seconds);
        loop {
            match self
                .responses
                .recv_timeout(end.saturating_duration_since(Instant::now()))
            {
                Ok(Ok(row)) if row["id"] == id => {
                    ensure!(
                        row.get("error").is_none(),
                        "Codex {method}: {}",
                        row["error"]
                    );
                    return row
                        .get("result")
                        .cloned()
                        .with_context(|| format!("Codex {method} missing result"));
                }
                Ok(Ok(_)) => (),
                Ok(Err(err)) => bail!("Codex {method}: {err}"),
                Err(err) => bail!(
                    "Codex {method} response ({seconds}s deadline): {err}. {}",
                    self.diagnostic()
                ),
            }
        }
    }

    pub fn alive(&mut self) -> Result<()> {
        ensure!(
            self.process.try_wait()?.is_none(),
            "Codex app-server exited prematurely"
        );
        Ok(())
    }

    pub fn shutdown(mut self) -> Result<()> {
        self.input.take();
        let status = wait(&mut self.process, Duration::from_secs(15))?;
        ensure!(status.success(), "Codex app-server exited with {status}");
        Ok(())
    }
}

impl Drop for Rpc {
    fn drop(&mut self) {
        self.input.take();
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

pub(crate) fn codex_config(url: &str) -> String {
    format!(
        "model_provider = \"fixture\"\nmodel = \"gpt-5.4\"\n[model_providers.fixture]\nname = \"Local fixture\"\nbase_url = \"{url}/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = false\nsupports_websockets = false\n[analytics]\nenabled = false\n"
    )
}

const CLAUDE_FLAGS: &[&str] = &[
    "--setting-sources",
    "user",
    "--strict-mcp-config",
    "--tools",
    "Bash",
    "--allowedTools",
    "Bash",
    "--permission-mode",
    "dontAsk",
];

fn attached_chat(output: &str) -> Result<String> {
    let (_, tail) = output
        .split_once("claude attach ")
        .context("Claude did not report the chat ID")?;
    let length = tail
        .bytes()
        .take_while(|c| c.is_ascii_hexdigit() || *c == b'-')
        .count();
    let id = &tail[..length];
    ensure!(
        id.as_bytes().first().is_some_and(u8::is_ascii_hexdigit)
            && id.as_bytes().last().is_some_and(u8::is_ascii_hexdigit),
        "Invalid Claude chat ID"
    );
    Ok(id.to_owned())
}

struct ClaudeChats<'a> {
    profiles: &'a Profiles,
    url: String,
    active: Option<String>,
    witness: Option<String>,
    starting: bool,
}
impl ClaudeChats<'_> {
    fn call(&self, args: &[&str]) -> Result<String> {
        output(
            self.profiles
                .cmd(&self.profiles.claude)
                .env("ANTHROPIC_BASE_URL", &self.url)
                .args(args),
            Duration::from_secs(if args.first() == Some(&"--bg") {
                180
            } else {
                60
            }),
        )
    }
    fn start(&mut self, msg: &str) -> Result<String> {
        self.starting = true;
        let args = [&["--bg"][..], CLAUDE_FLAGS, &["--", msg]].concat();
        let raw = self.call(&args)?;
        let id = attached_chat(&raw)?;
        self.starting = false;
        Ok(id)
    }
    fn listed(&self) -> Result<Vec<String>> {
        let repo = self
            .profiles
            .repo
            .to_str()
            .context("Expected UTF-8 fixture path")?;
        let rows: Value = serde_json::from_str(&self.call(&["agents", "--json", "--cwd", repo])?)?;
        Ok(rows
            .as_array()
            .context("Invalid Claude agent list")?
            .iter()
            .filter(|row| row["cwd"] == repo)
            .filter_map(|row| row["id"].as_str().map(str::to_owned))
            .collect())
    }
    fn registered(&self, id: &str) -> Result<bool> {
        Ok(self.listed()?.iter().any(|active| active == id))
    }
    fn stop_target(&mut self) -> Result<()> {
        let id = self.active.as_ref().context("No active Claude chat")?;
        let result = self.call(&["stop", id])?;
        ensure!(
            result.to_lowercase().contains(&format!("stopped {id}")),
            "Claude did not acknowledge stop: {result}"
        );
        let end = Instant::now() + Duration::from_secs(10);
        while self.registered(id)? {
            ensure!(Instant::now() < end, "Stopped Claude chat remains active");
            std::thread::sleep(Duration::from_millis(150));
        }
        self.active = None;
        self.check_witness()
    }
    fn check_witness(&self) -> Result<()> {
        ensure!(
            self.registered(self.witness.as_ref().context("Missing witness chat")?)?,
            "Claude's control chat stopped"
        );
        Ok(())
    }
    fn finish(&mut self) -> Result<()> {
        // Always try both IDs if the first cleanup fails.
        let mut errors = Vec::new();
        let mut ids = [self.active.take(), self.witness.take()]
            .into_iter()
            .flatten()
            .collect::<std::collections::BTreeSet<_>>();
        // A timed out --bg may have created a chat before reporting its identifier.
        if std::mem::take(&mut self.starting) {
            match self.listed() {
                Ok(created) => ids.extend(created),
                Err(err) => errors.push(format!("Listing the isolated profile: {err:#}")),
            }
        }
        for id in ids {
            if let Err(err) = self.call(&["stop", &id]) {
                errors.push(format!("{id}: {err:#}"));
            }
        }
        ensure!(errors.is_empty(), "Claude cleanup: {}", errors.join(", "));
        Ok(())
    }
}
impl Drop for ClaudeChats<'_> {
    fn drop(&mut self) {
        if let Err(e) = self.finish() {
            eprintln!("{e:#}");
        }
    }
}

enum Session<'a> {
    Claude(ClaudeChats<'a>),
    Codex { rpc: Rpc, id: String },
}
pub(crate) struct Chat<'a> {
    session: Session<'a>,
    model: Model,
}

impl<'a> Chat<'a> {
    pub fn start(profiles: &'a Profiles, client: Client, cmd: String) -> Result<Self> {
        let prompt = "Run the fixture command once.";
        let model = Model::start(
            client,
            Plan {
                command: cmd,
                prompt: prompt.into(),
                follow: None,
            },
        )?;
        let session = match client {
            Client::Claude => {
                let mut chats = ClaudeChats {
                    profiles,
                    url: model.url.clone(),
                    active: None,
                    witness: None,
                    starting: false,
                };
                chats.witness = Some(chats.start("Keep this control conversation open.")?);
                chats.active = Some(chats.start(prompt)?);
                ensure!(
                    chats.registered(chats.active.as_ref().unwrap())?,
                    "Claude chat not registered"
                );
                Session::Claude(chats)
            }
            Client::Codex => {
                fs::write(
                    profiles.profile(client).join("config.toml"),
                    codex_config(&model.url),
                )?;
                let mut rpc = Rpc::start(profiles, false)?;
                let thread = rpc.call(
                    "thread/start",
                    json!({"modelProvider":"fixture","model":"gpt-5.4","cwd":profiles.repo,
                    "approvalPolicy":"never","sandbox":"danger-full-access"}),
                )?;
                let id = thread["thread"]["id"]
                    .as_str()
                    .context("Missing Codex chat ID")?
                    .to_owned();
                rpc.call(
                    "turn/start",
                    json!({"threadId":id,"input":[{"type":"text","text":prompt}]}),
                )?;
                Session::Codex { rpc, id }
            }
        };
        Ok(Self { session, model })
    }
    pub fn close(&mut self) -> Result<()> {
        self.model.check()?;
        ensure!(self.model.issued(), "No fixture tool call was issued");
        match &mut self.session {
            Session::Claude(chats) => chats.stop_target()?,
            Session::Codex { rpc, id } => {
                rpc.call("thread/archive", json!({"threadId":id}))?;
                let listing = rpc.call(
                    "thread/list",
                    json!({"archived":true,"modelProviders":["fixture"],"limit":100}),
                )?;
                ensure!(
                    listing["data"]
                        .as_array()
                        .context("Invalid Codex thread list")?
                        .iter()
                        .any(|t| t["id"].as_str() == Some(id.as_str())),
                    "Codex did not list the archived chat"
                );
            }
        }
        println!("Client acknowledged closing the target chat.");
        self.alive()
    }
    pub fn alive(&mut self) -> Result<()> {
        self.model.check()?;
        if let Session::Codex { rpc, .. } = &mut self.session {
            rpc.alive()?;
        }
        Ok(())
    }
    pub fn finish(&mut self) -> Result<()> {
        if let Session::Claude(chats) = &mut self.session {
            chats.check_witness()?;
            chats.finish()?;
        }
        self.alive()
    }
}

pub(crate) fn foreground(
    p: &Profiles,
    c: Client,
    model: &Model,
    prompt: &str,
    log: &Path,
) -> Result<Child> {
    let mut cmd = match c {
        Client::Claude => {
            let mut cmd = p.cmd(&p.claude);
            cmd.env("ANTHROPIC_BASE_URL", &model.url)
                .arg("-p")
                .args(CLAUDE_FLAGS)
                .args(["--", prompt]);
            cmd
        }
        Client::Codex => {
            let mut cmd = p.cmd(&p.codex);
            cmd.arg("exec");
            for line in [
                "model_provider=\"fixture\"",
                "model=\"gpt-5.4\"",
                "model_providers.fixture.name=\"Fixture\"",
                &format!("model_providers.fixture.base_url=\"{}/v1\"", model.url),
                "model_providers.fixture.wire_api=\"responses\"",
                "model_providers.fixture.requires_openai_auth=false",
                "model_providers.fixture.supports_websockets=false",
            ] {
                cmd.args(["-c", line]);
            }
            cmd.args(["-s", "danger-full-access", prompt]);
            cmd
        }
    };
    let log = File::create(log)?;
    Ok(cmd.stdout(log.try_clone()?).stderr(log).spawn()?)
}

#[cfg(test)]
mod tests {
    use super::attached_chat;
    #[test]
    fn parses_the_attach_command_with_short_and_full_ids() {
        for id in ["3dbccb74", "152c2aa5-be30-4c6c-95b7-8d57cba62e6f"] {
            let output = format!("Background session.\n  claude attach {id}\x1b[0m\n");
            assert_eq!(attached_chat(&output).unwrap(), id);
        }
        assert!(attached_chat("claude attach --help").is_err());
    }
}
