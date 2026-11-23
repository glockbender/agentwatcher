#![forbid(unsafe_code)]

mod confirmation;
mod domain;
mod git;
mod hook;
mod process;
#[cfg(feature = "mcp-fixture")]
mod protocol;
mod push;
mod window;

fn push_once(request: &str) -> Result<(), String> {
    let args: domain::Arguments = serde_json::from_str(request)
        .map_err(|_| "Expected one JSON object containing valid push arguments.")?;
    let cancel = process::Cancellation::for_command()?;
    let result = push::execute(&args, &cancel, true, |form, deadline| {
        window::confirm(form, &cancel, deadline)
    })?;
    // The reader may already be gone when cancellation came from closing the chat.
    std::io::Write::write_fmt(&mut std::io::stdout().lock(), format_args!("{result}\n"))
        .map_err(|_| "The caller stopped listening.")?;
    if result["status"] == "completed" {
        Ok(())
    } else {
        Err("The push did not complete.".into())
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [cmd, arguments @ ..] if cmd == "hook" => hook::run(arguments),
        [cmd, request] if cmd == "push" => push_once(request),
        #[cfg(feature = "mcp-fixture")]
        [] => protocol::run(!cfg!(target_os = "macos")),
        #[cfg(feature = "mcp-fixture")]
        [flag] if flag == "--mcp-forms" => protocol::run(!cfg!(target_os = "macos")),
        #[cfg(feature = "mcp-fixture")]
        [flag] if flag == "--client-forms" => protocol::run(true),
        [flag] if flag == "--version" => {
            println!("agent-watch-git {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        [flag, request] if flag == "--confirmation-window" => {
            window::show(request).map(|answer| println!("{answer}"))
        }
        _ => Err("Usage: agent-watch-git push <JSON object> | --version".into()),
    };
    if let Err(message) = result {
        eprintln!("{message}");
        std::process::exit(1);
    }
}
