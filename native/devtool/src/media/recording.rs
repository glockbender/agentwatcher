//! Own the recorder until its movie index is written, including failed takes.
use super::scene::{Scene, numbers, pids};
use super::{Result, args, now, output, sleep, wait};
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub(super) struct Take {
    marks: PathBuf,
    movie: PathBuf,
    pub rect: [i32; 4],
    t0: f64,
    child: Arc<Mutex<Option<Child>>>,
    stop: Arc<AtomicBool>,
    sampler: Option<JoinHandle<()>>,
    signals: Vec<signal_hook::SigId>,
    finished: bool,
}

fn append(path: &Path, line: &str) -> Result {
    let mut bytes = line.as_bytes().to_vec();
    bytes.push(b'\n');
    OpenOptions::new()
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(&bytes))
        .map_err(|e| format!("{}: {e}", path.display()))
}

fn stop_child(child: &Mutex<Option<Child>>, started: bool) -> Result {
    let mut lock = child.lock().map_err(|_| "Recorder lock unavailable")?;
    let Some(mut child) = lock.take() else {
        return Ok(());
    };
    if child.try_wait().map_err(|e| e.to_string())?.is_none() {
        let _ = output(
            "/bin/kill",
            args![if started { "-INT" } else { "-TERM" }, child.id()],
        );
    }
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            return if status.success() {
                Ok(())
            } else {
                Err(format!("Screen recorder exited with {status}"))
            };
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("Screen recorder did not finish writing the movie".into());
        }
        sleep(0.05);
    }
}

