use super::*;
use regex::Regex;
use std::cmp::Ordering;
use std::sync::LazyLock;

pub(super) const OUTPUT: &str = "docs/measurements.md";
const UNKNOWN: &str = "версия не записана";
const GROUPS: &[(&str, &[&str])] = &[
    ("Claude Code", &["Claude Code", "Claude.app"]),
    ("Codex", &["Codex Desktop", "Codex", "ChatGPT.app"]),
    ("Ghostty", &["Ghostty"]),
    (
        "JetBrains IDE",
        &["GoLand", "IntelliJ IDEA", "PyCharm", "RustRover"],
    ),
    ("macOS", &["macOS"]),
];
const VERSION: &str = r"\d+(?:\.\d+)+(?:-[A-Za-z]+(?:\.\d+)*)?";
const NUMBER: &str = r"\d+(?:\.\d+)*(?:-[A-Za-z]+(?:\.\d+)*)?";

fn subjects() -> impl Iterator<Item = &'static str> {
    GROUPS.iter().flat_map(|(_, items)| items.iter().copied())
}

static NAMES: LazyLock<String> =
    LazyLock::new(|| subjects().map(regex::escape).collect::<Vec<_>>().join("|"));
static FULL_VERSION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!("^{VERSION}$")).unwrap());
static CHECKED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!("({}) ({VERSION})", *NAMES)).unwrap());
static CODE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"[Mm]easured on ({})\b((?: {NUMBER})?(?:(?:, | and |, and ){VERSION})*)",
        *NAMES
    ))
    .unwrap()
});
static NUMBERS: LazyLock<Regex> = LazyLock::new(|| Regex::new(NUMBER).unwrap());
type Versions = Vec<(String, String)>;
pub(super) type Row = [String; 4];

fn add_unknown(versions: &mut Versions, subject: Option<&str>) {
    if let Some(s) = subject
        && !versions.iter().any(|(name, _)| name == s)
    {
        versions.push((s.into(), UNKNOWN.into()));
    }
}

pub(super) fn parse_marker(body: &str) -> Option<Versions> {
    let mut versions = Vec::new();
    let mut subject = None;
    for part in body.split(',').map(str::trim) {
        if let Some(name) = subjects().find(|s| {
            part == *s
                || part
                    .strip_prefix(s)
                    .is_some_and(|tail| tail.starts_with(' '))
        }) {
            add_unknown(&mut versions, subject);
            subject = Some(name);
            let rest = part[name.len()..].trim();
            if !rest.is_empty() {
                if !FULL_VERSION.is_match(rest) && !re!(r"^\d+$").is_match(rest) {
                    return None;
                }
                versions.push((name.into(), rest.into()));
            }
        } else if let Some(s) = subject
            && (part == UNKNOWN || FULL_VERSION.is_match(part))
        {
            versions.push((s.into(), part.into()));
        } else {
            return None;
        }
    }
    add_unknown(&mut versions, subject);
    (!versions.is_empty()).then_some(versions)
}

#[derive(Default)]
struct Unit {
    title: String,
    anchor: String,
    text: String,
    line: usize,
}

fn units(text: &str) -> Vec<Unit> {
    let mut units = Vec::new();
    let mut seen = BTreeMap::new();
    let (mut title, mut anchor) = (String::new(), String::new());
    let mut fence = false;
    let mut current = Unit::default();
    for (index, line) in text.lines().chain(std::iter::once("")).enumerate() {
        if line.starts_with("```") {
            fence = !fence;
            continue;
        }
        if fence {
            continue;
        }
        let header = heading(line);
        let line = line.trim_end();
        if header.is_some() || line.trim().is_empty() || re!(r"^(?:\||[-*] |\d+\. )").is_match(line)
        {
            if !current.text.is_empty() {
                units.push(std::mem::take(&mut current));
            }
            if let Some((level, name)) = header {
                title = name.into();
                anchor = numbered_anchor(&mut seen, name);
                if level == 1 {
                    title.clear();
                    anchor.clear();
                }
                continue;
            }
            if line.trim().is_empty() {
                continue;
            }
        }
        if current.text.is_empty() {
            current.line = index + 1;
            current.title.clone_from(&title);
            current.anchor.clone_from(&anchor);
        } else {
            current.text.push(' ');
        }
        current.text.push_str(line.trim());
    }
    if !current.text.is_empty() {
        units.push(current);
    }
    units
}

