//! Only model output is scripted. Tool dispatch, subprocess ownership and hook results come from the real clients.
use crate::Client;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::io::Read;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

#[derive(Clone)]
pub(crate) struct Plan {
    pub command: String,
    pub prompt: String,
    /// The model may follow the hook direction once, only if the actual denial names this binary.
    pub follow: Option<(String, String)>,
}

#[derive(Default)]
struct State {
    issued: bool,
    denial: Option<String>,
    error: Option<String>,
}

pub(crate) struct Model {
    pub url: String,
    state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Model {
    pub fn start(client: Client, plan: Plan) -> Result<Self> {
        let server = Server::http(("127.0.0.1", 0)).map_err(anyhow::Error::from_boxed)?;
        let url = format!("http://{}", server.server_addr());
        let state = Arc::new(Mutex::new(State::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let shared = state.clone();
        let stopping = stop.clone();
        let worker = thread::spawn(move || {
            // A pending Codex turn must stay alive after exec_command yields a running shell.
            let mut held = Vec::new();
            while !stopping.load(Ordering::Acquire) {
                match server.recv_timeout(Duration::from_millis(100)) {
                    Ok(Some(request)) if !is_model_request(client, &request) => {
                        let _ = request.respond(Response::empty(StatusCode(404)));
                    }
                    Ok(Some(mut request)) => match reply(client, &mut request, &plan, &shared) {
                        Ok(Some((kind, data))) => {
                            let header = Header::from_bytes("Content-Type", kind)
                                .expect("constant HTTP header");
                            let _ =
                                request.respond(Response::from_string(data).with_header(header));
                        }
                        Ok(None) => held.push(request),
                        Err(err) => {
                            let msg = err.to_string();
                            shared.lock().unwrap().error = Some(msg.clone());
                            let _ = request.respond(
                                Response::from_string(msg).with_status_code(StatusCode(400)),
                            );
                        }
                    },
                    Ok(None) => (),
                    Err(err) => {
                        shared.lock().unwrap().error = Some(err.to_string());
                        break;
                    }
                }
            }
        });
        Ok(Self {
            url,
            state,
            stop,
            worker: Some(worker),
        })
    }

    pub fn check(&self) -> Result<()> {
        if let Some(err) = &self.state.lock().unwrap().error {
            anyhow::bail!("Local model: {err}");
        }
        Ok(())
    }

    pub fn issued(&self) -> bool {
        self.state.lock().unwrap().issued
    }
    pub fn denial(&self) -> Option<String> {
        self.state.lock().unwrap().denial.clone()
    }
}

impl Drop for Model {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.worker.take() {
            let _ = thread.join();
        }
    }
}

fn is_model_request(client: Client, request: &Request) -> bool {
    let endpoint = match client {
        Client::Claude => "/v1/messages",
        Client::Codex => "/v1/responses",
    };
    request.method() == &Method::Post && request.url().split('?').next() == Some(endpoint)
}

fn reply(
    client: Client,
    request: &mut Request,
    plan: &Plan,
    shared: &Mutex<State>,
) -> Result<Option<(&'static str, String)>> {
    let mut data = Vec::new();
    request
        .as_reader()
        .take(32 * 1024 * 1024 + 1)
        .read_to_end(&mut data)?;
    ensure!(
        data.len() <= 32 * 1024 * 1024,
        "Fixture model request exceeds 32 MiB"
    );
    let body: Value = serde_json::from_slice(&data)?;
    let mut state = shared.lock().unwrap();
    let tools = body["tools"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default();
    let tool = match client {
        Client::Codex => "exec_command",
        Client::Claude => "Bash",
    };
    let advertised = tools.iter().any(|entry| entry["name"] == tool);
    let mut command = None;
    let mut following = false;
    let output = match client {
        Client::Codex => {
            ensure!(advertised, "Codex did not advertise exec_command");
            body["input"].as_array().and_then(|items| {
                items
                    .iter()
                    .rev()
                    .find(|item| item["type"] == "function_call_output")
            })
        }
        Client::Claude => body["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|message| message["content"].as_array().into_iter().flatten())
            .rfind(|block| block["type"] == "tool_result"),
    };
    let relevant = client == Client::Codex || body["messages"].to_string().contains(&plan.prompt);
    if advertised && relevant {
        if !state.issued && output.is_none() {
            state.issued = true;
            command = Some(plan.command.as_str());
        } else if let (Some((expected, follow)), Some(output)) = (&plan.follow, output)
            && state.denial.is_none()
        {
            let text = output.to_string();
            if text.contains(expected) && text.contains("push") {
                command = Some(follow.as_str());
                following = true;
            }
            state.denial = Some(text);
        }
    }
    if client == Client::Codex {
        return Ok(command.map(|cmd| ("text/event-stream", codex_events(cmd, following))));
    }
    Ok(Some(claude_response(&body, command, following)?))
}

fn events(items: &[Value]) -> String {
    items
        .iter()
        .map(|item| {
            format!(
                "event: {}\ndata: {item}\n\n",
                item["type"].as_str().unwrap()
            )
        })
        .collect()
}

fn codex_events(command: &str, following: bool) -> String {
    let suffix = if following { "followup" } else { "fixture" };
    let args = json!({"cmd":command,"yield_time_ms":1000,"login":false});
    let call = json!({"type":"function_call","id":format!("fc_{suffix}"),"call_id":format!("call_{suffix}"),
        "name":"exec_command","arguments":args.to_string()});
    let mut empty = call.clone();
    empty["arguments"] = json!("");
    let response = json!({"id":"resp_fixture","object":"response","status":"in_progress","model":"gpt-5.4","output":[],
        "usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}});
    let mut done = response.clone();
    done["status"] = json!("completed");
    done["output"] = json!([call]);
    events(&[
        json!({"type":"response.created","response":response}),
        json!({"type":"response.output_item.added","output_index":0,"item":empty}),
        json!({"type":"response.output_item.done","output_index":0,"item":call}),
        json!({"type":"response.completed","response":done}),
    ])
}

fn claude_response(
    body: &Value,
    command: Option<&str>,
    following: bool,
) -> Result<(&'static str, String)> {
    let (block, start, delta, reason) = if let Some(cmd) = command {
        let id = if following {
            "toolu_followup"
        } else {
            "toolu_fixture"
        };
        let input = json!({"command":cmd});
        let start = json!({"type":"tool_use","id":id,"name":"Bash","input":{}});
        let mut block = start.clone();
        block["input"] = input.clone();
        (
            block,
            start,
            json!({"type":"input_json_delta","partial_json":input.to_string()}),
            "tool_use",
        )
    } else {
        (
            json!({"type":"text","text":"Done"}),
            json!({"type":"text","text":""}),
            json!({"type":"text_delta","text":"Done"}),
            "end_turn",
        )
    };
    let mut message = json!({"id":"msg_fixture","type":"message","role":"assistant","model":body["model"].as_str().context("Missing model")?,
        "content":[block],"stop_reason":reason,"stop_sequence":null,"usage":{"input_tokens":8,"output_tokens":12}});
    if body["stream"] != true {
        return Ok(("application/json", message.to_string()));
    }
    message["content"] = json!([]);
    message["stop_reason"] = Value::Null;
    Ok((
        "text/event-stream",
        events(&[
            json!({"type":"message_start","message":message}),
            json!({"type":"content_block_start","index":0,"content_block":start}),
            json!({"type":"content_block_delta","index":0,"delta":delta}),
            json!({"type":"content_block_stop","index":0}),
            json!({"type":"message_delta","delta":{"stop_reason":reason,"stop_sequence":null},"usage":{"output_tokens":12}}),
            json!({"type":"message_stop"}),
        ]),
    ))
}
