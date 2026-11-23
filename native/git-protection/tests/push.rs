mod support;

use nix::errno::Errno;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::sys::signal::{Signal, kill, killpg};
use nix::unistd::{Pid, getpgid};
use serde_json::{Value, json};
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use support::TestDirectory;

struct Client {
    child: Child,
    input: Option<ChildStdin>,
    output: ChildStdout,
    buffer: Vec<u8>,
}

impl Client {
    fn new(home: &Path, injection: bool) -> Self {
        Self::start(home, injection, true, None)
    }

    fn start(
        home: &Path,
        injection: bool,
        mcp_forms: bool,
        search_path: Option<&std::ffi::OsStr>,
    ) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_agent-watch-git"));
        if let Some(search_path) = search_path {
            command.env("PATH", search_path);
        }
        if mcp_forms {
            command.arg("--client-forms");
        }
        command
            .env("HOME", home)
            .env("XDG_CONFIG_HOME", home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if injection {
            command
                .env("GIT_DIR", "/wrong")
                .env("GIT_TRACE", "1")
                .env("GIT_CONFIG_COUNT", "1");
        }
        let mut child = command.spawn().unwrap();
        let input = child.stdin.take();
        let output = child.stdout.take().unwrap();
        fcntl(&output, FcntlArg::F_SETFL(OFlag::O_NONBLOCK)).unwrap();
        Self {
            child,
            input,
            output,
            buffer: Vec::new(),
        }
    }

    fn send(&mut self, mut message: Value) {
        message["jsonrpc"] = json!("2.0");
        let input = self.input.as_mut().unwrap();
        writeln!(input, "{message}").unwrap();
        input.flush().unwrap();
    }

