use crate::domain::Arguments;
use crate::process::Cancellation;
use nix::errno::Errno;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::unistd::write;
use serde_json::{Value, json};
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;
use std::io::{BufRead, BufReader, Read};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::thread;
use std::time::{Duration, Instant};

const MAX_MESSAGE: usize = 1024 * 1024;

#[derive(Clone, Copy, PartialEq)]
enum ConfirmationUi {
    Window,
    McpForms,
}

enum Event {
    Message(Value),
    ParseError,
    Closed,
    Prompt {
        message: String,
        schema: Value,
        reply: SyncSender<Value>,
    },
    Finished(Value),
}

fn input(sender: &SyncSender<Event>, shutdown: &AtomicBool) {
    let mut input = BufReader::new(std::io::stdin().lock());
    loop {
        let mut line = Vec::new();
        // A bounded read avoids allocating an unbounded line before checking it.
        match input
            .by_ref()
            .take(u64::try_from(MAX_MESSAGE + 1).unwrap())
            .read_until(b'\n', &mut line)
        {
            Ok(0) | Err(_) => break,
            Ok(_) if line.len() > MAX_MESSAGE || !line.ends_with(b"\n") => break,
            Ok(_) => {
                let event = match serde_json::from_slice::<Value>(&line) {
                    Ok(value) if value.is_object() => Event::Message(value),
                    _ => Event::ParseError,
                };
                if sender.send(event).is_err() {
                    return;
                }
            }
        }
    }
    shutdown.store(true, Ordering::Release);
    let _ = sender.send(Event::Closed);
}

