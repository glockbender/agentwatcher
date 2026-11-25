//! Branch types from Agent Watch settings and the check level each one asks for.
//!
//! The app writes the table; this side only reads it. An agent runs as the same user and can
//! edit the file, so nothing read here may lower the floor: `main`, `master`, the remote's
//! default branch, branches listed in `mothership.protectedBranch` and tags. See ADR-0025.

use serde::Deserialize;
use std::path::{Path, PathBuf};

/// How a force push or a remote deletion of a branch is checked, weakest first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    /// No window: the agent's own `git push` goes through.
    None,
    /// One confirmation.
    Click,
    /// Confirmation plus typing the repository name.
    Name,
    /// Always refused; the person runs the command from a terminal.
    Forbid,
}

/// Where the app keeps the table, relative to the home folder.
pub const TABLE_PATH: &str = "Library/Application Support/AgentWatch/git-branch-types.json";
const TABLE_VERSION: u32 = 1;
const MAX_TABLE_BYTES: u64 = 1024 * 1024;

// Unknown fields are ignored, as the app's decoder ignores them, so both sides read one
// file the same way.
#[derive(Clone, Debug, Deserialize)]
pub struct BranchType {
    pub name: String,
    pub patterns: Vec<String>,
    pub level: Level,
}

#[derive(Deserialize)]
struct Table {
    version: u32,
    types: Vec<BranchType>,
}

#[derive(Clone, Debug, Default)]
pub struct BranchTypes(Vec<BranchType>);

impl BranchTypes {
    /// The table of the home the agent runs with. Agents follow `HOME`, so a scratch home
    /// gets no types, which is today's behaviour.
    pub fn load() -> Self {
        std::env::var_os("HOME")
            .filter(|home| !home.is_empty())
            .map(|home| Self::load_from(&PathBuf::from(home).join(TABLE_PATH)))
            .unwrap_or_default()
    }

    /// A missing or unreadable file means no types. Never a lower level: with no types every
    /// branch keeps the behaviour it had before types existed.
    pub fn load_from(path: &Path) -> Self {
        let Ok(file) = std::fs::File::open(path) else {
            return Self::default();
        };
        let mut text = String::new();
        if std::io::Read::read_to_string(
            &mut std::io::Read::take(file, MAX_TABLE_BYTES + 1),
            &mut text,
        )
        .is_err()
            || text.len() as u64 > MAX_TABLE_BYTES
        {
            return Self::default();
        }
        Self::parse(&text).unwrap_or_default()
    }

    pub fn parse(text: &str) -> Option<Self> {
        let table: Table = serde_json::from_str(text).ok()?;
        (table.version == TABLE_VERSION).then_some(Self(table.types))
    }

    /// Whether any type can let a push through or refuse it without a window. Without one,
    /// the hook has nothing to look up.
    pub fn has_none_or_forbid(&self) -> bool {
        self.0
            .iter()
            .any(|kind| matches!(kind.level, Level::None | Level::Forbid))
    }

    /// The first type with a pattern that matches the short branch name.
    pub fn matching(&self, branch: &str) -> Option<&BranchType> {
        self.0.iter().find(|kind| {
            kind.patterns
                .iter()
                .any(|pattern| pattern_matches(pattern, branch))
        })
    }
}

/// `*` matches any run of characters, `/` included, so `release/*` covers `release/2026/q1`.
/// `?` matches one character. Everything else matches itself.
pub fn pattern_matches(pattern: &str, name: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let name: Vec<char> = name.chars().collect();
    let (mut p, mut n) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while n < name.len() {
        if p < pattern.len() && (pattern[p] == '?' || pattern[p] == name[n]) {
            p += 1;
            n += 1;
        } else if p < pattern.len() && pattern[p] == '*' {
            star = Some((p, n));
            p += 1;
        } else if let Some((star_p, star_n)) = star {
            p = star_p + 1;
            n = star_n + 1;
            star = Some((star_p, star_n + 1));
        } else {
            return false;
        }
    }
    pattern[p..].iter().all(|&c| c == '*')
}

/// The level of a force push or deletion of a branch, before the floor.
///
/// A branch no type matches keeps the behaviour it had before types existed: one click for a
/// deletion, a confirmation plus the repository name for a force push.
pub fn chosen(types: &BranchTypes, branch: &str, delete: bool) -> (Level, Option<String>) {
    match types.matching(branch) {
        Some(kind) => (kind.level, Some(kind.name.clone())),
        None if delete => (Level::Click, None),
        None => (Level::Name, None),
    }
}