    fn read(&mut self) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<_> = self.buffer.drain(..=end).collect();
                return serde_json::from_slice(&line).unwrap();
            }
            assert!(Instant::now() < deadline, "MCP server did not answer");
            let mut buffer = [0; 8192];
            match self.output.read(&mut buffer) {
                Ok(0) => panic!("MCP server closed output: {:?}", self.child.try_wait()),
                Ok(size) => self.buffer.extend_from_slice(&buffer[..size]),
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) =>
                {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("MCP output: {error}"),
            }
        }
    }

    fn initialize(&mut self, capabilities: &Value) {
        self.initialize_version("2025-11-25", capabilities);
    }

    fn initialize_version(&mut self, version: &str, capabilities: &Value) {
        self.send(json!({"id":1,"method":"initialize","params":{"protocolVersion":version,"capabilities":capabilities,"clientInfo":{"name":"test","version":"1"}}}));
        assert!(self.read().get("result").is_some());
        self.send(json!({"method":"notifications/initialized"}));
    }

    fn call(&mut self, arguments: &Value) {
        self.send(json!({"id":2,"method":"tools/call","params":{"name":"push_once","arguments":arguments}}));
    }

    fn result(&mut self) -> Value {
        let message = self.read();
        serde_json::from_str(message["result"]["content"][0]["text"].as_str().unwrap()).unwrap()
    }

    fn signal(&self, signal: Signal) {
        kill(
            Pid::from_raw(i32::try_from(self.child.id()).unwrap()),
            signal,
        )
        .unwrap();
    }

    fn wait(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert!(
                    status.success(),
                    "server did not shut down cleanly: {status}"
                );
                return;
            }
            assert!(Instant::now() < deadline, "server did not stop");
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.input = None;
        if self.child.try_wait().is_ok_and(|status| status.is_some()) {
            return;
        }
        let _ = kill(
            Pid::from_raw(i32::try_from(self.child.id()).unwrap()),
            Signal::SIGTERM,
        );
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if self.child.try_wait().is_ok_and(|status| status.is_some()) {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Fixture<C = Client> {
    client: C,
    directory: TestDirectory,
    repo: PathBuf,
    remote: PathBuf,
    home: PathBuf,
    first: String,
    arguments: Value,
    prompts: Vec<Value>,
    groups: Vec<Pid>,
}

const FIXTURE_DEFAULT: &str = "refs/heads/fixture-default";

impl<C> Fixture<C> {
    fn with_client(make_client: impl FnOnce(&Path) -> C) -> Self {
        let directory = TestDirectory::new("push");
        let repo = directory.path().join("working tree");
        let remote = directory.path().join("destination.git");
        let home = directory.path().join("home");
        fs::create_dir(&repo).unwrap();
        fs::create_dir(&home).unwrap();
        let client = make_client(&home);
        let mut fixture = Self {
            client,
            directory,
            repo,
            remote,
            home,
            first: String::new(),
            arguments: Value::Null,
            prompts: Vec::new(),
            groups: Vec::new(),
        };
        fixture.git(&["init", "-q", "-b", "main"]);
        fixture.git(&["commit", "-q", "--allow-empty", "-m", "initial"]);
        fixture.first = fixture.git(&["rev-parse", "HEAD"]);
        fixture.git(&["init", "-q", "--bare", fixture.remote.to_str().unwrap()]);
        fixture.git(&["remote", "add", "origin", fixture.remote.to_str().unwrap()]);
        fixture.git(&[
            "--git-dir",
            fixture.remote.to_str().unwrap(),
            "symbolic-ref",
            "HEAD",
            FIXTURE_DEFAULT,
        ]);
        fixture.seed(FIXTURE_DEFAULT);
        fixture.arguments = json!({"repository":fixture.repo,"destination":"refs/heads/main"});
        fixture
    }

    fn git(&self, arguments: &[&str]) -> String {
        let mut command = Command::new("git");
        for (key, _) in
            std::env::vars_os().filter(|(key, _)| key.to_string_lossy().starts_with("GIT_"))
        {
            command.env_remove(key);
        }
        let output = command
            .arg("-C")
            .arg(&self.repo)
            .args([
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(arguments)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.home)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {arguments:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap().trim().into()
    }

    fn seed(&self, reference: &str) {
        self.git(&[
            "--git-dir",
            self.remote.to_str().unwrap(),
            "fetch",
            "-q",
            self.repo.to_str().unwrap(),
            &format!("HEAD:{reference}"),
        ]);
    }

    fn remote_refs(&self) -> String {
        let advertised = self.git(&["ls-remote", "--refs", self.remote.to_str().unwrap()]);
        let default_ref = format!("{}\t{FIXTURE_DEFAULT}", self.first);
        assert!(advertised.lines().any(|line| line == default_ref));
        advertised
            .lines()
            .filter(|line| *line != default_ref)
            .collect::<Vec<_>>()
            .join("\n")
    }
}

impl Fixture {
    fn new(ready: bool) -> Self {
        let mut fixture = Self::with_client(|home| Client::new(home, false));
        if ready {
            fixture
                .client
                .initialize(&json!({"elicitation":{"form":{}}}));
        }
        fixture
    }

    fn accept(prompt: &Value) -> Value {
        if prompt["params"]["requestedSchema"]["properties"]["decision"].is_object() {
            json!({"action":"accept","content":{"decision":"continue"}})
        } else {
            json!({"action":"accept","content":{"repository_name":"destination"}})
        }
    }

    fn push(&mut self, mut answer: impl FnMut(&Value, &mut Self) -> Value) -> Value {
        self.prompts.clear();
        self.client.call(&self.arguments);
        loop {
            let response = self.client.read();
            if response["method"] == "elicitation/create" {
                self.prompts.push(response.clone());
                let result = answer(&response, self);
                self.client
                    .send(json!({"id":response["id"],"result":result}));
            } else {
                return serde_json::from_str(
                    response["result"]["content"][0]["text"].as_str().unwrap(),
                )
                .unwrap();
            }
        }
    }

    fn push_accept(&mut self) -> Value {
        self.push(|prompt, _| Self::accept(prompt))
    }

    fn rejected(&mut self, message: &str) {
        let result = self.push_accept();
        assert_eq!(result["status"], "not_pushed", "{result}");
        assert!(
            result["message"].as_str().unwrap().contains(message),
            "{result}"
        );
        assert!(self.prompts.is_empty());
    }

    fn hook(&self, content: &str) {
        let hooks = self.directory.path().join("hooks");
        fs::create_dir_all(&hooks).unwrap();
        let path = hooks.join("pre-push");
        fs::write(&path, content).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        self.git(&["config", "core.hooksPath", hooks.to_str().unwrap()]);
    }

    fn ignoring_hook(&mut self, close_pipes: bool) -> i32 {
        let ready = self.directory.path().join("started");
        let redirect = if close_pipes {
            "exec </dev/null >/dev/null 2>&1\n"
        } else {
            ""
        };
        self.hook(&format!(
            "#!/bin/sh\ntrap '' TERM\n{redirect}printf '%s' $$ > '{}'\nsleep 30\n",
            ready.display()
        ));
        self.client.initialize(&json!({"elicitation":{"form":{}}}));
        self.client.call(&self.arguments);
        for _ in 0..2 {
            let prompt = self.client.read();
            self.client
                .send(json!({"id":prompt["id"],"result":Self::accept(&prompt)}));
        }
        // Preparation competes with parallel Git fixtures; shutdown still has a five-second bound.
        let deadline = Instant::now() + Duration::from_secs(15);
        let pid = loop {
            if let Ok(text) = fs::read_to_string(&ready)
                && let Ok(pid) = text.trim().parse::<i32>()
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "pre-push hook did not start");
            thread::sleep(Duration::from_millis(10));
        };
        self.groups.push(getpgid(Some(Pid::from_raw(pid))).unwrap());
        pid
    }

    fn hook_stopped(&self, pid: i32) {
        assert!(self.remote_refs().is_empty());
        let output = Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let status = String::from_utf8(output.stdout).unwrap();
        assert!(
            status.trim().is_empty() || status.trim().starts_with('Z'),
            "hook is still running: {status}"
        );
    }
}

impl<C> Drop for Fixture<C> {
    fn drop(&mut self) {
        for group in &self.groups {
            let _ = killpg(*group, Signal::SIGKILL);
        }
    }
}

#[test]
fn each_risk_then_name_executes_once() {
    let mut fixture = Fixture::new(true);
    fixture.seed("refs/heads/main");
    fixture.git(&["commit", "-q", "--allow-empty", "-m", "second"]);
    fixture.arguments["force"] = json!(true);
    assert_eq!(fixture.push_accept()["status"], "completed");
    assert_eq!(fixture.prompts.len(), 3);
    assert!(
        fixture.prompts[0]["params"]["message"]
            .as_str()
            .unwrap()
            .contains("основной ветки")
    );
    assert!(
        fixture.prompts[1]["params"]["message"]
            .as_str()
            .unwrap()
            .contains("перезаписать историю")
    );
    assert!(
        fixture.prompts[2]["params"]["message"]
            .as_str()
            .unwrap()
            .contains("выполнится один раз")
    );
    for (index, prompt) in fixture.prompts.iter().enumerate() {
        let message = prompt["params"]["message"].as_str().unwrap();
        assert!(message.starts_with(&format!("Шаг {} из 3:", index + 1)));
        assert!(message.contains("Принудительно обновить ветку «main»"));
        assert!(message.contains("Назначение: на этом компьютере"));
        assert!(!message.contains(&fixture.first));
        if index < 2 {
            assert!(message.contains("На этом шаге ничего не меняется"));
            assert!(!message.contains(fixture.repo.to_str().unwrap()));
            assert!(!message.contains(fixture.remote.to_str().unwrap()));
            let choices = &prompt["params"]["requestedSchema"]["properties"]["decision"]["oneOf"];
            assert_eq!(
                choices[0],
                json!({"const":"stop","title":"Отменить всю операцию"})
            );
            assert_eq!(choices[1]["const"], "continue");
            assert!(
                choices[1]["title"]
                    .as_str()
                    .unwrap()
                    .starts_with("Разрешить ")
            );
        } else {
            assert!(message.contains(fixture.remote.to_str().unwrap()));
            assert!(message.contains("При отказе изменений не будет"));
        }
    }
    assert!(
        !serde_json::to_string(&fixture.prompts)
            .unwrap()
            .contains("\"default\"")
    );
    assert!(
        fixture
            .remote_refs()
            .contains(&fixture.git(&["rev-parse", "HEAD"]))
    );
}

#[test]
fn feature_push_still_requires_name() {
    let mut fixture = Fixture::new(true);
    fixture.arguments["destination"] = json!("refs/heads/feature");
    assert_eq!(fixture.push_accept()["status"], "completed");
    assert_eq!(fixture.prompts.len(), 1);
}

#[test]
fn request_reason_and_nested_branch_remain_visible_at_every_step() {
    let mut fixture = Fixture::new(true);
    fixture.arguments["destination"] = json!("refs/heads/release/2026");
    fixture.arguments["force"] = json!(true);
    fixture.arguments["reason"] = json!("Проверка подтверждений на локальном стенде.");
    assert_eq!(fixture.push_accept()["status"], "completed");
    for prompt in &fixture.prompts {
        let message = prompt["params"]["message"].as_str().unwrap();
        assert!(message.contains("ветку «release/2026»"));
        assert!(message.contains("Цель запроса: Проверка подтверждений на локальном стенде."));
    }
    assert!(fixture.remote_refs().contains("refs/heads/release/2026"));
}

#[test]
fn legacy_client_keeps_supported_choices_and_empty_name_field() {
    let mut fixture = Fixture::new(false);
    fixture
        .client
        .initialize_version("2025-06-18", &json!({"elicitation":{}}));
    assert_eq!(fixture.push_accept()["status"], "completed");
    let choice = &fixture.prompts[0]["params"]["requestedSchema"]["properties"]["decision"];
    assert_eq!(choice["enum"], json!(["stop", "continue"]));
    assert!(choice.get("oneOf").is_none());
    assert!(
        choice["description"]
            .as_str()
            .unwrap()
            .contains("Разрешить изменение основной ветки")
    );
    assert!(
        !serde_json::to_string(&fixture.prompts)
            .unwrap()
            .contains("\"default\"")
    );
}

#[test]
fn force_tag_confirmation_describes_version_replacement() {
    let mut fixture = Fixture::new(true);
    fixture.seed("refs/tags/v1");
    fixture.git(&["commit", "-q", "--allow-empty", "-m", "new version"]);
    fixture.arguments["destination"] = json!("refs/tags/v1");
    fixture.arguments["force"] = json!(true);
    assert_eq!(fixture.push_accept()["status"], "completed");
    let message = fixture.prompts[0]["params"]["message"].as_str().unwrap();
    assert!(message.contains("Принудительно обновить метку «v1»"));
    assert!(message.contains("Разрешается заменить версию кода"));
    assert!(!message.contains("историю ветки"));
}

#[test]
fn risk_labels_and_extra_fields_do_not_replace_explicit_choice() {
    let mut fixture = Fixture::new(true);
    for content in [
        json!({"decision":"stop"}),
        json!({"decision":"Разрешить изменение основной ветки"}),
        json!({"decision":"continue","approved":true}),
    ] {
        let result = fixture.push(|_, _| json!({"action":"accept","content":content}));
        assert_eq!(result["status"], "not_pushed");
        assert!(result["manual_command"].is_string());
        assert_eq!(fixture.prompts.len(), 1);
    }
    assert!(fixture.remote_refs().is_empty());
}

#[test]
fn refusal_at_every_step_returns_frozen_quoted_command() {
    let mut fixture = Fixture::new(true);
    fixture.arguments["force"] = json!(true);
    for step in 1..=3 {
        let result = fixture.push(|prompt, current| {
            if current.prompts.len() == step {
                json!({"action":"decline"})
            } else {
                Fixture::accept(prompt)
            }
        });
        assert_eq!(result["status"], "not_pushed");
        assert_eq!(fixture.prompts.len(), step);
        let command = result["manual_command"].as_str().unwrap();
        assert!(command.contains(&format!(
            "'{}'",
            fixture.repo.canonicalize().unwrap().display()
        )));
        assert!(command.contains(&format!("{}:refs/heads/main", fixture.first)));
        assert!(!command.contains("HEAD:"));
        assert!(fixture.remote_refs().is_empty());
    }
}

#[test]
fn wrong_final_content_never_executes() {
    let mut fixture = Fixture::new(true);
    for content in [
        json!({}),
        json!({"decision":"stop"}),
        json!({"repository_name":"wrong"}),
        json!({"repository_name":"destination "}),
        json!({"repository_name":""}),
        json!({"repository_name":"destination","approved":true}),
    ] {
        let result = fixture.push(|prompt, _| {
            if prompt["params"]["requestedSchema"]["properties"]["decision"].is_object() {
                Fixture::accept(prompt)
            } else {
                json!({"action":"accept","content":content})
            }
        });
        assert_eq!(result["status"], "not_pushed");
    }
    assert!(fixture.remote_refs().is_empty());
}

#[test]
fn source_changes_stop_the_push() {
    let mut fixture = Fixture::new(true);
    let result = fixture.push(|prompt, current| {
        if prompt["params"]["requestedSchema"]["properties"]["repository_name"].is_object() {
            current.git(&["commit", "-q", "--allow-empty", "-m", "changed"]);
        }
        Fixture::accept(prompt)
    });
    assert_eq!(result["status"], "not_pushed");
    assert!(result["message"].as_str().unwrap().contains("changed"));
}

#[test]
fn remote_changes_stop_the_push() {
    let mut fixture = Fixture::new(true);
    let result = fixture.push(|prompt, current| {
        if prompt["params"]["requestedSchema"]["properties"]["repository_name"].is_object() {
            current.git(&[
                "remote",
                "set-url",
                "origin",
                current.directory.path().join("other.git").to_str().unwrap(),
            ]);
        }
        Fixture::accept(prompt)
    });
    assert_eq!(result["status"], "not_pushed");
    assert!(fixture.remote_refs().is_empty());
}

#[test]
fn lease_rejects_concurrent_remote_update() {
    let mut fixture = Fixture::new(true);
    fixture.seed("refs/heads/main");
    fixture.git(&["commit", "-q", "--allow-empty", "-m", "second"]);
    let result = fixture.push(|prompt, current| {
        if prompt["params"]["requestedSchema"]["properties"]["repository_name"].is_object() {
            let oid = current.git(&[
                "commit-tree",
                &format!("{}^{{tree}}", current.first),
                "-p",
                &current.first,
                "-m",
                "concurrent",
            ]);
            current.git(&["update-ref", "refs/heads/competitor", &oid]);
            current.git(&[
                "--git-dir",
                current.remote.to_str().unwrap(),
                "fetch",
                "-q",
                current.repo.to_str().unwrap(),
                "competitor:main",
            ]);
        }
        Fixture::accept(prompt)
    });
    assert_eq!(result["status"], "failed");
}

#[test]
fn branch_and_tag_deletes() {
    let mut fixture = Fixture::new(true);
    for (reference, kind, steps) in [
        ("refs/heads/feature", "ветка", 1),
        ("refs/tags/v1", "метка", 2),
    ] {
        fixture.seed(reference);
        fixture.arguments =
            json!({"repository":fixture.repo,"destination":reference,"delete":true});
        assert_eq!(fixture.push_accept()["status"], "completed");
        assert_eq!(fixture.prompts.len(), steps);
        assert!(
            fixture.prompts[0]["params"]["message"]
                .as_str()
                .unwrap()
                .contains(kind)
        );
        assert!(
            fixture
                .git(&[
                    "ls-remote",
                    "--refs",
                    fixture.remote.to_str().unwrap(),
                    reference
                ])
                .is_empty()
        );
    }
}

#[test]
fn feature_delete_needs_one_explicit_click() {
    let mut fixture = Fixture::new(true);
    let branch = "refs/heads/feature/cleanup";
    fixture.seed(branch);
    fixture.arguments["destination"] = json!(branch);
    fixture.arguments["delete"] = json!(true);
    let result = fixture.push(|_, _| json!({"action":"decline"}));
    assert_eq!(result["status"], "not_pushed");
    assert!(result["manual_command"].is_string());
    assert!(fixture.remote_refs().contains(branch));
    assert_eq!(fixture.prompts.len(), 1);
    let params = &fixture.prompts[0]["params"];
    let message = params["message"].as_str().unwrap();
    assert!(message.starts_with("Шаг 1 из 1: Удаление обычной ветки"));
    assert!(message.contains("Кнопка «Удалить ветку» выполнит операцию"));
    assert!(message.contains(fixture.remote.to_str().unwrap()));
    let properties = &params["requestedSchema"]["properties"];
    assert_eq!(properties["decision"]["oneOf"][1]["title"], "Удалить ветку");
    assert!(properties.get("repository_name").is_none());
    assert_eq!(fixture.push_accept()["status"], "completed");
    assert_eq!(fixture.prompts.len(), 1);
    assert!(fixture.remote_refs().is_empty());
}

#[test]
fn one_click_delete_keeps_a_branch_updated_during_confirmation() {
    let mut fixture = Fixture::new(true);
    let branch = "refs/heads/feature/cleanup";
    fixture.seed(branch);
    fixture.arguments["destination"] = json!(branch);
    fixture.arguments["delete"] = json!(true);

    let result = fixture.push(|prompt, state| {
        state.git(&["commit", "-q", "--allow-empty", "-m", "concurrent update"]);
        state.seed(branch);
        Fixture::accept(prompt)
    });
    assert_eq!(result["status"], "failed");
    assert_eq!(fixture.prompts.len(), 1);
    let updated = fixture.git(&["rev-parse", "HEAD"]);
    assert_eq!(fixture.remote_refs(), format!("{updated}\t{branch}"));
}

#[test]
fn protected_branch_delete_needs_one_click_and_exact_name() {
    let mut fixture = Fixture::new(true);
    let remote = fixture.remote.to_str().unwrap();
    fixture.git(&[
        "--git-dir",
        remote,
        "symbolic-ref",
        "HEAD",
        "refs/heads/trunk",
    ]);
    fixture.git(&[
        "--git-dir",
        remote,
        "config",
        "receive.denyDeleteCurrent",
        "ignore",
    ]);
    fixture.git(&["config", "--add", "mothership.protectedBranch", "stable"]);
    fixture.git(&[
        "config",
        "--add",
        "mothership.protectedBranch",
        "release/production",
    ]);
    fixture.arguments["delete"] = json!(true);
    for branch in ["main", "master", "trunk", "stable", "release/production"] {
        let reference = format!("refs/heads/{branch}");
        fixture.seed(&reference);
        fixture.arguments["destination"] = json!(reference);
        let result = fixture.push(|prompt, state| {
            assert!(state.remote_refs().contains(&reference));
            if state.prompts.len() == 1 {
                Fixture::accept(prompt)
            } else {
                json!({"action":"accept","content":{"repository_name":"wrong"}})
            }
        });
        assert_eq!(result["status"], "not_pushed");
        assert_eq!(fixture.prompts.len(), 2);
        let first = &fixture.prompts[0]["params"];
        assert!(
            first["message"]
                .as_str()
                .unwrap()
                .starts_with("Шаг 1 из 2: Удаление защищённой ветки")
        );
        assert!(first["requestedSchema"]["properties"]["decision"].is_object());
        assert!(
            fixture.prompts[1]["params"]["requestedSchema"]["properties"]["repository_name"]
                .is_object()
        );
        assert!(fixture.remote_refs().contains(&reference));
        assert_eq!(fixture.push_accept()["status"], "completed");
        assert_eq!(fixture.prompts.len(), 2);
        assert!(!fixture.remote_refs().contains(&reference));
    }
}

#[test]
fn deletion_stops_if_the_remote_does_not_advertise_its_default_branch() {
    let mut fixture = Fixture::new(true);
    let branch = "refs/heads/feature/cleanup";
    fixture.seed(branch);
    fixture.git(&[
        "--git-dir",
        fixture.remote.to_str().unwrap(),
        "update-ref",
        "--no-deref",
        "HEAD",
        &fixture.first,
    ]);
    fixture.arguments["destination"] = json!(branch);
    fixture.arguments["delete"] = json!(true);
    let result = fixture.push_accept();
    assert!(
        result
            .to_string()
            .contains("did not advertise its default branch")
    );
    assert!(fixture.prompts.is_empty());
    assert!(fixture.remote_refs().contains(branch));
}

// Both modes use the same isolated Git refs, requests, and expected stop point.
fn deletion_confirmation_scenario<C>(
    mut fixture: Fixture<C>,
    mut request: impl FnMut(&mut Fixture<C>, bool) -> Value,
) {
    let feature = "refs/heads/feature/example";
    let trunk = "refs/heads/trunk";
    fixture.seed(feature);
    fixture.seed(trunk);
    let remote = fixture.remote.to_str().unwrap();
    fixture.git(&["--git-dir", remote, "symbolic-ref", "HEAD", trunk]);
    // Keep the rehearsal recoverable even if the person approves the final form by accident.
    fixture.git(&["--git-dir", remote, "config", "receive.denyDeletes", "true"]);
    let before = fixture.remote_refs();
    fixture.arguments["delete"] = json!(true);

    for (branch, protected, expected_stop, instruction) in [
        (
            feature,
            false,
            "Confirmation stopped at risk 1",
            "Нажмите «Отменить всю операцию».",
        ),
        (
            trunk,
            true,
            "The final confirmation was declined",
            "Разрешите первый шаг. На втором шаге оставьте имя пустым и нажмите «Отменить всю операцию».",
        ),
    ] {
        fixture.arguments["destination"] = json!(branch);
        fixture.arguments["reason"] = json!(instruction);
        let result = request(&mut fixture, protected);
        assert_eq!(
            fixture.remote_refs(),
            before,
            "Remote refs changed after {branch}"
        );
        assert_eq!(result["status"], "not_pushed", "{result}");
        assert!(
            result["message"].as_str().unwrap().contains(expected_stop),
            "{result}"
        );
    }
}

#[test]
fn cancelling_each_deletion_at_its_final_prompt_keeps_both_branches() {
    deletion_confirmation_scenario(Fixture::new(true), |fixture, protected| {
        let result = fixture.push(|prompt, state| {
            let required = &prompt["params"]["requestedSchema"]["required"];
            match state.prompts.len() {
                1 => {
                    assert_eq!(required, &json!(["decision"]));
                    if protected {
                        Fixture::accept(prompt)
                    } else {
                        json!({"action":"decline"})
                    }
                }
                2 if protected => {
                    assert_eq!(required, &json!(["repository_name"]));
                    json!({"action":"decline"})
                }
                _ => panic!("Unexpected confirmation after cancellation"),
            }
        });
        assert_eq!(fixture.prompts.len(), if protected { 2 } else { 1 });
        result
    });
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "interactive: a person must answer the two deletion requests"]
fn rehearse_deletion_with_native_windows() {
    let binary = std::env::var_os("AGENT_WATCH_TEST_GIT_BIN")
        .map_or_else(
            || PathBuf::from(env!("CARGO_BIN_EXE_agent-watch-git")),
            PathBuf::from,
        )
        .canonicalize()
        .expect("locate the requested AgentWatchGit binary");
    deletion_confirmation_scenario(Fixture::with_client(|_| ()), |fixture, _| {
        eprintln!(
            "{} — {}",
            fixture.arguments["destination"], fixture.arguments["reason"]
        );
        let output = Command::new(&binary)
            .arg("push")
            .arg(fixture.arguments.to_string())
            .current_dir(&fixture.repo)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &fixture.home)
            .env("GIT_ALLOW_PROTOCOL", "file")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(!output.status.success(), "Expected a cancellation");
        serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
            panic!(
                "CLI did not return its decision: {error}: {}",
                String::from_utf8_lossy(&output.stderr)
            )
        })
    });
}

