use super::super::recording::Take;
use super::super::scene::{Scene, pids};
use super::super::{Result, args, discard, output, sleep, wait};
use std::{fs, io::Write};

pub(super) fn run(s: &mut Scene) -> Result {
    if output("sysctl", &["-n", "kern.hv_vmm_present"]).as_deref() != Ok("1") {
        return Err(
            "The setup take runs only in the recording VM: it ends Claude and quits Ghostty".into(),
        );
    }
    let plugin = s.home.join(".claude/skills/agent-watch");
    if plugin.exists()
        || !pids("AgentWatch").is_empty()
        || !s.driver(args!["onscreen"])?.is_empty()
        || !s.app.is_dir()
    {
        return Err(
            "Setup needs an empty desktop, a prebuilt demo app, and a fresh Claude profile".into(),
        );
    }
    let stage = super::full(s)?;
    discard(&s.support, &s.home)?;
    let state = s.work.join("stage.env");
    if state.exists() {
        fs::remove_file(state).map_err(|e| e.to_string())?;
    }
    s.state = Default::default();
    // Measured on macOS 15.7.7: the centred settings window covers y=59–619; the demo terminal should align with its lower edge.
    let config = s
        .home
        .join("Library/Application Support/com.mitchellh.ghostty/config");
    fs::OpenOptions::new().create(true).append(true).open(config).and_then(|mut f|f.write_all(b"\nwindow-position-x = 330\nwindow-position-y = 299\nwindow-width = 80\nwindow-height = 14\n")).map_err(|e|e.to_string())?;
    s.driver(args!["glide", 1060, 680])?;
    sleep(1.0);
    let take = Take::begin(s, "setup", stage)?;
    sleep(1.0);
    take.mark("launch")?;
    s.start_copy()?;
    if !wait(|| s.widget().is_ok(), 20, 0.25) {
        return Err("The widget did not show".into());
    }
    // Measured on macOS 15.7.7 in Tart: finding a button in the Accessibility tree took about 1.5 seconds, so pauses before clicks are short.
    take.mark("widget")?;
    for (delay, title, label) in [
        (0.8, "Connect Agent", "connect"),
        (0.3, "Set Up Claude Code", "choose"),
        (0.3, "Install Connection", "install"),
    ] {
        sleep(delay);
        take.click(s, "findc", title, label)?;
    }
    if !wait(|| plugin.join("hooks/hooks.json").is_file(), 20, 0.25) {
        return Err("The guide did not install the hooks".into());
    }
    sleep(0.3);
    take.click(s, "findc", "Continue", "continue")?;
    sleep(0.3);
    s.driver(args!["glide", 1060, 560])?;
    let before = s.count("sessionStarted", "");
    sleep(1.2);
    take.mark("terminal")?;
    s.open_terminal()?;
    sleep(1.2);
    take.mark("claude")?;
    s.driver(args!["type", "claude"])?;
    sleep(0.3);
    s.driver(args!["key", 36])?;
    s.require_event("sessionStarted", before, 30, "")?;
    take.mark("started")?;
    sleep(1.5);
    let ([x, y, w, _], _) = s.settings_window()?;
    take.glide_click(s, x + w * 2 / 3, y + 12)?;
    take.mark("front")?;
    let ready = wait(|| s.find("findc", "has reported").is_ok(), 20, 0.25);
    take.mark(if ready { "ready" } else { "ready-timeout" })?;
    sleep(2.6);
    take.finish()?;
    for pid in pids("claude") {
        output("/bin/kill", args!["-TERM", pid])?;
    }
    sleep(1.0);
    for pid in pids("ghostty") {
        s.driver(args!["quit", pid])?;
    }
    s.driver(args!["quit", s.state.demo])?;
    Ok(())
}