fn marker() -> &'static Regex {
    re!(r"\(замер: ([^)]*)\)")
}

fn sentence(mut text: &str, mut start: usize, mut end: usize) -> String {
    if text.starts_with('|') {
        let mut offset = 1;
        for cell in text.trim_matches('|').split('|') {
            if start >= offset && start < offset + cell.len() + 1 {
                start = (start - offset).min(cell.len());
                end = (end - offset).min(cell.len());
                text = cell;
                break;
            }
            offset += cell.len() + 1;
        }
    }
    let left = [". ", "! ", "? "]
        .iter()
        .filter_map(|p| text[..start].rfind(p))
        .max()
        .map_or(0, |n| n + 2);
    let right = [". ", "! ", "? "]
        .iter()
        .filter_map(|p| text[end..].find(p))
        .min()
        .map_or(text.len(), |n| end + n + 1);
    let phrase = marker().replace_all(text[left..right].trim(), "");
    let phrase = re!(r"\[([^\]]+)\]\([^)]+\)").replace_all(&phrase, "$1");
    let phrase = re!(r"\s{2,}").replace_all(&phrase, " ");
    let phrase = re!(r"\s+([.,;:])").replace_all(&phrase, "$1");
    let phrase = phrase.trim().replace('|', "\\|");
    if phrase.chars().count() <= 240 {
        return phrase;
    }
    let cut: String = phrase.chars().take(239).collect();
    format!("{}…", cut.rsplit_once(' ').map_or(cut.as_str(), |(s, _)| s))
}

fn has_claim(text: &str) -> bool {
    re!(r"\b(?:[Зз]амерен[оаы]?|[Зз]америл[аи]?|[Ии]змерен[оаы]?|[Ии]змерил[аи]?)\b|\b[Зз]амеры? показал[аи]?\b")
        .find_iter(text).any(|m|m.as_str().contains(' ') || !text[..m.start()].ends_with("не ") && !text[..m.start()].ends_with("Не "))
}

fn doc_rows(name: &str, text: &str, rows: &mut Vec<Row>, errors: &mut Vec<String>) {
    let short = Path::new(name).file_name().unwrap().to_string_lossy();
    let link = name.strip_prefix("docs/").unwrap();
    for u in units(text) {
        let marks: Vec<_> = marker().captures_iter(&u.text).collect();
        if marks.is_empty()
            && !matches!(name, "docs/implementation-plan.md" | "docs/release-plan.md")
            && has_claim(&u.text)
        {
            errors.push(format!(
                "{name}:{}: says it measured something; add (замер: <program> <version>)",
                u.line
            ));
        }
        for m in marks {
            let Some(parsed) = parse_marker(&m[1]) else {
                errors.push(format!(
                    "{name}:{}: {} names one of {} and versions",
                    u.line,
                    &m[0],
                    subjects().collect::<Vec<_>>().join(", ")
                ));
                continue;
            };
            let place = if u.anchor.is_empty() {
                format!("[{short}]({link})")
            } else {
                format!("[{short}, «{}»]({link}#{})", u.title, u.anchor)
            };
            let span = m.get(0).unwrap();
            let fact = sentence(&u.text, span.start(), span.end());
            rows.extend(
                parsed
                    .into_iter()
                    .map(|(s, v)| [s, v, fact.clone(), place.clone()]),
            );
        }
    }
}

fn troubleshooting_rows(text: &str, rows: &mut Vec<Row>, errors: &mut Vec<String>) {
    for u in units(text) {
        let Some(body) = u
            .text
            .strip_prefix("**Checked on:** ")
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        let first = re!(r"\. |; ")
            .split(body.trim_end_matches('.'))
            .next()
            .unwrap();
        let mut recorded = false;
        for m in CHECKED.captures_iter(first) {
            rows.push([
                m[1].into(),
                m[2].into(),
                u.title.replace('|', "\\|"),
                format!(
                    "[TROUBLESHOOTING.md, «{}»](../TROUBLESHOOTING.md#{})",
                    u.title, u.anchor
                ),
            ]);
            recorded = true;
        }
        if !recorded && !first.starts_with("not recorded") {
            errors.push(format!("TROUBLESHOOTING.md:{}: **Checked on:** names a program and its version, or says not recorded",u.line));
        }
    }
}