fn elicit(
    sender: &SyncSender<Event>,
    cancel: &Cancellation,
    deadline: Instant,
    message: String,
    schema: Value,
) -> Result<Value, String> {
    cancel.check(deadline)?;
    let (reply, response) = mpsc::sync_channel(1);
    sender
        .send(Event::Prompt {
            message,
            schema,
            reply,
        })
        .map_err(|_| "The client disconnected.")?;
    loop {
        cancel.check(deadline)?;
        match response.recv_timeout(Duration::from_millis(50)) {
            Ok(value) => {
                cancel.check(deadline)?;
                return value
                    .get("result")
                    .filter(|v| v.is_object())
                    .cloned()
                    .ok_or_else(|| "The client could not obtain confirmation.".into());
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => return Err("The confirmation was cancelled.".into()),
        }
    }
}

fn execute(
    arguments: Value,
    sender: &SyncSender<Event>,
    cancel: &Cancellation,
    forms: bool,
    titled_choices: bool,
    ui: ConfirmationUi,
) -> Result<Value, String> {
    let args: Arguments = serde_json::from_value(arguments).map_err(
        |_| "Invalid push arguments; approval flags and shell commands are not accepted.",
    )?;
    crate::push::execute(
        &args,
        cancel,
        titled_choices || ui == ConfirmationUi::Window,
        |form, deadline| match ui {
            ConfirmationUi::Window => crate::window::confirm(form, cancel, deadline),
            ConfirmationUi::McpForms if forms => {
                elicit(sender, cancel, deadline, form.message, form.schema)
            }
            ConfirmationUi::McpForms => {
                Err("This client does not support MCP confirmation forms.".into())
            }
        },
    )
}

struct Active {
    id: Value,
    cancel: Cancellation,
}

#[derive(PartialEq)]
enum Phase {
    New,
    Initialized,
    Ready,
}

struct Server {
    sender: SyncSender<Event>,
    phase: Phase,
    forms: bool,
    titled_choices: bool,
    ui: ConfirmationUi,
    active: Option<Active>,
    pending: Option<(String, SyncSender<Value>)>,
    next_id: u64,
    closed: bool,
    shutdown: Arc<AtomicBool>,
}

impl Server {
    fn send(&self, mut value: Value) -> Result<(), String> {
        if self.closed {
            return Ok(());
        }
        value["jsonrpc"] = json!("2.0");
        let mut frame = serde_json::to_vec(&value).map_err(|_| "Invalid server response.")?;
        frame.push(b'\n');
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut remaining = frame.as_slice();
        while !remaining.is_empty() {
            if self.shutdown.load(Ordering::Acquire) || Instant::now() >= deadline {
                return Err("The client stopped reading responses.".into());
            }
            match write(std::io::stdout(), remaining) {
                Ok(0) => return Err("The client disconnected.".into()),
                Ok(count) => remaining = &remaining[count..],
                Err(Errno::EINTR) => {}
                Err(Errno::EAGAIN) => thread::sleep(Duration::from_millis(10)),
                Err(_) => return Err("The client disconnected.".into()),
            }
        }
        Ok(())
    }

    fn error(&self, id: &Value, code: i32, message: &str) -> Result<(), String> {
        self.send(json!({"id":id,"error":{"code":code,"message":message}}))
    }

    fn stop(&mut self) {
        self.closed = true;
        self.pending = None;
        if let Some(active) = &self.active {
            active.cancel.cancel();
        }
    }

    fn dispatch(&mut self, message: &Value) -> Result<(), String> {
        let id = &message["id"];
        let Some(method) = message["method"].as_str() else {
            if self
                .pending
                .as_ref()
                .is_some_and(|(pending, _)| id.as_str() == Some(pending))
                && let Some((_, reply)) = self.pending.take()
            {
                let _ = reply.send(message.clone());
            }
            return Ok(());
        };
        let empty = json!({});
        let params = message.get("params").unwrap_or(&empty);
        if !params.is_object() {
            return self.error(id, -32602, "params must be an object");
        }
        match method {
            "notifications/cancelled" => {
                if let Some(active) = &self.active
                    && params["requestId"] == active.id { active.cancel.cancel(); self.pending = None; }
            }
            "notifications/initialized" => if self.phase == Phase::Initialized { self.phase = Phase::Ready; },
            "initialize" if self.phase == Phase::New => {
                self.forms = params["capabilities"]["elicitation"].as_object().is_some_and(|e| e.is_empty() || e.contains_key("form"));
                self.titled_choices = params["protocolVersion"] != "2025-06-18";
                self.phase = Phase::Initialized;
                let version = match params["protocolVersion"].as_str() { Some("2025-06-18") => "2025-06-18", _ => "2025-11-25" };
                let instructions = match self.ui {
                    ConfirmationUi::Window => "Use push_once. Agent Watch opens a macOS window. Never automate confirmations.",
                    ConfirmationUi::McpForms => "Use push_once. Agent Watch asks in the client. Never automate confirmations.",
                };
                self.send(json!({"id":id,"result":{"protocolVersion":version,"capabilities":{"tools":{}},"serverInfo":{"name":"agent-watch-git","version":env!("CARGO_PKG_VERSION")},"instructions":instructions}}))?;
            }
            "ping" => self.send(json!({"id":id,"result":{}}))?,
            _ if self.phase != Phase::Ready => self.error(id, -32600, "Initialize the MCP connection first")?,
            "tools/list" => self.send(json!({"id":id,"result":{"tools":[serde_json::from_str::<Value>(include_str!("tool.json")).map_err(|_| "Invalid built-in tool schema.")?]}}))?,
            "tools/call" => {
                if params["name"] != "push_once" || !params["arguments"].is_object() {
                    return self.error(id, -32602, "Unknown tool or invalid arguments");
                }
                if !id.is_string() && !id.is_i64() && !id.is_u64() { return self.error(id, -32600, "tools/call requires a request id"); }
                if self.active.is_some() { return self.error(id, -32600, "Another push request is still active"); }
                let cancel = Cancellation::new();
                self.active = Some(Active {id:id.clone(),cancel:cancel.clone()});
                let arguments = params["arguments"].clone();
                let sender = self.sender.clone();
                let forms = self.forms;
                let titled_choices = self.titled_choices;
                let ui = self.ui;
                thread::spawn(move || {
                    let value = match std::panic::catch_unwind(|| execute(arguments, &sender, &cancel, forms, titled_choices, ui)) {
                        Ok(Ok(value)) => value,
                        Ok(Err(message)) => json!({"status":"not_pushed","message":message}),
                        Err(_) => json!({"status":"outcome_unknown","message":"The push tool failed. Check the remote before retrying."}),
                    };
                    let _ = sender.send(Event::Finished(value));
                });
            }
            _ if method.starts_with("notifications/") => {}
            _ => self.error(id, -32601, "Method not found")?,
        }
        Ok(())
    }

    fn events(&mut self, events: &Receiver<Event>) {
        while let Ok(event) = events.recv() {
            let result = match event {
                Event::Closed => {
                    self.stop();
                    Ok(())
                }
                Event::ParseError if !self.closed => {
                    self.error(&Value::Null, -32700, "Invalid JSON-RPC object")
                }
                Event::Message(message) if !self.closed => self.dispatch(&message),
                Event::Prompt {
                    message,
                    schema,
                    reply,
                } if !self.closed => {
                    self.next_id += 1;
                    let id = format!("confirmation-{}", self.next_id);
                    self.pending = Some((id.clone(), reply));
                    self.send(json!({"id":id,"method":"elicitation/create","params":{"mode":"form","message":message,"requestedSchema":schema}}))
                }
                Event::Finished(value) => {
                    self.pending = None;
                    if let Some(active) = self.active.take() {
                        self.send(json!({"id":active.id,"result":{"isError":!matches!(value["status"].as_str(),Some("completed"|"not_pushed")),"content":[{"type":"text","text":value.to_string()}]}}))
                    } else {
                        Ok(())
                    }
                }
                _ => Ok(()),
            };
            if result.is_err() {
                self.stop();
            }
            if self.closed && self.active.is_none() {
                break;
            }
        }
    }
}

pub fn run(mcp_forms: bool) -> Result<(), String> {
    fcntl(std::io::stdout(), FcntlArg::F_SETFL(OFlag::O_NONBLOCK))
        .map_err(|_| "MCP output could not be configured.")?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let (sender, events) = mpsc::sync_channel(16);
    let mut signals =
        Signals::new([SIGTERM, SIGHUP, SIGINT]).map_err(|_| "Signal handling could not start.")?;
    let handle = signals.handle();
    let signal_sender = sender.clone();
    let signal_shutdown = shutdown.clone();
    thread::spawn(move || {
        for _ in signals.forever() {
            signal_shutdown.store(true, Ordering::Release);
            if signal_sender.send(Event::Closed).is_err() {
                break;
            }
        }
    });
    let input_sender = sender.clone();
    let input_shutdown = shutdown.clone();
    thread::spawn(move || input(&input_sender, &input_shutdown));
    let mut server = Server {
        sender,
        phase: Phase::New,
        forms: false,
        titled_choices: false,
        ui: if mcp_forms {
            ConfirmationUi::McpForms
        } else {
            ConfirmationUi::Window
        },
        active: None,
        pending: None,
        next_id: 0,
        closed: false,
        shutdown,
    };
    server.events(&events);
    handle.close();
    Ok(())
}
