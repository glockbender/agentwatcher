//! Assemble published clips from the take's time marks and camera keys.
use super::frames::{FPS, Marks, name, number};
use super::{Result, args, driver, output, read};
use regex::Regex;
use std::fmt::Write;
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
};

struct Clip<'a> {
    name: &'a str,
    take: &'a str,
    start: &'a str,
    end: &'a str,
    width: u32,
    height: u32,
    keys: &'a str,
    fade: f64,
}

fn fields(line: &str) -> Vec<&str> {
    line.split('#')
        .next()
        .unwrap_or("")
        .split_whitespace()
        .collect()
}

impl<'a> Clip<'a> {
    fn parse(line: &'a str) -> Result<Option<Self>> {
        let parts = fields(line);
        if parts.is_empty() {
            return Ok(None);
        }
        let [id, take, start, end, w, h, keys, options @ ..] = parts.as_slice() else {
            return Err(format!("Invalid clip: {line}"));
        };
        let fade = match options {
            [] => 0.0,
            [value] => number(value.strip_prefix("fade=").ok_or("Expected fade=seconds")?)?,
            _ => return Err(format!("Invalid clip options: {line}")),
        };
        let size = |s: &str| {
            s.parse::<u32>()
                .ok()
                .filter(|n| *n > 0)
                .ok_or_else(|| format!("Invalid clip dimension: {s}"))
        };
        let key = Path::new(keys);
        if !key.starts_with("clips")
            || !key
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_)))
        {
            return Err(format!("Invalid camera file: {keys}"));
        }
        Ok(Some(Self {
            name: name(id)?,
            take: name(take)?,
            start,
            end,
            width: size(w)?,
            height: size(h)?,
            keys,
            fade,
        }))
    }

    fn render(&self, ctx: &Context) -> Result {
        let m = Marks::load(ctx.work, self.take)?;
        let start = m.at(self.start)?;
        let end = m.at(self.end)?;
        if end <= start {
            return Err(format!("{} ends before it starts", self.name));
        }
        let dir = ctx.work.join("frames").join(self.name);
        let keys = dir.join("keys.txt");
        let taps = dir.join("taps.txt");
        if let Some(bin) = &ctx.driver {
            fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            for path in files(&dir, "", ".png")? {
                fs::remove_file(path).map_err(|e| e.to_string())?;
            }
            let mut track = String::new();
            for line in read(&ctx.scripts.join(self.keys))?.lines() {
                let words = fields(line);
                if let Some((time, values)) = words.split_first() {
                    writeln!(
                        &mut track,
                        "{:.3} {}",
                        m.at(time)? - start,
                        values.join(" ")
                    )
                    .unwrap();
                }
            }
            fs::write(&keys, track).map_err(|e| e.to_string())?;
            let mut coords = String::new();
            for [t, x, y] in &m.taps {
                writeln!(
                    &mut coords,
                    "{:.3} {:.1} {:.1}",
                    t - start,
                    (x - m.stage[0]) * m.scale,
                    (y - m.stage[1]) * m.scale
                )
                .unwrap();
            }
            fs::write(&taps, coords).map_err(|e| e.to_string())?;
            output(
                "ffmpeg",
                args![
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-ss",
                    format!("{start:.3}"),
                    "-to",
                    format!("{end:.3}"),
                    "-i",
                    ctx.work.join(format!("{}.mov", self.take)).display(),
                    "-filter_complex",
                    m.filter(start, end)?,
                    "-map",
                    "[o]",
                    dir.join("s%04d.png").display()
                ],
            )?;
            output(
                bin,
                args![
                    "zoom",
                    dir.display(),
                    keys.display(),
                    dir.display(),
                    self.width,
                    self.height,
                    FPS,
                    taps.display()
                ],
            )?;
        }
        let frames = files(&dir, "f", ".png")?.len();
        if frames == 0 {
            return Err(format!("No rendered frames in {}", dir.display()));
        }
        let pattern = dir.join("f%04d.png");
        let base = vec![
            "-hide_banner".into(),
            "-loglevel".into(),
            "error".into(),
            "-framerate".into(),
            FPS.to_string(),
            "-i".into(),
            pattern.display().to_string(),
        ];
        let mut encoding = base.clone();
        if self.fade > 0. {
            encoding.extend_from_slice(args![
                "-vf",
                format!(
                    "fade=t=out:st={:.3}:d={}",
                    frames as f64 / f64::from(FPS) - self.fade,
                    self.fade
                )
            ]);
        }
        let clip = ctx.work.join(format!("{}.avif", self.name));
        let tmp = ctx
            .work
            .join(format!("{}.{}.avif.tmp", self.name, std::process::id()));
        encoding.extend_from_slice(args![
            "-c:v",
            "libsvtav1",
            "-crf",
            ctx.crf,
            "-preset",
            4,
            "-svtav1-params",
            "scm=1",
            "-pix_fmt",
            "yuv420p",
            "-f",
            "avif",
            "-y",
            tmp.display()
        ]);
        let encoded = output("ffmpeg", &encoding);
        if let Err(e) = encoded {
            let _ = fs::remove_file(tmp);
            return Err(e);
        }
        fs::rename(tmp, &clip).map_err(|e| e.to_string())?;
        println!(
            "{}: {} KB, {:.1} s",
            self.name,
            fs::metadata(&clip).map_err(|e| e.to_string())?.len() / 1024,
            end - start
        );
        if ctx.sheet {
            let mut sheet = base;
            sheet.extend_from_slice(args![
                "-vf",
                format!(
                    "select='not(mod(n\\,12))',scale=480:-2,tile=4x{}:padding=4:color=white",
                    frames.div_ceil(48)
                ),
                "-frames:v",
                1,
                "-y",
                ctx.work.join(format!("{}-sheet.png", self.name)).display()
            ]);
            output("ffmpeg", &sheet)?;
        }
        if ctx.publish {
            let dest = ctx.root.join("docs/images").join(clip.file_name().unwrap());
            let temp = dest.with_extension(format!("avif.new-{}", std::process::id()));
            fs::copy(&clip, &temp)
                .and_then(|_| fs::rename(temp, &dest))
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

struct Context<'a> {
    root: &'a Path,
    work: &'a Path,
    scripts: PathBuf,
    sheet: bool,
    publish: bool,
    driver: Option<PathBuf>,
    crf: String,
}

fn files(dir: &Path, prefix: &str, suffix: &str) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for e in fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))? {
        let path = e.map_err(|e| e.to_string())?.path();
        if path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with(prefix) && n.ends_with(suffix))
        {
            out.push(path);
        }
    }
    Ok(out)
}