fn code_rows(name: &str, text: &str, prefix: &str, rows: &mut Vec<Row>) {
    let mut paragraph = String::new();
    for line in text.lines().chain(std::iter::once("")) {
        let s = line.trim();
        let body = s.trim_start_matches(['/', '#']).trim();
        if s.starts_with(prefix) && !s.starts_with("#!") && !body.is_empty() {
            if !paragraph.is_empty() {
                paragraph.push(' ');
            }
            paragraph.push_str(body);
            continue;
        }
        for m in CODE.captures_iter(&paragraph) {
            let span = m.get(0).unwrap();
            let fact = sentence(&paragraph, span.start(), span.end());
            let mut versions = NUMBERS.find_iter(&m[2]).map(|s| s.as_str()).peekable();
            if versions.peek().is_none() {
                rows.push([
                    m[1].into(),
                    UNKNOWN.into(),
                    fact.clone(),
                    format!("`{name}`"),
                ]);
            }
            rows.extend(
                versions.map(|v| [m[1].into(), v.into(), fact.clone(), format!("`{name}`")]),
            );
        }
        paragraph.clear();
    }
}

pub(super) fn collect(files: &Files) -> (Vec<Row>, Vec<String>) {
    let mut rows = Vec::new();
    let mut errors = Vec::new();
    for (name, text) in files {
        if name.starts_with("docs/") && name.ends_with(".md") && !frozen(name) && name != OUTPUT {
            doc_rows(name, text, &mut rows, &mut errors);
        } else if name == "TROUBLESHOOTING.md" {
            troubleshooting_rows(text, &mut rows, &mut errors);
        } else if let Some(prefix) = match Path::new(name).extension().and_then(|s| s.to_str()) {
            Some("swift" | "rs" | "kt" | "kts") => Some("//"),
            Some("sh") => Some("#"),
            _ => None,
        } {
            code_rows(name, text, prefix, &mut rows);
        }
    }
    (rows, errors)
}

fn by_version(left: &str, right: &str) -> Ordering {
    let (a, tag_a) = left
        .split_once('-')
        .map_or((left, false), |(s, _)| (s, true));
    let (b, tag_b) = right
        .split_once('-')
        .map_or((right, false), |(s, _)| (s, true));
    let a: Vec<_> = a.split('.').collect();
    let b: Vec<_> = b.split('.').collect();
    let numeric = || {
        for (x, y) in a.iter().zip(&b) {
            let x = x.trim_start_matches('0');
            let y = y.trim_start_matches('0');
            let cmp = y.len().cmp(&x.len()).then_with(|| y.cmp(x));
            if cmp != Ordering::Equal {
                return cmp;
            }
        }
        a.len().cmp(&b.len()).then_with(|| tag_a.cmp(&tag_b))
    };
    (left == UNKNOWN)
        .cmp(&(right == UNKNOWN))
        .then_with(numeric)
}

pub(super) fn render(rows: Vec<Row>) -> String {
    use std::fmt::Write;
    let mut text = include_str!("measurements-header.md.in").to_owned();
    for (title, subjects) in GROUPS {
        let mut group: Vec<_> = rows
            .iter()
            .filter_map(|r| subjects.iter().position(|s| s == &r[0]).map(|i| (i, r)))
            .collect();
        if group.is_empty() {
            continue;
        }
        group.sort_by(|(i, a), (j, b)| {
            i.cmp(j)
                .then_with(|| by_version(&a[1], &b[1]))
                .then_with(|| a[3].cmp(&b[3]))
                .then_with(|| a[2].cmp(&b[2]))
        });
        writeln!(
            text,
            "\n## {title}\n\n| Версия | Что замерено | Где |\n| --- | --- | --- |"
        )
        .unwrap();
        for (_, r) in group {
            let subject = if subjects.len() > 1 {
                format!("{} ", r[0])
            } else {
                String::new()
            };
            writeln!(text, "| {subject}{} | {} | {} |", r[1], r[2], r[3]).unwrap();
        }
    }
    text
}
