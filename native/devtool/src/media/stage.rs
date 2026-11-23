use super::scene::{Scene, applescript_string, pids};
use super::{NAMES, Result, args, discard, output, sleep, wait};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}

fn demo_settings(source: &str, sender: &Path) -> Result<Value> {
    let value: Value = serde_json::from_str(source).map_err(|e| e.to_string())?;
    let mut hooks = serde_json::Map::new();
    for (event, groups) in value
        .get("hooks")
        .and_then(Value::as_object)
        .ok_or("No Claude hooks")?
    {
        if !event.chars().all(char::is_alphanumeric) {
            return Err(format!("Invalid hook event {event}"));
        }
        for hook in groups
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|g| g["hooks"].as_array())
            .flatten()
        {
            if hook["command"]
                .as_str()
                .is_some_and(|c| c.contains("AgentWatchSend"))
            {
                let mut hook = hook.clone();
                hook["command"] = json!(format!(
                    "{} --source claude --event {event}",
                    shell_quote(&sender.to_string_lossy())
                ));
                hooks.insert(event.clone(), json!([{"hooks":[hook]}]));
            }
        }
    }
    if hooks.is_empty() {
        return Err("No Agent Watch hooks in the configuration".into());
    }
    Ok(
        json!({"hooks":hooks,"spinnerVerbs":{"mode":"replace","verbs":["Working","Thinking","Reading"]},"spinnerTipsEnabled":false,"preferredNotifChannel":"notifications_disabled","env":{"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY":"1"}}),
    )
}

fn config(scene: &Scene, name: &str) -> String {
    let command = format!(
        " clear && exec claude --setting-sources project,local --strict-mcp-config --settings {} --permission-mode default --name {}",
        shell_quote(&scene.settings.to_string_lossy()),
        shell_quote(name)
    );
    format!(
        "{{initial working directory:{}, initial input:{} & return, environment variables:{{{}, \"IS_DEMO=1\"}}, font size:14}}",
        applescript_string(&scene.main.to_string_lossy()),
        applescript_string(&command),
        applescript_string(&format!(
            "AGENT_WATCH_SUPPORT_DIR={}",
            scene.support.display()
        ))
    )
}

fn start_copy(scene: &mut Scene) -> Result {
    scene.start_copy()?;
    sleep(2.0);
    scene.dismiss()
}

fn up(scene: &mut Scene) -> Result {
    if !scene.state.window.is_empty() && !scene.demo_claudes().is_empty() {
        return Err("A stage is up already: stage down first".into());
    }
    let perms = scene.driver(args!["check"])?;
    if perms.contains("false") {
        return Err(format!("Missing permissions: {perms}"));
    }
    if let Some(pid) = scene.demo_pid() {
        scene.driver(args!["quit", pid])?;
        sleep(2.0);
    }
    if !pids("AgentWatch").is_empty() {
        return Err("Agent Watch runs: quit it before putting up the stage".into());
    }
    if !wait(
        || scene.driver(args!["onscreen"]).is_ok_and(|v| v.is_empty()),
        20,
        0.25,
    ) {
        return Err(format!(
            "This desktop is not empty: {}",
            scene.driver(args!["onscreen"])?
        ));
    }
    if std::env::var_os("AW_PREBUILT").is_none_or(|v| v.is_empty()) {
        let path = scene.work.join("build.log");
        let log = fs::File::create(&path).map_err(|e| e.to_string())?;
        let status = Command::new(std::env::current_exe().map_err(|e| e.to_string())?)
            .env("AGENT_WATCH_FLAVOR", "production")
            .arg("build-app")
            .arg("debug")
            .arg(&scene.app)
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log)
            .stdin(Stdio::null())
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(format!("Build failed: {}", path.display()));
        }
    } else if !scene.app.is_dir() {
        return Err(format!(
            "AW_PREBUILT is set but {} is missing",
            scene.app.display()
        ));
    }
    let plugin = std::env::var_os("AW_CLAUDE_HOOKS")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            scene
                .home
                .join(".claude/skills/agent-watch/hooks/hooks.json")
        });
    let settings = demo_settings(
        &super::read(&plugin)?,
        &scene.support.join("AgentWatch/AgentWatchSend"),
    )?;
    fs::write(
        &scene.settings,
        serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    discard(&scene.support, &scene.home)?;
    let support = scene.support.join("AgentWatch");
    fs::create_dir_all(support.join("Themes")).map_err(|e| e.to_string())?;
    fs::write(
        support.join("settings.json"),
        r#"{"widgetWidth":340,"widgetHeight":100,"widgetSizeFollowsSessions":false}"#,
    )
    .map_err(|e| e.to_string())?;
    fs::copy(
        scene.scripts().join("demo-theme.json"),
        support.join("Themes/demo-theme.json"),
    )
    .map_err(|e| e.to_string())?;
    start_copy(scene)?;
    let started = scene.count("sessionStarted", "");
    let mut script = format!(
        "tell application \"Ghostty\"\nset w to new window with configuration {}\n",
        config(scene, NAMES[0])
    );
    for name in &NAMES[1..] {
        script += &format!("new tab in w with configuration {}\n", config(scene, name));
    }
    script += "return id of w\nend tell";
    scene.state.window = output("osascript", &["-e", &script])?;
    scene.state.ghost = pids("ghostty")
        .into_iter()
        .next()
        .ok_or("Ghostty did not start")?;
    scene.save()?;
    for i in 0..NAMES.len() {
        scene.require_event("sessionStarted", started + i, 90, "")?;
    }
    // Measured on Claude Code 2.1.294: three simultaneous sessions took over 20 seconds to give every tab its name.
    let titles = format!(
        "tell application \"Ghostty\" to get name of every tab of (first window whose id is {})",
        applescript_string(&scene.state.window)
    );
    if !wait(
        || output("osascript", &["-e", &titles]).is_ok_and(|t| NAMES.iter().all(|n| t.contains(n))),
        480,
        0.25,
    ) {
        return Err("The tabs are not named after the sessions yet".into());
    }
    scene.state.ids = vec![String::new(); NAMES.len()];
    for i in (1..NAMES.len()).chain(std::iter::once(0)) {
        let prompt = match i {
            0 => "Run `task --list` and tell me in one line which task runs the unit tests.",
            1 => "List the targets in Package.swift in one line.",
            _ => "Reply with one word: ready.",
        };
        let before = scene.count("turnStarted", "");
        scene.say(NAMES[i], prompt)?;
        scene.require_event("turnStarted", before, 30, "")?;
        scene.state.ids[i] = scene.last_id("turnStarted")?;
    }
    scene.state.asker.clone_from(&scene.state.ids[0]);
    for id in &scene.state.ids[1..] {
        scene.require_event("turnCompleted", 0, 120, id)?;
    }
    scene.require_event("userInputRequired", 0, 120, &scene.state.asker)?;
    scene.save()?;
    println!(
        "· up: copy {}, Ghostty window {}",
        scene.state.demo, scene.state.window
    );
    Ok(())
}