fn check_published(root: &Path, listed: &BTreeSet<&str>) -> Result {
    let images = root.join("docs/images");
    let doc = read(&root.join("README.md"))?;
    let links = Regex::new(r"docs/images/(clip-[\w-]+)\.avif").unwrap();
    let readme: BTreeSet<&str> = links
        .captures_iter(&doc)
        .map(|c| c.get(1).unwrap().as_str())
        .collect();
    let paths = files(&images, "clip-", ".avif")?;
    let present = paths
        .iter()
        .filter_map(|p| p.file_stem()?.to_str())
        .collect::<BTreeSet<_>>();
    for (clips, message) in [
        (
            present.difference(listed),
            "in docs/images but not in clips.txt: git rm it",
        ),
        (
            listed.difference(&readme),
            "in clips.txt but not in the README",
        ),
        (
            readme.difference(listed),
            "in the README but not in clips.txt",
        ),
    ] {
        for clip in clips {
            println!("{clip}: {message}");
        }
    }
    let mut total = 0;
    for clip in listed.intersection(&present) {
        total += fs::metadata(images.join(format!("{clip}.avif")))
            .map_err(|e| e.to_string())?
            .len();
    }
    println!(
        "all {} clips in docs/images: {} KB",
        listed.intersection(&present).count(),
        total / 1024
    );
    Ok(())
}

pub(super) fn run(root: &Path, work: &Path, args: &[String]) -> Result {
    let mut wanted = BTreeSet::new();
    let (mut sheet, mut publish) = (false, false);
    for arg in args {
        match arg.as_str() {
            "--sheet" => sheet = true,
            "--publish" => publish = true,
            other => {
                wanted.insert(name(other)?);
            }
        }
    }
    let scripts = root.join(".claude/skills/readme-media/scripts");
    let spec = read(&scripts.join("clips.txt"))?;
    let all = spec
        .lines()
        .map(Clip::parse)
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    let listed = all.iter().map(|clip| clip.name).collect::<BTreeSet<_>>();
    if listed.len() != all.len() {
        return Err("Duplicate clip names in clips.txt".into());
    }
    if let Some(missing) = wanted.difference(&listed).next() {
        return Err(format!("Unknown clip: {missing}"));
    }
    let ctx = Context {
        root,
        work,
        scripts,
        sheet,
        publish,
        driver: if std::env::var_os("ENCODE_ONLY").is_some_and(|v| !v.is_empty()) {
            None
        } else {
            Some(driver(root, work)?)
        },
        crf: std::env::var("CRF").unwrap_or_else(|_| "46".into()),
    };
    let selected = all
        .iter()
        .filter(|clip| wanted.is_empty() || wanted.contains(clip.name))
        .collect::<Vec<_>>();
    std::thread::scope(|scope| {
        let mut workers = Vec::new();
        for lane in 0..selected.len().min(4) {
            let clips = &selected;
            let ctx = &ctx;
            workers.push(scope.spawn(move || {
                clips
                    .iter()
                    .skip(lane)
                    .step_by(4)
                    .try_for_each(|clip| clip.render(ctx))
            }));
        }
        for job in workers {
            job.join().map_err(|_| "Clip worker stopped")??;
        }
        Ok::<(), String>(())
    })?;
    if publish {
        check_published(root, &listed)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_recording_manifest_and_camera_files() {
        let scripts =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.claude/skills/readme-media/scripts");
        let manifest = read(&scripts.join("clips.txt")).unwrap();
        let clips: Vec<_> = manifest
            .lines()
            .filter_map(|line| Clip::parse(line).unwrap())
            .collect();
        assert!(!clips.is_empty());
        for clip in clips {
            assert!(scripts.join(clip.keys).is_file(), "{}", clip.keys);
            assert!(clip.width > 0 && clip.height > 0 && clip.fade >= 0.);
        }
        assert!(Clip::parse("bad take @a @b 32 32 clips/../note").is_err());
    }
}
