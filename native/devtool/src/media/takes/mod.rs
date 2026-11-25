//! Camera marks and movement timings belong to individual clips; the clip editor consumes their names.
mod sessions;
mod settings;
mod setup;
use super::Result;
use super::recording::Take;
use super::scene::Scene;

pub(super) const NAMES: &[&str] = &[
    "start",
    "menu",
    "icon",
    "fullscreen",
    "rows",
    "order",
    "look",
    "folders",
    "setup",
];

fn full(scene: &Scene) -> Result<[i32; 4]> {
    let [_, _, w, h] = scene.screen()?;
    Ok([0, 0, w, h])
}
fn finish_answer(scene: &Scene, take: &Take, before: usize, id: &str) -> Result {
    take.mark(if scene.wait_event("turnCompleted", before, 60, id) {
        "done"
    } else {
        "done-timeout"
    })
}
fn turn(scene: &Scene, event: &str, why: &str) -> Result {
    if scene.last_turn(&scene.state.asker) == event {
        Ok(())
    } else {
        Err(why.into())
    }
}

pub(super) fn run(scene: &mut Scene, name: &str, counts: bool) -> Result {
    if name != "setup"
        && (scene.demo_pid().as_ref() != Some(&scene.state.demo)
            || scene.state.ids.len() != super::NAMES.len())
    {
        return Err("No running demo stage. Use stage up first.".into());
    }
    match name {
        "start" => sessions::start(scene),
        "menu" => sessions::menu(scene),
        "icon" => sessions::icon(scene, counts),
        "fullscreen" => sessions::fullscreen(scene),
        "order" => settings::order(scene),
        "rows" => settings::rows(scene),
        "look" => settings::look(scene),
        "folders" => settings::folders(scene),
        "setup" => setup::run(scene),
        _ => Err("Unknown media take".into()),
    }
}
