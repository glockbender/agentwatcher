use super::*;
use std::collections::BTreeSet;

type Check = fn(&Files) -> Vec<String>;
pub(super) const CHECKS: &[Check] = &[links, paths, adrs, sections, status, openings, lengths];

fn without_fences(text: &str) -> String {
    re!(r"(?ms)^\x60\x60\x60.*?^\x60\x60\x60")
        .replace_all(text, |m: &regex::Captures<'_>| {
            "\n".repeat(m[0].bytes().filter(|&c| c == b'\n').count())
        })
        .into_owned()
}

fn anchors(text: &str) -> BTreeSet<String> {
    let mut seen = BTreeMap::new();
    without_fences(text)
        .lines()
        .filter_map(heading)
        .map(|(_, title)| numbered_anchor(&mut seen, title))
        .collect()
}

fn normalize(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir if result.file_name().is_some() => {
                result.pop();
            }
            p => result.push(p.as_os_str()),
        }
    }
    result
}

fn location(name: &str, text: &str, pos: usize) -> String {
    format!(
        "{name}:{}",
        1 + text[..pos].bytes().filter(|&c| c == b'\n').count()
    )
}

pub(super) fn links(files: &Files) -> Vec<String> {
    let mut problems = Vec::new();
    let mut known = BTreeMap::new();
    for (name, text) in files.iter().filter(|(n, _)| n.ends_with(".md")) {
        let prose = without_fences(text);
        for m in re!(r"\]\(([^)\s]+)\)").captures_iter(&prose) {
            let target = &m[1];
            if ["http://", "https://", "mailto:"]
                .iter()
                .any(|p| target.starts_with(p))
            {
                continue;
            }
            let (path, anchor) = target.split_once('#').unwrap_or((target, ""));
            let resolved = if path.is_empty() {
                PathBuf::from(name)
            } else {
                normalize(&Path::new(name).parent().unwrap().join(path))
            };
            let file = resolved.to_string_lossy();
            let error = if !files.contains_key(file.as_ref()) && !resolved.exists() {
                "which does not exist"
            } else if !anchor.is_empty()
                && file.ends_with(".md")
                && !known
                    .entry(file.to_string())
                    .or_insert_with(|| anchors(files.get(file.as_ref()).map_or("", String::as_str)))
                    .contains(anchor)
            {
                "which has no such heading"
            } else {
                continue;
            };
            problems.push(format!(
                "{}: links to {target}, {error}",
                location(name, &prose, m.get(0).unwrap().start())
            ));
        }
    }
    problems
}

pub(super) fn paths(files: &Files) -> Vec<String> {
    let mut problems = Vec::new();
    for (name, text) in files {
        for m in re!(r"\bdocs/[\w./-]+\.md\b").find_iter(text) {
            if !files.contains_key(m.as_str()) {
                problems.push(format!(
                    "{}: names {}, which does not exist",
                    location(name, text, m.start()),
                    m.as_str()
                ));
            }
        }
    }
    problems
}

fn under(name: &str, dir: &str) -> bool {
    Path::new(name).parent() == Some(Path::new(dir))
}

pub(super) fn adrs(files: &Files) -> Vec<String> {
    let mut problems = Vec::new();
    let mut numbers = BTreeMap::new();
    for name in files.keys().filter(|n| under(n, "docs/adr")) {
        let basename = Path::new(name).file_name().unwrap().to_str().unwrap();
        if let Some(m) = re!(r"^(\d{4})-[a-z0-9-]+\.md$").captures(basename) {
            let number = m.get(1).unwrap().as_str();
            if let Some(other) = numbers.get(number) {
                problems.push(format!("{name}: ADR-{number} is also {other}"));
            }
            numbers.entry(number).or_insert(name);
        } else {
            problems.push(format!(
                "{name}: an ADR file is named NNNN-words-with-hyphens.md"
            ));
        }
    }
    for (name, text) in files {
        for m in re!(r"\bADR-(\d{4})\b").captures_iter(text) {
            if !numbers.contains_key(&m[1]) {
                problems.push(format!(
                    "{}: cites {}, which does not exist",
                    location(name, text, m.get(0).unwrap().start()),
                    &m[0]
                ));
            }
        }
    }
    problems
}

pub(super) fn sections(files: &Files) -> Vec<String> {
    let mut problems = Vec::new();
    for (name, text) in files {
        if frozen(name)
            || ![".md", ".swift", ".rs", ".kt"]
                .iter()
                .any(|s| name.ends_with(s))
        {
            continue;
        }
        for m in re!(r"§\s*\d").find_iter(text) {
            problems.push(format!(
                "{}: points at a section by number; name the heading",
                location(name, text, m.start())
            ));
        }
    }
    problems
}

pub(super) fn status(files: &Files) -> Vec<String> {
    files.iter().filter(|(n,_)|under(n,"docs/adr") && n.ends_with(".md"))
        .filter(|(_,t)| !re!(r"^\*\*Статус:\*\* (?:принято \d{4}-\d{2}-\d{2}|заменено \[ADR-\d{4}\]\(\d{4}-[a-z0-9-]+\.md\)|частично заменено \[ADR-\d{4}\]\(\d{4}-[a-z0-9-]+\.md\) — .+)\.$").is_match(t.lines().nth(2).unwrap_or("")))
        .map(|(n,_)|format!("{n}:3: the third line is the status: **Статус:** принято YYYY-MM-DD.")).collect()
}

pub(super) fn openings(files: &Files) -> Vec<String> {
    files
        .iter()
        .filter(|(n, _)| under(n, "docs") && n.ends_with(".md"))
        .filter(|(_, t)| {
            let opening = t
                .split("\n\n")
                .filter(|p| !p.trim().is_empty())
                .nth(1)
                .unwrap_or("")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            !opening.starts_with("Здесь") || !opening.contains("Чего здесь нет")
        })
        .map(|(n, _)| format!("{n}:3: opens with «Здесь — …» and «Чего здесь нет: …»"))
        .collect()
}

pub(super) fn lengths(files: &Files) -> Vec<String> {
    files
        .iter()
        .filter(|(n, _)| under(n, "docs") && n.ends_with(".md"))
        .filter_map(|(n, t)| {
            let lines = t.bytes().filter(|&c| c == b'\n').count();
            (lines > 500)
                .then(|| format!("{n}: {lines} lines; split it by subject (the limit is 500)"))
        })
        .collect()
}

pub(super) fn troubleshooting(doc: &str, readme: &str) -> Vec<String> {
    let mut errors = Vec::new();
    if !readme.contains("](TROUBLESHOOTING.md)") {
        errors.push("README.md does not link to TROUBLESHOOTING.md".into());
    }
    let mut entries = doc.split("\n## ").skip(1).peekable();
    if entries.peek().is_none() {
        errors.push("TROUBLESHOOTING.md has no entries (each starts with '## ')".into());
    }
    for entry in entries {
        let (title, body) = entry.split_once('\n').unwrap_or((entry, ""));
        for field in ["**Why:**", "**What to do:**", "**Checked on:**"] {
            let lines: Vec<_> = body.lines().filter_map(|s| s.strip_prefix(field)).collect();
            match lines.as_slice() {
                [s] if s.trim().is_empty() => errors.push(format!("'{title}': {field} is empty")),
                [_] => {}
                _ => errors.push(format!(
                    "'{title}': needs exactly one line starting with {field}, has {}",
                    lines.len()
                )),
            }
        }
    }
    errors
}
