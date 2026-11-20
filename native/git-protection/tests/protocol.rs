use std::process::Command;

#[test]
#[cfg(feature = "mcp-fixture")]
fn binary_serves_mcp_and_rejects_uninitialized_calls() {
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Write};
    use std::process::Stdio;
    let mut child = Command::new(env!("CARGO_BIN_EXE_agent-watch-git"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    for (request, expected) in [
        (
            json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
            "error",
        ),
        (
            json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{"form":{}}}}}),
            "result",
        ),
    ] {
        writeln!(input, "{request}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], request["id"]);
        assert!(response.get(expected).is_some());
    }
    drop(input);
    assert!(child.wait().unwrap().success());
}

#[test]
fn reports_embedded_source_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_agent-watch-git"))
        .arg("--version")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap().trim(),
        concat!("agent-watch-git ", env!("CARGO_PKG_VERSION"))
    );
}

#[cfg(target_os = "macos")]
mod accessory_app {
    use super::Command;
    use std::fs;

    #[test]
    #[ignore = "requires a macOS graphical session"]
    fn bundled_window_can_prepare_an_alert_without_changing_activation_policy() {
        let root = super::support::TestDirectory::new("accessory-app");
        let contents = root.path().join("AgentWatch.app/Contents");
        fs::create_dir_all(contents.join("MacOS")).unwrap();
        fs::write(
            contents.join("Info.plist"),
            r#"<?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>local.agent-watch.test</string>
            <key>CFBundleExecutable</key><string>AgentWatch</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>LSUIElement</key><true/>
            </dict></plist>"#,
        )
        .unwrap();
        let executable = contents.join("MacOS/AgentWatchGit");
        fs::copy(env!("CARGO_BIN_EXE_agent-watch-git"), &executable).unwrap();
        // Invalid text reaches alert construction but can never present an approval.
        let reply = Command::new(executable)
            .args([
                "--confirmation-window",
                r#"{"message":"probe","schema":{}}"#,
            ])
            .output()
            .unwrap();
        assert!(!reply.status.success());
        assert_eq!(
            String::from_utf8(reply.stderr).unwrap().lines().last(),
            Some("Invalid window text.")
        );
    }
}

#[cfg(target_os = "macos")]
mod support;
