use super::super::recording::Take;
use super::super::scene::Scene;
use super::super::{NAMES, Result, args, sleep};
use super::{finish_answer, full, turn};

const LONG_TASK: &str =
    "Read docs/architecture.md with the Read tool, no commands, and explain it in about 600 words.";

pub(super) fn start(s: &Scene) -> Result {
    let stage = full(s)?;
    let bar = s.screen()?[1];
    let top = bar + 12;
    s.place_sessions(16, top, 1120, 704 - top)?;
    s.select(NAMES[2])?;
    s.show_widget(true)?;
    s.place_widget(796, bar + 16)?;
    s.driver(args!["glide", 600, 600])?;
    sleep(1.0);
    turn(
        s,
        "userInputRequired",
        "Check the task list is not waiting for input",
    )?;
    let [_, wy, _, wh] = s.widget()?;
    let [cx, cy, x, y, w, h] = s.find("find", NAMES[0])?;
    let below = y + h - (wy + wh - 4);
    let need = if below > 0 { (below + 22) / 23 * 23 } else { 0 };
    let rows = s.ordered_rows(&(0..NAMES.len()).collect::<Vec<_>>())?;
    let waiting = rows
        .iter()
        .position(|(_, i)| *i == 0)
        .ok_or("No waiting row")?;
    let (slot, count) = match waiting {
        4..=6 => (0, 3),
        0..=2 => (3, 3),
        _ => (0, 2),
    };
    let before = s.count("turnCompleted", &s.state.asker);
    let take = Take::begin(s, "start", stage)?;
    sleep(2.0);
    s.driver(args!["glide", x + w - 15, rows[slot].0])?;
    take.mark("scroll")?;
    s.driver(args!["scroll", count * 23, "1.0", "back"])?;
    if need > 0 {
        s.driver(args!["scroll", need, "0.3"])?;
    }
    sleep(0.3);
    let started = s.count("turnStarted", "");
    take.mark("long-task")?;
    s.say(NAMES[2], LONG_TASK)?;
    s.require_event("turnStarted", started, 5, "")?;
    let explaining = s.last_id("turnStarted")?;
    let explained = s.count("turnCompleted", &explaining);
    sleep(1.2);
    s.driver(args!["glide", cx, cy - need])?;
    take.mark("hover")?;
    sleep(2.4);
    take.glide_click(s, cx, cy - need)?;
    take.mark(&format!("click {x} {} {w} {h}", y - need))?;
    sleep(0.4);
    s.driver(args!["glide", 600, 600])?;
    sleep(1.8);
    take.mark("approve")?;
    s.press(NAMES[0], "enter")?;
    finish_answer(s, &take, before, &s.state.asker)?;
    sleep(4.5);
    take.finish()?;
    if !s.wait_event("turnCompleted", explained, 240, &explaining) {
        println!("· the long answer is still running");
    }
    Ok(())
}

pub(super) fn menu(s: &Scene) -> Result {
    let stage = full(s)?;
    let bar = s.screen()?[1];
    s.place_sessions(16, bar + 12, 1120, 692 - bar)?;
    s.select(NAMES[1])?;
    s.show_widget(false)?;
    let (x, w) = s.icon()?;
    let icon = x + w / 2;
    s.warm_menu(icon, bar, stage[3] / 2)?;
    s.driver(args!["glide", 760, 560])?;
    sleep(1.0);
    let take = Take::begin(s, "menu", stage)?;
    sleep(1.5);
    take.mark("long-task")?;
    s.say(NAMES[2],"Read docs/architecture.md again with the Read tool, no commands, and explain it in about 600 words.")?;
    sleep(2.5);
    let asked = s.count("userInputRequired", &s.state.asker);
    take.mark("ask")?;
    s.say(
        NAMES[0],
        "Run `task --list` and tell me in one line which task formats the Swift sources.",
    )?;
    s.require_event("userInputRequired", asked, 60, &s.state.asker)?;
    take.mark("waiting")?;
    let before = s.count("turnCompleted", &s.state.asker);
    sleep(3.5);
    take.glide_click(s, icon, bar / 2)?;
    take.mark("open-menu")?;
    sleep(1.6);
    take.click(s, "find", NAMES[0], "choose")?;
    sleep(0.5);
    s.driver(args!["glide", 800, 600])?;
    sleep(2.2);
    take.mark("approve")?;
    s.press(NAMES[0], "enter")?;
    finish_answer(s, &take, before, &s.state.asker)?;
    sleep(1.5);
    take.glide_click(s, icon, bar / 2)?;
    take.mark("reopen")?;
    sleep(2.8);
    take.mark("escape")?;
    s.driver(args!["key", 53])?;
    sleep(0.3);
    s.driver(args!["glide", 800, 600])?;
    sleep(1.2);
    take.finish()?;
    s.show_widget(true)
}