#[test]
fn a_branch_protected_during_one_click_delete_is_kept() {
    let mut fixture = Fixture::new(true);
    let branch = "refs/heads/feature";
    fixture.seed(branch);
    fixture.arguments["destination"] = json!(branch);
    fixture.arguments["delete"] = json!(true);
    let result = fixture.push(|prompt, state| {
        state.git(&[
            "--git-dir",
            state.remote.to_str().unwrap(),
            "symbolic-ref",
            "HEAD",
            branch,
        ]);
        Fixture::accept(prompt)
    });
    assert_eq!(result["status"], "not_pushed");
    assert!(
        result["message"]
            .as_str()
            .unwrap()
            .contains("branch protection changed")
    );
    assert_eq!(fixture.prompts.len(), 1);
    assert!(fixture.remote_refs().contains(branch));
}

#[test]
fn config_changes_during_remote_head_lookup_stop_one_click_delete() {
    for key in ["include.path", "remote.origin.url"] {
        let mut fixture = Fixture::new(false);
        let branch = "refs/heads/feature/cleanup";
        fixture.seed(branch);
        fixture.arguments["destination"] = json!(branch);
        fixture.arguments["delete"] = json!(true);
        fixture.hook("#!/bin/sh\nexit 1\n");

        let included_config = fixture.directory.path().join("protected-branches");
        fixture.git(&[
            "config",
            "--file",
            included_config.to_str().unwrap(),
            "mothership.protectedBranch",
            "feature/cleanup",
        ]);
        let value = if key == "include.path" {
            included_config
        } else {
            fixture.directory.path().join("changed-destination.git")
        };

        let bin = fixture.directory.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let git = bin.join("git");
        fs::write(
            &git,
            r#"#!/bin/sh
export PATH="${PATH#*:}"
if [ "$3" = ls-remote ] && [ "$4" = --symref ] && [ -f "$HOME/config-change" ]; then
    { IFS= read -r key && IFS= read -r value; } < "$HOME/config-change" || exit 1
    git -C "$2" config --local "$key" "$value" || exit 1
fi
exec git "$@"
"#,
        )
        .unwrap();
        fs::set_permissions(git, fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::join_paths(
            std::iter::once(bin).chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
        )
        .unwrap();
        fixture.client = Client::start(&fixture.home, false, true, Some(&path));
        fixture
            .client
            .initialize(&json!({"elicitation":{"form":{}}}));

        let result = fixture.push(|prompt, state| {
            fs::write(
                state.home.join("config-change"),
                format!("{key}\n{}\n", value.display()),
            )
            .unwrap();
            Fixture::accept(prompt)
        });
        assert_eq!(result["status"], "not_pushed", "{key}: {result}");
        assert_eq!(fixture.prompts.len(), 1);
        assert!(fixture.remote_refs().contains(branch));
    }
}

#[test]
fn remote_name_and_hook_lookup_preserved_once() {
    let mut fixture = Fixture::new(true);
    let recorded = fixture.directory.path().join("arguments");
    fixture.hook(&format!("#!/bin/sh\ntest \"$1\" = origin || exit 1\ntest \"$(git remote get-url --push \"$1\")\" = \"$2\" || exit 1\nprintf '%s\\n' \"$1\" \"$2\" >> '{}'\n",recorded.display()));
    assert_eq!(fixture.push_accept()["status"], "completed");
    assert_eq!(
        fs::read_to_string(recorded)
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        ["origin", fixture.remote.to_str().unwrap()]
    );
}

#[test]
fn added_pushurl_cannot_run_hook_twice() {
    let mut fixture = Fixture::new(true);
    let recorded = fixture.directory.path().join("count");
    fixture.hook(&format!(
        "#!/bin/sh\nprintf x >> '{}'\n",
        recorded.display()
    ));
    let result = fixture.push(|prompt, current| {
        if prompt["params"]["requestedSchema"]["properties"]["repository_name"].is_object() {
            current.git(&[
                "config",
                "remote.origin.pushurl",
                current.remote.to_str().unwrap(),
            ]);
        }
        Fixture::accept(prompt)
    });
    let calls = fs::read_to_string(recorded).unwrap_or_default();
    assert!(matches!(
        result["status"].as_str(),
        Some("completed" | "not_pushed")
    ));
    assert_eq!(
        calls,
        if result["status"] == "completed" {
            "x"
        } else {
            ""
        }
    );
}

/// Starts the client with `git` in a folder ahead of PATH, as `script` (or a file that
/// cannot run, when `executable` is false).
fn with_fake_git(fixture: &mut Fixture, script: &str, executable: bool) {
    let bin = fixture.directory.path().join("bin");
    fs::create_dir(&bin).unwrap();
    let git = bin.join("git");
    fs::write(&git, script).unwrap();
    let mode = if executable { 0o755 } else { 0o644 };
    fs::set_permissions(git, fs::Permissions::from_mode(mode)).unwrap();
    let path = std::env::join_paths(
        std::iter::once(bin).chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
    )
    .unwrap();
    fixture.client = Client::start(&fixture.home, false, true, Some(&path));
    fixture
        .client
        .initialize(&json!({"elicitation":{"form":{}}}));
}

#[test]
fn a_preparation_failure_names_the_git_command_and_the_reason() {
    let mut fixture = Fixture::new(false);
    with_fake_git(
        &mut fixture,
        r#"#!/bin/sh
export PATH="${PATH#*:}"
if [ "$3" = rev-parse ] && [ "$4" = --show-toplevel ]; then
    head -c 2000000 /dev/zero | tr '\0' 'x'
    exit 0
fi
exec git "$@"
"#,
        true,
    );
    fixture.rejected("`git rev-parse` stopped (Git produced too much output)");
}

#[test]
fn a_git_that_cannot_start_says_so() {
    let mut fixture = Fixture::new(false);
    with_fake_git(&mut fixture, "not a program\n", false);
    fixture.rejected("`git check-ref-format` stopped (Git could not be started: ");
}

#[test]
fn environment_cannot_redirect_git() {
    let mut fixture = Fixture::new(true);
    fixture.client = Client::new(&fixture.home, true);
    fixture
        .client
        .initialize(&json!({"elicitation":{"form":{}}}));
    assert_eq!(fixture.push_accept()["status"], "completed");
    assert!(fixture.remote_refs().contains(&fixture.first));
}

#[test]
fn existing_pushurl_is_reset_once_or_rejected_safely() {
    let mut fixture = Fixture::new(true);
    let recorded = fixture.directory.path().join("count");
    fixture.hook(&format!(
        "#!/bin/sh\nprintf x >> '{}'\n",
        recorded.display()
    ));
    fixture.git(&[
        "config",
        "remote.origin.pushurl",
        fixture.remote.to_str().unwrap(),
    ]);
    let result = fixture.push_accept();
    if result["status"] == "not_pushed" {
        assert!(
            result["message"]
                .as_str()
                .unwrap()
                .contains("cannot reset an existing pushurl")
        );
        assert!(!recorded.exists());
    } else {
        assert_eq!(result["status"], "completed");
        assert_eq!(fs::read_to_string(recorded).unwrap(), "x");
    }
}

#[test]
fn pinned_destination_survives_config_change_inside_hook() {
    let mut fixture = Fixture::new(true);
    let other = fixture.directory.path().join("other.git");
    fixture.git(&["init", "-q", "--bare", other.to_str().unwrap()]);
    fixture.hook(&format!(
        "#!/bin/sh\ngit remote set-url origin '{}'\n",
        other.display()
    ));
    assert_eq!(fixture.push_accept()["status"], "completed");
    assert!(fixture.remote_refs().contains(&fixture.first));
    assert!(
        fixture
            .git(&["ls-remote", other.to_str().unwrap()])
            .is_empty()
    );
}

#[test]
fn noop_needs_no_confirmation_or_push() {
    let mut fixture = Fixture::new(true);
    fixture.seed("refs/heads/main");
    fixture.rejected("no push is needed");
}

#[test]
fn replace_objects_cannot_disguise_rewrite() {
    let mut fixture = Fixture::new(true);
    fixture.seed("refs/heads/main");
    let tree = format!("{}^{{tree}}", fixture.first);
    let unrelated = fixture.git(&["commit-tree", &tree, "-m", "unrelated"]);
    let replacement = fixture.git(&[
        "commit-tree",
        &tree,
        "-p",
        &fixture.first,
        "-m",
        "replacement",
    ]);
    fixture.git(&["replace", &unrelated, &replacement]);
    fixture.arguments["source"] = json!(unrelated);
    fixture.rejected("preserve existing history");
}

#[test]
fn legacy_grafts_rejected() {
    let mut fixture = Fixture::new(true);
    fs::write(
        fixture.repo.join(".git/info/grafts"),
        format!("{}\n", fixture.first),
    )
    .unwrap();
    fixture.rejected("Legacy Git grafts");
}

#[test]
fn normal_push_rejects_history_and_tag_replacement() {
    let mut fixture = Fixture::new(true);
    fixture.seed("refs/heads/main");
    fixture.git(&["checkout", "-q", "--orphan", "different"]);
    fixture.git(&["commit", "-q", "--allow-empty", "-m", "unrelated"]);
    fixture.rejected("preserve existing history");
    fixture.seed("refs/tags/v1");
    fixture.git(&["commit", "-q", "--allow-empty", "-m", "new tag"]);
    fixture.arguments["destination"] = json!("refs/tags/v1");
    fixture.rejected("Replacing an existing tag");
}

#[test]
fn bad_arguments_rejected() {
    let mut fixture = Fixture::new(true);
    let original = fixture.arguments.clone();
    for change in [
        json!({"approved":true}),
        json!({"destination":"main"}),
        json!({"destination":"refs/heads/*"}),
        json!({"remote":"--mirror"}),
        json!({"force":"true"}),
        json!({"repository":"."}),
        json!({"delete":true,"force":true}),
        json!({"delete":true,"source":"HEAD"}),
        json!({"source":""}),
        json!({"source":null}),
        json!({"reason":""}),
        json!({"reason":"first\nsecond"}),
        json!({"reason":"x".repeat(201)}),
        json!({"repository":format!("{}\n",fixture.repo.display())}),
    ] {
        fixture.arguments = original.clone();
        for (key, value) in change.as_object().unwrap() {
            fixture.arguments[key] = value.clone();
        }
        fixture.rejected("");
    }
}

#[test]
fn multiple_urls_and_rewrites_rejected() {
    let mut fixture = Fixture::new(true);
    fixture.git(&[
        "remote",
        "set-url",
        "--add",
        "--push",
        "origin",
        fixture.remote.to_str().unwrap(),
    ]);
    fixture.git(&[
        "remote",
        "set-url",
        "--add",
        "--push",
        "origin",
        "/tmp/another.git",
    ]);
    fixture.rejected("Exactly one push URL");
    fixture.git(&["config", "--unset-all", "remote.origin.pushurl"]);
    fixture.git(&[
        "config",
        "url.ssh://git@example.invalid/.insteadOf",
        "https://example.invalid/",
    ]);
    fixture.rejected("Custom URL rewrites");
}

#[test]
fn custom_transport_rejected() {
    let mut fixture = Fixture::new(true);
    fixture.git(&["config", "remote.origin.vcs", "https"]);
    fixture.rejected("transport commands are unsupported");
}

#[test]
fn real_stdio_round_trip_then_refusal() {
    let mut fixture = Fixture::new(true);
    fixture.client.send(json!({"id":3,"method":"tools/list"}));
    assert!(fixture.client.read().to_string().contains("push_once"));
    fixture.client.call(&fixture.arguments);
    let prompt = fixture.client.read();
    assert_eq!(prompt["method"], "elicitation/create");
    fixture
        .client
        .send(json!({"id":prompt["id"],"result":{"action":"decline"}}));
    let result = fixture.client.result();
    assert_eq!(result["status"], "not_pushed");
    assert!(result.get("manual_command").is_some());
    assert!(fixture.remote_refs().is_empty());
}

#[test]
fn duplicate_or_wrong_response_cannot_skip_a_confirmation() {
    let mut fixture = Fixture::new(true);
    fixture.client.call(&fixture.arguments);
    let first = fixture.client.read();
    let reply =
        json!({"id":first["id"],"result":{"action":"accept","content":{"decision":"continue"}}});
    fixture.client.send(reply.clone());
    let last = fixture.client.read();
    assert_ne!(first["id"], last["id"]);
    fixture.client.send(reply);
    fixture.client.send(json!({"id":"wrong","result":{"action":"accept","content":{"repository_name":"destination"}}}));
    fixture
        .client
        .send(json!({"id":last["id"],"result":{"action":"cancel"}}));
    assert_eq!(fixture.client.result()["status"], "not_pushed");
}

#[test]
fn cancellation_while_waiting_returns_a_manual_command() {
    let mut fixture = Fixture::new(true);
    fixture.client.call(&fixture.arguments);
    fixture.client.read();
    fixture
        .client
        .send(json!({"method":"notifications/cancelled","params":{"requestId":2}}));
    let result = fixture.client.result();
    assert_eq!(result["status"], "not_pushed");
    assert!(result.get("manual_command").is_some());
}

#[test]
fn unsupported_client_and_uninitialized_calls_fail_closed() {
    let mut fixture = Fixture::new(false);
    fixture.client.call(&fixture.arguments);
    assert!(fixture.client.read().get("error").is_some());
    fixture.client.initialize(&json!({}));
    fixture.client.call(&fixture.arguments);
    let result = fixture.client.result();
    assert!(
        result["message"]
            .as_str()
            .unwrap()
            .contains("does not support")
    );
    assert!(result.get("manual_command").is_some());
}

#[test]
fn disconnect_while_waiting_cancels_without_a_push() {
    let mut fixture = Fixture::new(true);
    fixture.client.call(&fixture.arguments);
    fixture.client.read();
    fixture.client.input = None;
    fixture.client.wait();
    assert!(fixture.remote_refs().is_empty());
}

#[test]
fn concurrent_calls_cannot_share_the_confirmation() {
    let mut fixture = Fixture::new(true);
    fixture.client.call(&fixture.arguments);
    let prompt = fixture.client.read();
    fixture.client.send(json!({"id":3,"method":"tools/call","params":{"name":"push_once","arguments":fixture.arguments}}));
    let busy = fixture.client.read();
    assert_eq!(busy["id"], 3);
    assert!(busy.get("error").is_some());
    fixture
        .client
        .send(json!({"id":prompt["id"],"result":{"action":"decline"}}));
    assert_eq!(fixture.client.result()["status"], "not_pushed");
}

#[test]
fn stalled_output_cannot_prevent_signal_cleanup() {
    let mut fixture = Fixture::new(false);
    let pid = fixture.ignoring_hook(false);
    let mut input = fixture.client.input.take().unwrap();
    let writer = thread::spawn(move || {
        for number in 100..10100 {
            if writeln!(
                input,
                "{}",
                json!({"jsonrpc":"2.0","id":number,"method":"ping"})
            )
            .and_then(|()| input.flush())
            .is_err()
            {
                break;
            }
        }
    });
    thread::sleep(Duration::from_millis(200));
    if let Err(error) = kill(
        Pid::from_raw(i32::try_from(fixture.client.child.id()).unwrap()),
        Signal::SIGTERM,
    ) {
        assert_eq!(error, Errno::ESRCH);
    }
    fixture.client.wait();
    writer.join().unwrap();
    fixture.hook_stopped(pid);
}

#[test]
fn disconnect_after_git_starts_stops_its_pre_push_hook() {
    let mut fixture = Fixture::new(false);
    let pid = fixture.ignoring_hook(true);
    fixture.client.input = None;
    fixture.client.wait();
    fixture.hook_stopped(pid);
}

#[test]
fn terminating_the_server_cancels_its_detached_push() {
    let mut fixture = Fixture::new(false);
    let pid = fixture.ignoring_hook(true);
    fixture.client.signal(Signal::SIGTERM);
    fixture.client.wait();
    fixture.hook_stopped(pid);
}

#[test]
fn hangup_of_the_server_cancels_its_detached_push() {
    let mut fixture = Fixture::new(false);
    let pid = fixture.ignoring_hook(true);
    fixture.client.signal(Signal::SIGHUP);
    fixture.client.wait();
    fixture.hook_stopped(pid);
}

#[test]
fn eof_then_sigterm_cannot_interrupt_cleanup() {
    let mut fixture = Fixture::new(false);
    let pid = fixture.ignoring_hook(false);
    fixture.client.input = None;
    thread::sleep(Duration::from_millis(150));
    let _ = kill(
        Pid::from_raw(i32::try_from(fixture.client.child.id()).unwrap()),
        Signal::SIGTERM,
    );
    fixture.client.wait();
    fixture.hook_stopped(pid);
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "opens real macOS windows; run explicitly without answering them"]
fn native_window_cancellation_disconnect_and_server_death_never_push() {
    for stop in ["cancel", "disconnect", "kill"] {
        let mut fixture = Fixture::new(false);
        fixture.client = Client::start(&fixture.home, false, false, None);
        fixture.client.initialize(&json!({}));
        fixture.arguments["reason"] =
            json!("Автоматическая проверка отмены: не отвечайте, окно закроется само.");
        fixture.client.call(&fixture.arguments);
        let deadline = Instant::now() + Duration::from_secs(10);
        let pid = loop {
            let children = Command::new("pgrep")
                .args(["-P", &fixture.client.child.id().to_string()])
                .output()
                .unwrap();
            let mut window = None;
            for pid in String::from_utf8(children.stdout)
                .unwrap()
                .split_whitespace()
            {
                let output = Command::new("ps")
                    .args(["-o", "command=", "-p", pid])
                    .output()
                    .unwrap();
                if String::from_utf8(output.stdout)
                    .unwrap()
                    .contains("--confirmation-window")
                {
                    window = Some(pid.parse::<i32>().unwrap());
                    break;
                }
            }
            if let Some(pid) = window {
                break pid;
            }
            assert!(
                Instant::now() < deadline,
                "native window child did not start: {stop}"
            );
            thread::sleep(Duration::from_millis(10));
        };
        // Let the actual helper enter AppKit and start its parent watchdog.
        thread::sleep(Duration::from_millis(200));
        let before = Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let before = String::from_utf8(before.stdout).unwrap();
        assert!(
            !before.trim().is_empty() && !before.trim().starts_with('Z'),
            "window exited before {stop}; lifecycle was not exercised"
        );
        match stop {
            "cancel" => {
                fixture
                    .client
                    .send(json!({"method":"notifications/cancelled","params":{"requestId":2}}));
                let result = fixture.client.result();
                assert_eq!(result["status"], "not_pushed", "{result}");
                assert!(result.get("manual_command").is_some());
            }
            "disconnect" => {
                fixture.client.input = None;
                fixture.client.wait();
            }
            "kill" => {
                fixture.client.signal(Signal::SIGKILL);
                fixture.client.child.wait().unwrap();
            }
            _ => unreachable!(),
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let status = Command::new("ps")
                .args(["-o", "stat=", "-p", &pid.to_string()])
                .output()
                .unwrap();
            let status = String::from_utf8(status.stdout).unwrap();
            if status.trim().is_empty() || status.trim().starts_with('Z') {
                break;
            }
            assert!(Instant::now() < deadline, "window survived {stop}: {pid}");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(fixture.remote_refs().is_empty(), "Git ran after {stop}");
    }
}

impl<C> Fixture<C> {
    /// Writes the branch types the way the app does, into the home the CLI runs with.
    fn branch_types(&self, text: &str) {
        let path = self
            .home
            .join("Library/Application Support/AgentWatch/git-branch-types.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
}

const TYPES: &str = r#"{"version":1,"types":[
    {"name":"Drafts","patterns":["agent/*"],"level":"none"},
    {"name":"Features","patterns":["feature/*"],"level":"click"},
    {"name":"Releases","patterns":["release/*"],"level":"name"},
    {"name":"Locked","patterns":["locked/*"],"level":"forbid"}]}"#;

/// The answers that would carry any operation through, and the number of windows it took.
fn run_level(fixture: &mut Fixture, branch: &str, delete: bool) -> (Value, usize) {
    let reference = format!("refs/heads/{branch}");
    fixture.seed(&reference);
    fixture.arguments = if delete {
        json!({"repository":fixture.repo,"destination":reference,"delete":true})
    } else {
        fixture.git(&["commit", "-q", "--allow-empty", "-m", branch]);
        json!({"repository":fixture.repo,"destination":reference,"force":true})
    };
    let result = fixture.push_accept();
    (result, fixture.prompts.len())
}

#[test]
fn each_level_asks_for_its_own_windows() {
    let mut fixture = Fixture::new(true);
    fixture.branch_types(TYPES);
    for delete in [false, true] {
        for (branch, windows) in [("agent/x", 0), ("feature/x", 1), ("release/x", 2)] {
            let (result, prompts) = run_level(&mut fixture, branch, delete);
            assert_eq!(result["status"], "completed", "{branch} {delete}: {result}");
            assert_eq!(prompts, windows, "{branch} delete={delete}");
        }
        let (result, prompts) = run_level(&mut fixture, "locked/x", delete);
        assert_eq!(result["status"], "not_pushed", "{result}");
        assert_eq!(prompts, 0);
        let message = result["message"].as_str().unwrap();
        assert!(message.contains("branch type 'Locked'"), "{message}");
        assert!(message.contains("no window was shown"), "{message}");
        assert!(result["manual_command"].is_string());
    }
    assert!(!fixture.remote_refs().contains("refs/heads/agent/x"));
    assert!(fixture.remote_refs().contains("refs/heads/locked/x"));
}

#[test]
fn a_click_level_force_push_runs_from_its_only_window() {
    let mut fixture = Fixture::new(true);
    fixture.branch_types(TYPES);
    let (result, prompts) = run_level(&mut fixture, "feature/one-window", false);
    assert_eq!(result["status"], "completed", "{result}");
    assert_eq!(prompts, 1);
    let params = &fixture.prompts[0]["params"];
    let message = params["message"].as_str().unwrap();
    assert!(
        message.starts_with("Шаг 1 из 1: Принудительная отправка"),
        "{message}"
    );
    assert!(message.contains("Тип ветки: Features"), "{message}");
    assert!(message.contains("Версия кода: HEAD"), "{message}");
    assert!(message.contains("Кнопка «Перезаписать историю ветки» выполнит операцию"));
    let decision = &params["requestedSchema"]["properties"]["decision"];
    assert_eq!(decision["oneOf"][1]["title"], "Перезаписать историю ветки");
    assert!(params["requestedSchema"]["properties"]["repository_name"].is_null());
}

#[test]
fn the_floor_keeps_the_repository_name_whatever_the_type_says() {
    let mut fixture = Fixture::new(true);
    fixture.branch_types(
        r#"{"version":1,"types":[{"name":"Everything","patterns":["*"],"level":"none"}]}"#,
    );
    fixture.git(&["config", "--add", "mothership.protectedBranch", "stable"]);
    let remote = fixture.remote.to_str().unwrap().to_owned();
    fixture.git(&[
        "--git-dir",
        &remote,
        "symbolic-ref",
        "HEAD",
        "refs/heads/trunk",
    ]);
    for (destination, delete, windows) in [
        ("refs/heads/main", true, 2),
        ("refs/heads/master", true, 2),
        ("refs/heads/trunk", true, 2),
        ("refs/heads/trunk", false, 2),
        ("refs/heads/stable", true, 2),
        ("refs/tags/v1", true, 2),
        ("refs/heads/main", false, 3),
        ("refs/heads/stable", false, 2),
        ("refs/tags/v2", false, 2),
    ] {
        fixture.seed(destination);
        fixture.git(&["commit", "-q", "--allow-empty", "-m", destination]);
        fixture.arguments = json!({"repository":fixture.repo,"destination":destination});
        fixture.arguments[if delete { "delete" } else { "force" }] = json!(true);
        let result = fixture.push(|prompt, _| {
            if prompt["params"]["requestedSchema"]["properties"]["decision"].is_object() {
                Fixture::accept(prompt)
            } else {
                json!({"action":"decline"})
            }
        });
        assert_eq!(result["status"], "not_pushed", "{destination}: {result}");
        assert_eq!(
            fixture.prompts.len(),
            windows,
            "{destination} delete={delete}"
        );
        let last = &fixture.prompts[windows - 1]["params"]["requestedSchema"]["properties"];
        assert!(last["repository_name"].is_object(), "{destination}");
        assert!(fixture.remote_refs().contains(destination), "{destination}");
    }
}

#[test]
fn the_first_matching_type_decides() {
    let mut fixture = Fixture::new(true);
    fixture.branch_types(
        r#"{"version":1,"types":[
            {"name":"Drafts","patterns":["agent/*"],"level":"none"},
            {"name":"Everything","patterns":["*"],"level":"forbid"}]}"#,
    );
    let (result, prompts) = run_level(&mut fixture, "agent/first", true);
    assert_eq!((result["status"].as_str(), prompts), (Some("completed"), 0));
    let (result, prompts) = run_level(&mut fixture, "other/second", true);
    assert_eq!(
        (result["status"].as_str(), prompts),
        (Some("not_pushed"), 0)
    );
    assert!(result["message"].as_str().unwrap().contains("'Everything'"));
}

