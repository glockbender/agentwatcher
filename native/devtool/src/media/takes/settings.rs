use super::super::recording::Take;
use super::super::scene::{Scene, numbers};
use super::super::{NAMES, Result, args, discard, output, sleep, wait};
use super::full;
use std::fs;

pub(super) fn order(s: &Scene) -> Result {
    let stage = full(s)?;
    s.open_settings("Widget")?;
    let closing = s
        .live()
        .into_iter()
        .max()
        .filter(|&i| i >= 3)
        .ok_or("No demo session left to close")?;
    let ended = s.count("sessionEnded", "");
    s.say(NAMES[closing], "/exit")?;
    s.require_event("sessionEnded", ended, 30, "")?;
    let rows = s.ordered_rows(&s.live())?;
    if rows.len() < 3 {
        return Err("Order needs three open sessions".into());
    }
    let asker = NAMES[rows.last().unwrap().1];
    sleep(1.0);
    let take = Take::begin(s, "order", stage)?;
    sleep(0.8);
    take.mark("tasks")?;
    for (_, i) in &rows[..2] {
        s.say(NAMES[*i],"Without using any tools, write a 300-word note on why the app never polls when no session is active.")?;
    }
    s.say(
        asker,
        "Run `git --version` and tell me the version in one line.",
    )?;
    for (delay, text, label) in [
        (4.0, "Order,", "order"),
        (1.6, "By state", "state"),
        (3.0, "By blocks", "blocks"),
    ] {
        sleep(delay);
        take.click(s, "findc", text, label)?;
    }
    sleep(1.2);
    let ([x, y, w, h], _) = s.settings_window()?;
    s.driver(args!["glide", x + w / 2, y + h / 2])?;
    s.driver(args!["scroll", 300, "0.8"])?;
    take.mark("scrolled")?;
    sleep(0.8);
    let from = numbers::<6>(&s.ax("findw", args!["Order", "Closed"])?)?;
    let to = numbers::<6>(&s.ax("findw", args!["Order", "Active"])?)?;
    take.drag(s, from[0], from[1], to[0], to[3] - 3)?;
    take.mark("drag")?;
    sleep(0.6);
    s.driver(args!["glide", 980, 640])?;
    sleep(2.4);
    take.finish()?;
    s.press(asker, "enter")
}

pub(super) fn rows(s: &Scene) -> Result {
    let stage = full(s)?;
    s.open_settings("Widget")?;
    sleep(1.0);
    let take = Take::begin(s, "rows", stage)?;
    sleep(0.8);
    take.click(s, "findc", "parts", "rows")?;
    for part in ["Elapsed", "Agent", "Counters", "Context"] {
        sleep(0.9);
        take.click(s, "find", part, &format!("off-{}", part.to_lowercase()))?;
    }
    sleep(1.4);
    for part in ["Branch", "Model"] {
        sleep(1.0);
        take.click(s, "find", part, &format!("on-{}", part.to_lowercase()))?;
    }
    sleep(1.2);
    let [x, top, w, h] = s.widget()?;
    let y = top + h / 2;
    sleep(0.4);
    take.drag(s, x + 2, y, x - 198, y)?;
    take.mark("wider")?;
    s.driver(args!["glide", x - 240, y])?;
    sleep(1.8);
    take.drag(s, x - 198, y, x + 2, y)?;
    take.mark("back")?;
    sleep(0.4);
    s.driver(args!["glide", 980, 640])?;
    sleep(1.6);
    if !s
        .windows()?
        .iter()
        .any(|(rect, title)| title.is_empty() && rect[0] + rect[2] == x + w && rect[2] == w)
    {
        return Err("The widget did not return to its original width".into());
    }
    take.finish()
}

