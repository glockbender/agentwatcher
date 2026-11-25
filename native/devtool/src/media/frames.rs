//! Coordinates in marks are display points. FFmpeg cropping and camera keys use stage pixels.
use super::{Result, read};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};

pub(super) const FPS: u32 = 25;

pub(super) fn name(text: &str) -> Result<&str> {
    if text.is_empty()
        || !text
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
    {
        Err(format!("Invalid take or clip name: {text}"))
    } else {
        Ok(text)
    }
}

pub(super) fn number(word: &str) -> Result<f64> {
    word.parse::<f64>()
        .ok()
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("Invalid number: {word}"))
}

#[derive(Default)]
pub(super) struct Marks {
    pub scale: f64,
    pub stage: [f64; 4],
    pub bar: f64,
    pub times: BTreeMap<String, f64>,
    icons: Vec<(f64, Option<[f64; 2]>)>,
    pub taps: Vec<[f64; 3]>,
}

impl Marks {
    pub fn load(work: &Path, take: &str) -> Result<Self> {
        Self::parse(&read(&work.join(format!("{}.marks", name(take)?)))?)
    }
    pub fn parse(text: &str) -> Result<Self> {
        let mut m = Self::default();
        for line in text.lines() {
            let words = line.split_whitespace().collect::<Vec<_>>();
            match words.as_slice() {
                ["stage", x, y, w, h] => m.stage = [number(x)?, number(y)?, number(w)?, number(h)?],
                ["scale", s] => m.scale = number(s)?,
                ["bar", b] => m.bar = number(b)?,
                ["@", t, label, ..] => {
                    m.times.insert((*label).into(), number(t)?);
                }
                ["icon", t] => m.icons.push((number(t)?, None)),
                ["icon", t, x, w] => m.icons.push((number(t)?, Some([number(x)?, number(w)?]))),
                ["tap", t, x, y] => m.taps.push([number(t)?, number(x)?, number(y)?]),
                [] | ["failed"] => {}
                _ => return Err(format!("Invalid recording mark: {line}")),
            }
        }
        if m.scale <= 0.0 || m.stage[2] <= 0.0 || m.stage[3] <= 0.0 {
            return Err("Missing stage dimensions or scale".into());
        }
        Ok(m)
    }
    pub fn at(&self, expression: &str) -> Result<f64> {
        let Some(key) = expression.strip_prefix('@') else {
            return number(expression);
        };
        if let Some(t) = self.times.get(key) {
            return Ok(*t);
        }
        for (at, _) in key.match_indices(['-', '+']).rev() {
            if let Some(t) = self.times.get(&key[..at])
                && let Ok(offset) = number(&key[at..])
            {
                return Ok(t + offset);
            }
        }
        Err(format!(
            "No mark {expression}; available: {}",
            self.times.keys().cloned().collect::<Vec<_>>().join(", ")
        ))
    }
    pub fn crop(&self) -> Result<[i32; 4]> {
        let [x, y, w, h] = self
            .stage
            .map(|p| (p * self.scale).round_ties_even() as i32);
        if w < 2 || h < 2 {
            return Err("Stage must be at least two pixels wide and high".into());
        }
        Ok([x, y, w / 2 * 2, h / 2 * 2])
    }
    fn spans(&self, start: f64, end: f64, x: i32, w: i32) -> Vec<(f64, f64, i32, i32)> {
        let rects: Vec<_> = self
            .icons
            .iter()
            .map(|(t, frame)| {
                (
                    *t,
                    frame.map(|[left, width]| {
                        let left = left * self.scale - f64::from(x);
                        let right = left + width * self.scale;
                        (
                            (left.max(0.0) + 1.0) as i32 / 2 * 2,
                            right.min(f64::from(w)) as i32 / 2 * 2,
                        )
                    }),
                )
            })
            .collect();
        let mut spans = Vec::new();
        let mut push = |begin: f64, finish: f64, left: i32, right: i32| {
            let a = (begin - start).max(0.0);
            let b = (finish - start).min(end - start);
            if b > a && right > left {
                spans.push((a, b, left, right));
            }
        };
        for (i, (t, frame)) in rects.iter().enumerate() {
            let Some((left, right)) = frame else { continue };
            let finish = rects.get(i + 1).map_or(end, |(t, _)| t - 0.4);
            push(if i == 0 { start } else { t + 0.4 }, finish, *left, *right);
            if let Some((_, Some((next_left, next_right)))) = rects.get(i + 1) {
                push(
                    finish,
                    finish + 0.8,
                    (*left).max(*next_left),
                    (*right).min(*next_right),
                );
            }
        }
        spans
    }
    pub fn filter(&self, start: f64, end: f64) -> Result<String> {
        let [x, y, w, h] = self.crop()?;
        let bar = (self.bar * self.scale).round_ties_even() as i32 - y;
        let mut s = format!("[0:v]crop={w}:{h}:{x}:{y}");
        if bar <= 0 {
            return Ok(format!("{s},fps={FPS}[o]"));
        }
        let spans = self.spans(start, end, x, w);
        s.push_str(&format!(",split={}[base][b]", spans.len() + 2));
        for i in 0..spans.len() {
            s.push_str(&format!("[p{i}]"));
        }
        s.push_str(&format!(
            ";[b]crop={w}:{bar}:0:0,boxblur={}:3[blur];[base][blur]overlay=0:0[o0]",
            14.min((w.min(bar) - 1) / 4)
        ));
        for (i, (a, b, left, right)) in spans.iter().enumerate() {
            s.push_str(&format!(";[p{i}]crop={}:{bar}:{left}:0[q{i}];[o{i}][q{i}]overlay={left}:0:enable='between(t,{a:.3},{b:.3})'[o{}]",right-left,i+1));
        }
        Ok(format!("{s};[o{}]fps={FPS}[o]", spans.len()))
    }
}