#[test]
fn without_a_readable_table_branches_keep_their_windows() {
    for table in [None, Some("{"), Some(r#"{"version":1,"types":[]}"#)] {
        let mut fixture = Fixture::new(true);
        if let Some(table) = table {
            fixture.branch_types(table);
        }
        let (result, prompts) = run_level(&mut fixture, "agent/x", true);
        assert_eq!((result["status"].as_str(), prompts), (Some("completed"), 1));
        assert!(
            !fixture.prompts[0]["params"]["message"]
                .as_str()
                .unwrap()
                .contains("Тип ветки")
        );
        let (result, prompts) = run_level(&mut fixture, "agent/y", false);
        assert_eq!((result["status"].as_str(), prompts), (Some("completed"), 2));
    }
}

#[test]
fn a_project_rule_only_raises_a_type() {
    let mut fixture = Fixture::new(true);
    fixture.branch_types(TYPES);
    for branch in ["agent/kept", "feature/kept", "locked/kept"] {
        fixture.git(&["config", "--add", "mothership.protectedBranch", branch]);
    }
    for (branch, windows) in [("agent/kept", 2), ("feature/kept", 2)] {
        let (result, prompts) = run_level(&mut fixture, branch, true);
        assert_eq!(result["status"], "completed", "{result}");
        assert_eq!(prompts, windows, "{branch}");
    }
    let (result, prompts) = run_level(&mut fixture, "locked/kept", true);
    assert_eq!(
        (result["status"].as_str(), prompts),
        (Some("not_pushed"), 0)
    );
}

#[test]
fn a_level_raised_during_the_window_stops_the_push() {
    let mut fixture = Fixture::new(true);
    fixture.branch_types(TYPES);
    let branch = "refs/heads/feature/raised";
    fixture.seed(branch);
    fixture.arguments = json!({"repository":fixture.repo,"destination":branch,"delete":true});
    let result = fixture.push(|prompt, state| {
        state.branch_types(&TYPES.replace(r#""click""#, r#""forbid""#));
        Fixture::accept(prompt)
    });
    assert_eq!(result["status"], "not_pushed", "{result}");
    assert!(
        result["message"]
            .as_str()
            .unwrap()
            .contains("changed during confirmation")
    );
    assert!(fixture.remote_refs().contains(branch));
}