impl Take {
    pub fn begin(scene: &Scene, name: &str, rect: [i32; 4]) -> Result<Self> {
        let screen = scene.screen()?;
        let marks = scene.work.join(format!("{name}.marks"));
        let movie = scene.work.join(format!("{name}.mov"));
        let stamp = scene.work.join(format!("{name}.t0"));
        let bar = if output("sysctl", &["-n", "kern.hv_vmm_present"]).as_deref() == Ok("1") {
            0
        } else {
            screen[1]
        };
        fs::write(
            &marks,
            format!(
                "stage {} {} {} {}\nscale {}\nbar {bar}\n",
                rect[0], rect[1], rect[2], rect[3], screen[0]
            ),
        )
        .map_err(|e| e.to_string())?;
        if stamp.exists() {
            fs::remove_file(&stamp).map_err(|e| e.to_string())?;
        }
        if !scene.state.demo.is_empty() {
            scene.dismiss()?;
        }
        scene.driver(args!["clear-notifications"])?;
        let stderr = fs::File::create(scene.work.join(format!("{name}.record.log")))
            .map_err(|e| e.to_string())?;
        let interrupted = Arc::new(AtomicBool::new(false));
        let mut take = Self {
            marks,
            movie,
            rect,
            t0: 0.0,
            child: Arc::new(Mutex::new(None)),
            stop: Arc::new(AtomicBool::new(false)),
            sampler: None,
            signals: Vec::new(),
            finished: false,
        };
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            take.signals.push(
                signal_hook::flag::register(sig, interrupted.clone()).map_err(|e| e.to_string())?,
            );
        }
        let child = Command::new(&scene.bin)
            .arg("record")
            .arg(&take.movie)
            .arg(&stamp)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(stderr)
            .process_group(0)
            .spawn()
            .map_err(|e| e.to_string())?;
        *take.child.lock().map_err(|_| "Recorder unavailable")? = Some(child);
        if !wait(
            || {
                interrupted.load(Ordering::Acquire)
                    || fs::metadata(&stamp).is_ok_and(|m| m.len() > 0)
            },
            150,
            0.02,
        ) || interrupted.load(Ordering::Acquire)
        {
            return Err(format!("Recording did not start: {name}.record.log"));
        }
        take.t0 = super::read(&stamp)?
            .trim()
            .parse()
            .map_err(|_| "Invalid first frame time")?;
        let (stop, child, marks, bin, t0) = (
            take.stop.clone(),
            take.child.clone(),
            take.marks.clone(),
            scene.bin.clone(),
            take.t0,
        );
        let mut pid = scene.state.demo.clone();
        let app_path = scene.app.join("Contents/MacOS/AgentWatch");
        take.sampler = Some(std::thread::spawn(move || {
            let mut last = None;
            while !stop.load(Ordering::Acquire) {
                if interrupted.load(Ordering::Acquire) {
                    let _ = stop_child(&child, true);
                    let _ = append(&marks, "failed");
                    std::process::exit(1);
                }
                if pid.is_empty() {
                    pid = pids("AgentWatch")
                        .into_iter()
                        .find(|p| {
                            output("ps", &["-p", p, "-o", "command="])
                                .is_ok_and(|s| Path::new(s.trim()) == app_path)
                        })
                        .unwrap_or_default();
                }
                let frame = if pid.is_empty() {
                    String::new()
                } else {
                    output(&bin, &["bar"])
                        .unwrap_or_default()
                        .lines()
                        .find(|l| l.split_whitespace().nth(2) == Some(&pid))
                        .map(|l| l.split_whitespace().take(2).collect::<Vec<_>>().join(" "))
                        .unwrap_or_default()
                };
                if last.as_ref() != Some(&frame) {
                    let _ = append(&marks, &format!("icon {:.3} {frame}", now() - t0));
                    last = Some(frame);
                }
                sleep(0.1);
            }
        }));
        // Measured on macOS 15.3: the recording indicator can push the icon behind the notch about 11 seconds into a take.
        // Measured on macOS 15.7.7 in Tart: the icon stayed in place throughout a 75-second take on a notchless display.
        if rect[1] < screen[1] && screen[1] > 30 && !scene.state.demo.is_empty() {
            while now() - take.t0 < 15.0 {
                let (x, _) = scene
                    .icon()
                    .map_err(|_| "The recording indicator pushed the icon behind the notch")?;
                if scene.driver(args!["bar"])?.lines().any(|l| {
                    l.split_whitespace().nth(3) == Some("Control")
                        && numbers::<1>(l).is_ok_and(|[left]| left < x)
                }) {
                    break;
                }
                sleep(0.25);
            }
        }
        println!("· recording {name}");
        Ok(take)
    }
    pub fn mark(&self, label: &str) -> Result {
        append(&self.marks, &format!("@ {:.3} {label}", now() - self.t0))
    }
    fn tap(&self, scene: &Scene, command: &[String], x: i32, y: i32) -> Result {
        let time: f64 = scene
            .driver(command)?
            .trim()
            .parse()
            .map_err(|_| "Invalid mouse press time")?;
        append(&self.marks, &format!("tap {:.3} {x} {y}", time - self.t0))
    }
    pub fn glide_click(&self, scene: &Scene, x: i32, y: i32) -> Result {
        self.tap(scene, args!["glide", x, y, "click"], x, y)
    }
    pub fn drag(&self, scene: &Scene, x: i32, y: i32, x2: i32, y2: i32) -> Result {
        self.tap(scene, args!["drag", x, y, x2, y2], x, y)
    }
    pub fn click(&self, scene: &Scene, kind: &str, name: &str, label: &str) -> Result {
        let [x, y, w, h] = self.rect;
        // Measured on macOS 15.7.7: each Accessibility lookup took about 0.1 seconds; an opening menu initially reports off-stage coordinates.
        for _ in 0..20 {
            if let Ok([cx, cy, l, t, rw, rh]) = scene.find(kind, name)
                && (x..=x + w).contains(&cx)
                && (y..=y + h).contains(&cy)
            {
                self.glide_click(scene, cx, cy)?;
                return self.mark(&format!("{label} {l} {t} {rw} {rh}"));
            }
            sleep(0.1);
        }
        Err(format!("No element on the stage: {name}"))
    }
    pub fn finish(mut self) -> Result {
        self.end(false)?;
        let size = output(
            "ffprobe",
            args![
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height",
                "-of",
                "csv=p=0",
                self.movie.display()
            ],
        );
        let size = match size {
            Ok(size) => size,
            Err(error) => {
                append(&self.marks, "failed")?;
                return Err(error);
            }
        };
        println!("· {} {size}", self.movie.display());
        for line in super::read(&self.marks)?
            .lines()
            .filter(|l| l.starts_with('@'))
        {
            println!("{line}");
        }
        Ok(())
    }
    fn end(&mut self, failed: bool) -> Result {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.sampler.take() {
            let _ = thread.join();
        }
        let result = stop_child(&self.child, self.t0 > 0.0);
        for id in self.signals.drain(..) {
            signal_hook::low_level::unregister(id);
        }
        if failed || result.is_err() {
            append(&self.marks, "failed")?;
        }
        result
    }
}

impl Drop for Take {
    fn drop(&mut self) {
        if let Err(e) = self.end(true) {
            eprintln!("{e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_take_marks_the_file_and_reaps_its_recorder() {
        let marks = std::env::temp_dir().join(format!(
            "aw-take-failed-{}-{}.marks",
            std::process::id(),
            now()
        ));
        fs::write(&marks, "stage 0 0 16 16\n").unwrap();
        let child = Command::new("/bin/sleep")
            .arg("60")
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();
        let take = Take {
            marks: marks.clone(),
            movie: marks.with_extension("mov"),
            rect: [0, 0, 16, 16],
            t0: now(),
            child: Arc::new(Mutex::new(Some(child))),
            stop: Arc::new(AtomicBool::new(false)),
            sampler: None,
            signals: vec![],
            finished: false,
        };
        drop(take);
        assert_eq!(
            fs::read_to_string(&marks).unwrap(),
            "stage 0 0 16 16\nfailed\n"
        );
        assert!(
            !Command::new("/bin/kill")
                .args(["-0", &pid.to_string()])
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        fs::remove_file(&marks).unwrap();
    }
}