fn reset(scene: &mut Scene) -> Result {
    let pid = scene
        .demo_pid()
        .filter(|p| *p == scene.state.demo)
        .ok_or("No running demo stage")?;
    if scene.last_turn(&scene.state.asker) == "userInputRequired" {
        scene.press(NAMES[0], "enter")?;
    }
    let live = scene.live();
    for &i in &live {
        if !wait(
            || scene.last_turn(&scene.state.ids[i]) == "turnCompleted",
            960,
            0.25,
        ) {
            return Err(format!(
                "{} is still working or waiting for input",
                NAMES[i]
            ));
        }
    }
    scene.driver(args!["quit", pid])?;
    if !wait(|| scene.demo_pid().is_none(), 40, 0.25) {
        return Err("The demo copy did not quit".into());
    }
    discard(&scene.support.join("AgentWatch/settings.json"), &scene.home)?;
    start_copy(scene)?;
    scene.save()?;
    let mut before = Vec::new();
    for &i in &live {
        before.push(scene.count("turnCompleted", &scene.state.ids[i]));
        scene.say(NAMES[i], "Reply with one word: ok.")?;
    }
    for (i, count) in live.into_iter().zip(before) {
        scene.require_event("turnCompleted", count, 60, &scene.state.ids[i])?;
    }
    println!(
        "· copy restarted with default settings: {}",
        scene.state.demo
    );
    Ok(())
}

pub(super) fn run(scene: &mut Scene, command: &str) -> Result {
    match command {
        "up" => up(scene),
        "reset-settings" => reset(scene),
        "status" => {
            println!(
                "copy: {}\nsessions: {} Claude processes, Ghostty window {}",
                scene.demo_pid().as_deref().unwrap_or("none"),
                scene.demo_claudes().len(),
                if scene.state.window.is_empty() {
                    "none"
                } else {
                    &scene.state.window
                }
            );
            Ok(())
        }
        "down" => {
            for pid in scene.demo_claudes() {
                output("/bin/kill", args!["-TERM", pid])?;
            }
            if let Some(pid) = scene.demo_pid() {
                scene.driver(args!["quit", pid])?;
            }
            sleep(1.0);
            discard(&scene.support, &scene.home)?;
            let state = scene.work.join("stage.env");
            if state.exists() {
                fs::remove_file(state).map_err(|e| e.to_string())?;
            }
            println!(
                "· down. Recordings and clips stay in {}",
                scene.work.display()
            );
            Ok(())
        }
        _ => Err("stage up|down|reset-settings|status".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_only_demo_sender_hooks() {
        let source = r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"AgentWatchSend old","timeout":3},{"command":"not selected"}]}]}}"#;
        let settings = demo_settings(source, Path::new("/demo path/sender")).unwrap();
        assert_eq!(
            settings["hooks"]["Stop"][0]["hooks"][0]["command"],
            "'/demo path/sender' --source claude --event Stop"
        );
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["timeout"], 3);
    }
}
