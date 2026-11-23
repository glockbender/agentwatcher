fn main() -> std::process::ExitCode {
    agent_watch_git_e2e::run(&std::env::args().skip(1).collect::<Vec<_>>())
}