pub(super) fn icon(s: &Scene, counts: bool) -> Result {
    s.show_widget(false)?;
    s.end_others()?;
    if counts {
        s.ax("press", args!["showWidgetSettings"])?;
        sleep(1.5);
        for name in ["Menu Bar", "Counts"] {
            let r = s.find("find", name)?;
            s.driver(args!["glide", r[0], r[1], "click"])?;
            sleep(1.0);
        }
        s.ax("close", args!["Menu Bar"])?;
    }
    let top = s.screen()?[1] + 12;
    s.place_sessions(240, top, 896, 564 - top)?;
    s.select(NAMES[0])?;
    s.driver(args!["glide", 760, 330])?;
    sleep(1.0);
    turn(s, "turnCompleted", "Check the task list is not done")?;
    let take = Take::begin(
        s,
        if counts { "counts" } else { "icon" },
        [224, 0, 928, 580],
    )?;
    sleep(1.2);
    let asked = s.count("userInputRequired", &s.state.asker);
    take.mark("ask")?;
    let question = if counts {
        "which task sets up the Git hooks."
    } else {
        "which task redraws the README pictures."
    };
    s.say(
        NAMES[0],
        &format!("Run `task --list` and tell me in one line {question}"),
    )?;
    s.require_event("userInputRequired", asked, 60, &s.state.asker)?;
    take.mark("waiting")?;
    let before = s.count("turnCompleted", &s.state.asker);
    sleep(2.6);
    take.mark("approve")?;
    s.press(NAMES[0], "enter")?;
    finish_answer(s, &take, before, &s.state.asker)?;
    sleep(2.6);
    take.finish()
}

pub(super) fn fullscreen(s: &Scene) -> Result {
    let stage = full(s)?;
    s.show_widget(false)?;
    s.end_others()?;
    s.select(NAMES[0])?;
    let title = s.window_title()?;
    s.driver(args!["ax", "fullscreen", s.state.ghost, title, "on"])?;
    let result = (|| {
        sleep(3.0);
        s.driver(args!["glide", 700, 600])?;
        sleep(1.0);
        turn(s, "turnCompleted", "Check the task list is not done")?;
        let take = Take::begin(s, "fullscreen", stage)?;
        sleep(1.5);
        let asked = s.count("userInputRequired", &s.state.asker);
        take.mark("ask")?;
        s.say(
            NAMES[0],
            "Run `task --list` and tell me in one line which task builds the app bundle.",
        )?;
        s.require_event("userInputRequired", asked, 60, &s.state.asker)?;
        take.mark("waiting")?;
        let before = s.count("turnCompleted", &s.state.asker);
        sleep(3.0);
        s.driver(args!["glide", 850, 0])?;
        take.mark("bar")?;
        sleep(2.5);
        s.driver(args!["glide", 950, 400])?;
        take.mark("back")?;
        sleep(3.0);
        take.mark("approve")?;
        s.press(NAMES[0], "enter")?;
        finish_answer(s, &take, before, &s.state.asker)?;
        sleep(2.5);
        take.finish()
    })();
    let exit = s
        .driver(args!["ax", "fullscreen", s.state.ghost, NAMES[0], "off"])
        .map(|_| ());
    result.and(exit)
}
