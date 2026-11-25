use super::{NAMES, Result, args, driver, output, sleep, wait};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Default, Debug, PartialEq)]
pub(super) struct State {
    pub demo: String,
    pub ghost: String,
    pub window: String,
    pub asker: String,
    pub ids: Vec<String>,
}

impl State {
    fn parse(text: &str) -> Self {
        let mut state = Self::default();
        for line in text.lines() {
            if let Some((key, v)) = line.split_once('=') {
                match key {
                    "DEMO_PID" => state.demo = v.into(),
                    "GHOSTTY_PID" => state.ghost = v.into(),
                    "SESSIONS_WID" => state.window = v.into(),
                    "ASKER" => state.asker = v.into(),
                    "IDS" => {
                        state.ids = v
                            .trim_start_matches('(')
                            .trim_end_matches(')')
                            .split_whitespace()
                            .map(str::to_owned)
                            .collect()
                    }
                    _ => {}
                }
            }
        }
        state
    }
    fn render(&self) -> String {
        format!(
            "DEMO_PID={}\nGHOSTTY_PID={}\nSESSIONS_WID={}\nASKER={}\nIDS=({})\n",
            self.demo,
            self.ghost,
            self.window,
            self.asker,
            self.ids.join(" ")
        )
    }
}

pub(super) struct Scene {
    pub home: PathBuf,
    pub root: PathBuf,
    pub main: PathBuf,
    pub work: PathBuf,
    pub support: PathBuf,
    pub app: PathBuf,
    pub settings: PathBuf,
    pub bin: PathBuf,
    pub state: State,
}

pub(super) fn numbers<const N: usize>(text: &str) -> Result<[i32; N]> {
    text.split_whitespace()
        .take(N)
        .map(|n| {
            n.strip_suffix(".0")
                .unwrap_or(n)
                .parse::<i32>()
                .map_err(|e| format!("Invalid geometry {text}: {e}"))
        })
        .collect::<Result<Vec<_>>>()?
        .try_into()
        .map_err(|_| format!("Incomplete geometry: {text}"))
}

pub(super) fn applescript_string(v: &str) -> String {
    format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\""))
}

pub(super) fn pids(name: &str) -> Vec<String> {
    output("pgrep", &["-x", name])
        .unwrap_or_default()
        .lines()
        .filter(|p| p.parse::<u32>().is_ok_and(|pid| pid > 1))
        .map(str::to_owned)
        .collect()
}