pub(super) fn look(s: &Scene) -> Result {
    let stage = full(s)?;
    s.open_settings("Appearance")?;
    let asked = s.count("userInputRequired", &s.state.asker);
    sleep(1.0);
    let take = Take::begin(s, "look", stage)?;
    sleep(0.8);
    take.mark("tasks")?;
    s.say(NAMES[2],"Read docs/architecture.md with the Read tool, no commands, and explain it in about 600 words.")?;
    s.say(
        NAMES[0],
        "Run `task --list` and tell me in one line which task checks the documents.",
    )?;
    for (delay, kind, text, label) in [
        (2.0, "find", "Light", "light"),
        (1.8, "findc", "Default", "theme-menu"),
        (0.9, "findm", "Bubblegum", "theme"),
        (2.4, "findc", "100%", "size-menu"),
        (0.9, "findm", "125%", "bigger"),
        (2.2, "findc", "125%", "size-menu-2"),
        (0.9, "findm", "75%", "smaller"),
        (2.2, "findc", "75%", "size-menu-3"),
        (0.9, "findm", "100%", "size-back"),
        (2.0, "findc", "Edit Theme", "edit"),
    ] {
        sleep(delay);
        take.click(s, kind, text, label)?;
    }
    sleep(1.0);
    s.driver(args!["glide", 400, 400])?;
    s.driver(args!["scroll", 300, "0.8"])?;
    take.mark("scrolled")?;
    s.require_event("userInputRequired", asked, 30, &s.state.asker)?;
    let find = |name: &str| numbers::<6>(&s.ax("findw", args!["Edit Theme", name])?);
    let column = find("To color")?;
    let row = find("Waiting for you")?;
    sleep(0.6);
    take.glide_click(s, column[0], row[1])?;
    take.mark("to-color")?;
    sleep(1.0);
    // Measured on macOS 15.7.7: red is 186 points right and 142 points down from the colour panel’s top left corner.
    let (panel, _) = s
        .windows()?
        .into_iter()
        .find(|(_, title)| title.ends_with("Colors"))
        .ok_or("The colour panel did not open")?;
    take.glide_click(s, panel[0] + 186, panel[1] + 142)?;
    take.mark("red")?;
    sleep(1.0);
    s.ax("close", args!["Colors"])?;
    let column = find("Full cycle")?;
    let row = find("Working")?;
    sleep(0.8);
    take.drag(s, column[2] + 41, row[1], column[2] + 10, row[1])?;
    take.mark("faster")?;
    sleep(0.6);
    s.driver(args!["glide", 980, 640])?;
    sleep(4.2);
    take.finish()?;
    s.press(NAMES[0], "enter")
}

pub(super) fn folders(s: &Scene) -> Result {
    let stage = full(s)?;
    if !s
        .home
        .join(".claude/skills/agent-watch/hooks/hooks.json")
        .is_file()
    {
        return Err("No installed Claude hooks; record the setup take first".into());
    }
    let guest = output("sysctl", &["-n", "kern.hv_vmm_present"]).as_deref() == Ok("1");
    for name in ["work", "personal"] {
        let folder = s.home.join(format!(".claude-{name}"));
        if folder.exists() && !guest {
            return Err(format!(
                "{} already exists on this Mac. Use a clean recording guest.",
                folder.display()
            ));
        }
        discard(&folder, &s.home)?;
        fs::create_dir(&folder).map_err(|e| e.to_string())?;
    }
    s.open_settings("Tooling")?;
    let (window, _) = s
        .windows()?
        .into_iter()
        .find(|(_, title)| title == "Tooling")
        .ok_or("No Tooling window")?;
    sleep(1.0);
    let take = Take::begin(s, "folders", stage)?;
    sleep(0.8);
    take.mark("tooling")?;
    for name in ["work", "personal"] {
        let folder = format!(".claude-{name}");
        let [cx, cy, x, y, w, h] = s.find("findc", "Add Folder")?;
        if cy >= window[1] + window[3] - 20 {
            return Err("Add Folder is below the window; the page needs scrolling".into());
        }
        sleep(0.4);
        take.glide_click(s, cx, cy)?;
        take.mark(&format!("add-{name} {x} {y} {w} {h}"))?;
        // Measured on macOS 15.7.7 in Tart: the folder dialog opened at home in column view with hidden folders visible.
        let open = || {
            s.windows()
                .is_ok_and(|ws| ws.iter().any(|(_, t)| t == "Open"))
        };
        if !wait(open, 40, 0.1) {
            return Err("The folder dialog did not open".into());
        }
        sleep(0.6);
        take.click(s, "find", &folder, &format!("pick-{name}"))?;
        sleep(0.4);
        take.click(s, "find", "Add", &format!("chosen-{name}"))?;
        if !wait(|| !open(), 40, 0.1) {
            return Err("The folder dialog stayed open".into());
        }
        sleep(0.8);
        take.click(s, "find", "Install", &format!("install-{name}"))?;
        if !wait(
            || {
                s.home
                    .join(&folder)
                    .join("skills/agent-watch/hooks/hooks.json")
                    .is_file()
            },
            20,
            0.25,
        ) {
            return Err(format!("No hooks installed in {folder}"));
        }
        take.mark(&format!("installed-{name}"))?;
        sleep(1.2);
    }
    sleep(0.4);
    s.driver(args!["glide", 980, 640])?;
    sleep(1.2);
    take.finish()
}