/// The floor raises a protected branch to `name`; nothing lowers it.
pub fn with_floor(level: Level, protected: bool) -> Level {
    if protected {
        level.max(Level::Name)
    } else {
        level
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn table(types: &str) -> BranchTypes {
        BranchTypes::parse(&format!(r#"{{"version":1,"types":{types}}}"#)).unwrap()
    }

    #[test]
    fn patterns_follow_the_shared_fixture() {
        // The Swift side reads the same file, so the two matchers cannot drift apart.
        let cases: Vec<Value> =
            serde_json::from_str(include_str!("../tests/fixtures/branch-patterns.json")).unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let pattern = case["pattern"].as_str().unwrap();
            let name = case["name"].as_str().unwrap();
            assert_eq!(
                pattern_matches(pattern, name),
                case["matches"].as_bool().unwrap(),
                "{pattern} vs {name}"
            );
        }
    }

    #[test]
    fn the_table_the_app_writes_is_read() {
        // The Swift tests encode a table and compare it with the same file.
        let types =
            BranchTypes::parse(include_str!("../tests/fixtures/branch-types.json")).unwrap();
        assert_eq!(
            chosen(&types, "fix/typo", true),
            (Level::Click, Some("Features".into()))
        );
        assert_eq!(chosen(&types, "hotfix/1", false).0, Level::Name);
        assert_eq!(chosen(&types, "tmp/x", false).0, Level::None);
        assert_eq!(chosen(&types, "archive/2025", true).0, Level::Forbid);
    }

    #[test]
    fn the_first_matching_type_wins() {
        let types = table(
            r#"[{"name":"Drafts","patterns":["agent/*"],"level":"none"},
                {"name":"Everything","patterns":["*"],"level":"forbid"},
                {"name":"Late","patterns":["agent/x"],"level":"name"}]"#,
        );
        assert_eq!(types.matching("agent/x").unwrap().name, "Drafts");
        assert_eq!(types.matching("feature/y").unwrap().name, "Everything");
        assert_eq!(
            chosen(&types, "agent/x", true),
            (Level::None, Some("Drafts".into()))
        );
    }

    #[test]
    fn every_level_is_read_and_ordered() {
        let types = table(
            r#"[{"name":"A","patterns":["a"],"level":"none"},
                {"name":"B","patterns":["b"],"level":"click"},
                {"name":"C","patterns":["c"],"level":"name"},
                {"name":"D","patterns":["d"],"level":"forbid"}]"#,
        );
        let levels: Vec<_> = ["a", "b", "c", "d"]
            .iter()
            .map(|branch| chosen(&types, branch, false).0)
            .collect();
        assert_eq!(
            levels,
            [Level::None, Level::Click, Level::Name, Level::Forbid]
        );
        assert!(Level::None < Level::Click && Level::Click < Level::Name);
        assert!(Level::Name < Level::Forbid);
    }

    #[test]
    fn a_branch_without_a_type_keeps_todays_behaviour() {
        for types in [BranchTypes::default(), table("[]")] {
            assert_eq!(chosen(&types, "feature/x", true), (Level::Click, None));
            assert_eq!(chosen(&types, "feature/x", false), (Level::Name, None));
        }
    }

    #[test]
    fn the_floor_never_goes_below_name() {
        for level in [Level::None, Level::Click, Level::Name] {
            assert_eq!(with_floor(level, true), Level::Name);
        }
        assert_eq!(with_floor(Level::Forbid, true), Level::Forbid);
        assert_eq!(with_floor(Level::None, false), Level::None);
    }

    #[test]
    fn an_unreadable_table_means_no_types() {
        for text in [
            "",
            "{",
            r#"{"version":2,"types":[]}"#,
            r#"{"version":1,"types":[{"name":"A","patterns":["*"],"level":"never"}]}"#,
            r#"{"version":1,"types":[{"name":"A","level":"none"}]}"#,
        ] {
            assert!(BranchTypes::parse(text).is_none(), "{text}");
        }
        // A field this version does not know is ignored, as the app ignores it.
        let newer = BranchTypes::parse(
            r#"{"version":1,"types":[{"name":"A","patterns":["a"],"level":"none","colour":"red"}]}"#,
        );
        assert_eq!(newer.unwrap().matching("a").unwrap().level, Level::None);
        let missing = BranchTypes::load_from(Path::new("/nonexistent/agent-watch/types.json"));
        assert!(missing.matching("anything").is_none());
    }
}