impl Scene {
    pub fn load(root: PathBuf, home: PathBuf) -> Result<Self> {
        let work = home.join("Library/Caches/agent-watch-media");
        let support = home.join("Library/Caches/aw-demo");
        fs::create_dir_all(&work).map_err(|e| e.to_string())?;
        // Measured on Claude Code 2.1.293: IS_DEMO skips the project trust dialog without saving trust; use the trusted main checkout.
        let common = PathBuf::from(output(
            "git",
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        )?);
        let state = match fs::read_to_string(work.join("stage.env")) {
            Ok(text) => State::parse(&text),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => State::default(),
            Err(e) => return Err(e.to_string()),
        };
        Ok(Self {
            bin: driver(&root, &work)?,
            main: common.parent().ok_or("No main checkout")?.to_owned(),
            root,
            home,
            app: work.join("AgentWatch.app"),
            settings: work.join("demo-settings.json"),
            work,
            support,
            state,
        })
    }
    pub fn scripts(&self) -> PathBuf {
        self.root.join(".claude/skills/readme-media/scripts")
    }
    pub fn save(&self) -> Result {
        let tmp = self.work.join(format!("stage.{}.tmp", std::process::id()));
        fs::write(&tmp, self.state.render())
            .and_then(|()| fs::rename(tmp, self.work.join("stage.env")))
            .map_err(|e| e.to_string())
    }
    pub fn driver(&self, args: &[String]) -> Result<String> {
        output(&self.bin, args)
    }
    pub fn ax(&self, command: &str, args: &[String]) -> Result<String> {
        let mut all = vec!["ax".to_owned(), command.into(), self.state.demo.clone()];
        all.extend_from_slice(args);
        self.driver(&all)
    }
    pub fn screen(&self) -> Result<[i32; 4]> {
        numbers(&self.driver(args!["screen"])?)
    }
    pub fn find(&self, kind: &str, name: &str) -> Result<[i32; 6]> {
        numbers(&self.ax(kind, args![name])?)
    }
    pub fn windows(&self) -> Result<Vec<([i32; 4], String)>> {
        self.ax("windows", &[])?
            .lines()
            .map(|line| {
                Ok((
                    numbers(line)?,
                    line.split_whitespace()
                        .skip(4)
                        .collect::<Vec<_>>()
                        .join(" "),
                ))
            })
            .collect()
    }
    pub fn widget(&self) -> Result<[i32; 4]> {
        self.windows()?
            .into_iter()
            .find(|(_, s)| s.is_empty())
            .map(|(rect, _)| rect)
            .ok_or("The widget is not visible".into())
    }
    pub fn settings_window(&self) -> Result<([i32; 4], String)> {
        self.windows()?
            .into_iter()
            .find(|(_, s)| !s.is_empty())
            .ok_or("No settings window".into())
    }
    pub fn show_widget(&self, visible: bool) -> Result {
        if self.widget().is_ok() != visible {
            self.ax("press", args!["toggleWidget"])?;
            sleep(0.6);
        }
        Ok(())
    }
    pub fn place_widget(&self, x: i32, y: i32) -> Result {
        let [_, _, w, h] = self.widget()?;
        self.ax("move", args!["-", x, y, w, h])?;
        Ok(())
    }
    pub fn window_title(&self) -> Result<String> {
        output(
            "osascript",
            args![
                "-e",
                format!(
                    "tell application \"Ghostty\" to get name of (first window whose id is {})",
                    applescript_string(&self.state.window)
                )
            ],
        )
    }
    pub fn place_sessions(&self, x: i32, y: i32, w: i32, h: i32) -> Result {
        self.driver(args![
            "ax",
            "move",
            self.state.ghost,
            self.window_title()?,
            x,
            y,
            w,
            h
        ])?;
        Ok(())
    }
    pub fn tab(&self, name: &str, action: &str, text: &str) -> Result {
        let script = format!(
            "on run argv\ntell application \"Ghostty\"\nset w to first window whose id is (item 1 of argv)\nset theTab to first tab of w whose name ends with (item 2 of argv)\nset t to terminal 1 of theTab\n{action}\nend tell\nend run"
        );
        let args = args!["-e", script, self.state.window, name, text];
        // Measured on Claude Code 2.1.294: a starting session can temporarily lose its tab title even after all three titles appeared.
        for _ in 0..20 {
            if output("osascript", args).is_ok() {
                return Ok(());
            }
            sleep(0.5);
        }
        output("osascript", args).map(|_| ())
    }
    pub fn say(&self, name: &str, text: &str) -> Result {
        self.tab(
            name,
            "input text (item 3 of argv) to t\ndelay 0.5\nsend key \"enter\" to t",
            text,
        )
    }
    pub fn press(&self, name: &str, key: &str) -> Result {
        self.tab(name, "send key (item 3 of argv) to t", key)
    }
    pub fn select(&self, name: &str) -> Result {
        self.tab(name, "select tab theTab\nactivate window w", "")
    }
    pub fn open_terminal(&self) -> Result<String> {
        let main = applescript_string(&self.main.to_string_lossy());
        let support = applescript_string(&format!(
            "AGENT_WATCH_SUPPORT_DIR={}",
            self.support.display()
        ));
        output(
            "osascript",
            args![
                "-e",
                format!(
                    "tell application \"Ghostty\"\nset w to new window with configuration {{initial working directory:{main}, font size:14, environment variables:{{{support}, \"IS_DEMO=1\"}}}}\nactivate window w\nreturn id of w\nend tell"
                )
            ],
        )
    }
    pub fn demo_pid(&self) -> Option<String> {
        let path = self.app.join("Contents/MacOS/AgentWatch");
        pids("AgentWatch").into_iter().find(|p| {
            output("ps", &["-p", p, "-o", "command="])
                .is_ok_and(|cmd| Path::new(cmd.trim()) == path)
        })
    }
    pub fn demo_claudes(&self) -> Vec<String> {
        let setting = format!("--settings {}", self.settings.display());
        pids("claude")
            .into_iter()
            .filter(|pid| {
                output("ps", &["-p", pid, "-o", "args="]).is_ok_and(|cmd| cmd.contains(&setting))
            })
            .collect()
    }
    pub fn start_copy(&mut self) -> Result {
        output(
            "open",
            args![
                "-n",
                "--env",
                format!("AGENT_WATCH_SUPPORT_DIR={}", self.support.display()),
                self.app.display()
            ],
        )?;
        for _ in 0..40 {
            if let Some(pid) = self.demo_pid() {
                self.state.demo = pid;
                if self.icon().is_ok() {
                    return Ok(());
                }
            }
            sleep(0.25);
        }
        Err("The demo copy did not put its icon in the menu bar".into())
    }
    pub fn dismiss(&self) -> Result {
        let args: Vec<_> = NAMES.iter().map(|n| n.to_string()).collect();
        self.ax("dismiss", &args).map(|_| ())
    }
    pub fn icon(&self) -> Result<(i32, i32)> {
        self.driver(args!["bar"])?
            .lines()
            .find(|line| line.split_whitespace().nth(2) == Some(self.state.demo.as_str()))
            .and_then(|line| numbers::<2>(line).ok())
            .map(|[x, w]| (x, w))
            .ok_or("The demo menu bar icon is not visible".into())
    }
    fn events(&self, mut visit: impl FnMut(&str, &str)) {
        use std::io::{BufRead, BufReader};
        let Ok(log) = fs::File::open(self.support.join("AgentWatch/event-debug.log")) else {
            return;
        };
        let mut reader = BufReader::new(log);
        let mut line = String::new();
        loop {
            line.clear();
            if !reader.read_line(&mut line).is_ok_and(|n| n > 0) {
                break;
            }
            let mut parts = line.split(" · ").skip(1);
            if let (Some(session), Some(event)) = (
                parts.next(),
                parts
                    .next()
                    .and_then(|words| words.split_whitespace().next()),
            ) {
                visit(session, event);
            }
        }
    }
    pub fn count(&self, event: &str, id: &str) -> usize {
        let mut count = 0;
        self.events(|session, name| {
            if name == event && (id.is_empty() || session == id) {
                count += 1;
            }
        });
        count
    }
    pub fn wait_event(&self, event: &str, before: usize, seconds: usize, id: &str) -> bool {
        wait(|| self.count(event, id) > before, seconds * 4, 0.25)
    }
    pub fn require_event(&self, event: &str, before: usize, seconds: usize, id: &str) -> Result {
        if self.wait_event(event, before, seconds, id) {
            Ok(())
        } else {
            Err(format!("Timed out waiting for {event} ({id})"))
        }
    }
    pub fn last_id(&self, event: &str) -> Result<String> {
        let mut last = String::new();
        self.events(|session, name| {
            if name == event {
                session.clone_into(&mut last);
            }
        });
        if last.is_empty() {
            Err(format!("No {event} event"))
        } else {
            Ok(last)
        }
    }
    pub fn last_turn(&self, id: &str) -> String {
        let mut last = String::new();
        self.events(|session, event| {
            if session == id
                && matches!(event, "turnStarted" | "userInputRequired" | "turnCompleted")
            {
                event.clone_into(&mut last);
            }
        });
        last
    }
    pub fn live(&self) -> Vec<usize> {
        self.state
            .ids
            .iter()
            .enumerate()
            .filter_map(|(i, id)| (self.count("sessionEnded", id) == 0).then_some(i))
            .collect()
    }
    pub fn end_others(&self) -> Result {
        let ended = self.count("sessionEnded", "");
        let mut sent = 0;
        for i in self.live().into_iter().filter(|i| *i != 0) {
            self.say(NAMES[i], "/exit")?;
            sent += 1;
        }
        if wait(|| self.count("sessionEnded", "") >= ended + sent, 120, 0.25) {
            Ok(())
        } else {
            Err("Other demo sessions did not end".into())
        }
    }
    pub fn ordered_rows(&self, indices: &[usize]) -> Result<Vec<(i32, usize)>> {
        let mut rows = vec![];
        for &i in indices {
            rows.push((self.find("find", NAMES[i])?[1], i));
        }
        rows.sort();
        Ok(rows)
    }
    pub fn open_settings(&self, page: &str) -> Result {
        let bar = self.screen()?[1];
        let top = bar + 12;
        self.place_sessions(330, top, 806, 704 - top)?;
        self.show_widget(true)?;
        if self.settings_window().is_err() {
            self.ax("press", args!["showWidgetSettings"])?;
            sleep(1.5);
        }
        let (_, title) = self.settings_window()?;
        self.ax("move", args![title, 16, top, 760, 704 - top])?;
        let r = self.find("find", page)?;
        self.driver(args!["glide", r[0], r[1], "click"])?;
        self.place_widget(796, bar + 16)?;
        self.driver(args!["activate", self.state.demo])?;
        self.driver(args!["glide", 980, 640]).map(|_| ())
    }
    // Measured on macOS 15.7.7 in Tart: the first click occasionally initialized menus without opening one; warm it off camera.
    pub fn warm_menu(&self, x: i32, bar: i32, half: i32) -> Result {
        for _ in 0..2 {
            self.driver(args!["glide", x, bar / 2, "click"])?;
            let opened = wait(
                || {
                    self.find("find", "Quit Agent Watch")
                        .is_ok_and(|r| r[1] < half)
                },
                30,
                0.1,
            );
            self.driver(args!["key", 53])?;
            sleep(0.5);
            if opened {
                return Ok(());
            }
        }
        Err("The menu did not open".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn existing_stage_file_roundtrips() {
        let text = "DEMO_PID=42\nGHOSTTY_PID=43\nSESSIONS_WID=win-1\nASKER=id_1\nIDS=(id_1 id_2)\n";
        assert_eq!(State::parse(text).render(), text);
    }
}