fn changes(before: &[u8], after: &[u8], width: usize) -> Option<([usize; 4], usize)> {
    let mut rect = [usize::MAX, usize::MAX, 0, 0];
    let mut count = 0;
    for (i, (a, b)) in before.iter().zip(after).enumerate() {
        if a.abs_diff(*b) > 12 {
            let (x, y) = (i % width, i / width);
            rect = [
                rect[0].min(x),
                rect[1].min(y),
                rect[2].max(x + 1),
                rect[3].max(y + 1),
            ];
            count += 1;
        }
    }
    (count > 0).then(|| (rect.map(|n| n * 4), count))
}

pub(super) fn activity(work: &Path, args: &[String]) -> Result {
    if args.is_empty() || args.len() > 3 {
        return Err("media activity <take> [from] [to]".into());
    }
    let take = name(&args[0])?;
    let start = args.get(1).map_or(Ok(0.0), |s| number(s))?;
    let [x, y, w, h] = Marks::load(work, take)?.crop()?;
    let (sw, sh) = ((w / 4) as usize, (h / 4) as usize);
    let size = sw
        .checked_mul(sh)
        .filter(|n| *n > 0 && *n <= 64 * 1024 * 1024)
        .ok_or("Unsupported frame dimensions")?;
    let mut cmd = Command::new("ffmpeg");
    cmd.args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        &start.to_string(),
    ]);
    if let Some(end) = args.get(2) {
        number(end)?;
        cmd.args(["-to", end]);
    }
    let mut child = cmd
        .arg("-i")
        .arg(work.join(format!("{take}.mov")))
        .args([
            "-vf",
            &format!("crop={w}:{h}:{x}:{y},fps=10,scale={sw}:{sh}:flags=area,format=gray"),
            "-f",
            "rawvideo",
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let result: Result = (|| {
        let mut stream = child.stdout.take().ok_or("Missing FFmpeg output")?;
        let mut before = vec![0; size];
        let mut frame = vec![0; size];
        let mut index = 0u32;
        while stream.read(&mut frame[..1]).map_err(|e| e.to_string())? != 0 {
            stream
                .read_exact(&mut frame[1..])
                .map_err(|e| format!("Incomplete FFmpeg frame: {e}"))?;
            if index > 0
                && let Some(([x0, y0, x1, y1], count)) = changes(&before, &frame, sw)
            {
                println!(
                    "{:6.1}s  x {x0:4}-{x1:4}  y {y0:4}-{y1:4}  {count:5} px",
                    start + f64::from(index) / 10.0
                );
            }
            std::mem::swap(&mut before, &mut frame);
            index += 1;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = child.kill();
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    result?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("FFmpeg exited with {status}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn camera_marks_and_even_privacy_spans() {
        let m = Marks::parse(
            "scale 2\nbar 25\nstage 5 10 101 99\n@ 1.5 menu-open\nicon 1 12 14\nicon 2 15 13\n",
        )
        .unwrap();
        assert_eq!(m.at("@menu-open-0.2").unwrap(), 1.3);
        let graph = m.filter(0., 5.).unwrap();
        assert!(graph.contains("crop=202:30:0:0"));
        assert!(graph.contains("between(t,1.600,2.400)"));
        assert_eq!(
            changes(&[0, 0, 0, 0], &[0, 12, 0, 13], 2),
            Some(([4, 4, 8, 8], 1))
        );
    }
}
