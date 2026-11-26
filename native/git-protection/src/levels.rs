//! Branch types from Agent Watch settings and the check level each one asks for.
//!
//! The app writes the table; this side only reads it. An agent runs as the same user and can
//! edit the file, so nothing read here may lower the floor: `main`, `master`, the remote's
//! default branch, branches listed in `mothership.protectedBranch` and tags. See ADR-0025.

use serde::Deserialize;
use std::collections::HashMap;
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

const TABLE_FILE: &str = "git-branch-types.json";

fn settings_path() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    if let Some((folder, configuration)) =
        option_env!("AGENT_WATCH_GIT_BUNDLE_POLICY").and_then(|value| value.split_once('/'))
    {
        // A profile can use a different HOME. A packaged helper follows the same account
        // Application Support folder as the app, even when the app is closed.
        let support = if let Some(path) = (configuration == "debug")
            .then(|| std::env::var_os("AGENT_WATCH_SUPPORT_DIR").filter(|value| !value.is_empty()))
            .flatten()
        {
            PathBuf::from(path)
        } else {
            nix::unistd::User::from_uid(nix::unistd::getuid())
                .ok()??
                .dir
                .join("Library/Application Support")
        };
        return Some(support.join(folder).join(TABLE_FILE));
    }

    std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(|home| {
            PathBuf::from(home)
                .join("Library/Application Support/AgentWatch")
                .join(TABLE_FILE)
        })
}
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
struct LegacyTable {
    types: Vec<BranchType>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OperationRules {
    force_push: Vec<BranchType>,
    delete: Vec<BranchType>,
}

impl OperationRules {
    fn for_operation(&self, delete: bool) -> &[BranchType] {
        if delete {
            &self.delete
        } else {
            &self.force_push
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct BranchTypes {
    enabled: bool,
    global: OperationRules,
    repositories: HashMap<String, OperationRules>,
}

impl Default for BranchTypes {
    fn default() -> Self {
        Self {
            enabled: true,
            global: OperationRules::default(),
            repositories: HashMap::new(),
        }
    }
}

#[derive(Clone, Copy)]
pub struct BranchRules<'a> {
    global: &'a [BranchType],
    local: &'a [BranchType],
    default: Level,
}

impl<'a> BranchRules<'a> {
    pub fn has_none_or_forbid(self) -> bool {
        self.global
            .iter()
            .chain(self.local)
            .any(|rule| matches!(rule.level, Level::None | Level::Forbid))
    }

    pub fn selected(self, branch: &str) -> (Level, Option<&'a BranchType>) {
        let matching = |rules: &'a [BranchType]| {
            rules.iter().find(|rule| {
                rule.patterns
                    .iter()
                    .any(|pattern| pattern_matches(pattern, branch))
            })
        };
        let global = matching(self.global);
        let level = global.map_or(self.default, |rule| rule.level);
        if let Some(local) = matching(self.local)
            && local.level > level
        {
            return (local.level, Some(local));
        }
        (level, global)
    }
}

impl BranchTypes {
    pub fn load() -> Self {
        settings_path().map_or_else(Self::default, |path| Self::load_from(&path))
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
        #[derive(Deserialize)]
        struct Version {
            version: u32,
        }

        match serde_json::from_str::<Version>(text).ok()?.version {
            1 => {
                let old: LegacyTable = serde_json::from_str(text).ok()?;
                Some(Self {
                    global: OperationRules {
                        force_push: old.types.clone(),
                        delete: old.types,
                    },
                    ..Self::default()
                })
            }
            2 => serde_json::from_str(text).ok(),
            _ => None,
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn has_repository_rules(&self) -> bool {
        !self.repositories.is_empty()
    }

    pub fn rules(&self, delete: bool, repository: Option<&str>) -> BranchRules<'_> {
        BranchRules {
            global: self.global.for_operation(delete),
            local: repository
                .and_then(|key| self.repositories.get(key))
                .map_or(&[], |rules| rules.for_operation(delete)),
            default: if delete { Level::Click } else { Level::Name },
        }
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

/// The level of a force push or deletion, before protected-branch checks.
pub fn chosen(
    types: &BranchTypes,
    branch: &str,
    delete: bool,
    repo: Option<&str>,
) -> (Level, Option<String>) {
    let (level, rule) = types.rules(delete, repo).selected(branch);
    (level, rule.map(|rule| rule.name.clone()))
}

pub const COMMON_DIRECTORY_ARGS: &[&str] = &["rev-parse", "--git-common-dir"];

pub fn canonical_directory(folder: &Path, path: &str) -> Result<String, String> {
    if path.is_empty() {
        return Err("Git did not return the repository’s common directory.".into());
    }
    let resolved = folder
        .join(path)
        .canonicalize()
        .map_err(|_| "Git could not resolve the repository’s common directory.")?;
    resolved
        .into_os_string()
        .into_string()
        .map_err(|_| "The repository's directory is not valid UTF-8.".into())
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
            chosen(&types, "fix/typo", true, None),
            (Level::Click, Some("Features".into()))
        );
        assert_eq!(chosen(&types, "hotfix/1", false, None).0, Level::Name);
        assert_eq!(chosen(&types, "tmp/x", false, None).0, Level::None);
        assert_eq!(chosen(&types, "archive/2025", true, None).0, Level::Forbid);
    }

    #[test]
    fn operations_are_independent_and_repositories_can_only_strengthen_them() {
        let types =
            BranchTypes::parse(include_str!("../tests/fixtures/branch-rules-v2.json")).unwrap();
        let repo = Some("/work/agent-watch/.git");
        assert!(types.enabled());
        assert_eq!(chosen(&types, "release/1", false, repo).0, Level::Forbid);
        assert_eq!(chosen(&types, "release/1", true, repo).0, Level::Name);
        assert_eq!(chosen(&types, "agent/kept", false, repo).0, Level::Name);
        assert_eq!(chosen(&types, "agent/kept", true, repo).0, Level::Forbid);
        assert_eq!(chosen(&types, "agent/kept", true, None).0, Level::None);
    }

    #[test]
    fn the_first_matching_type_wins() {
        let types = table(
            r#"[{"name":"Drafts","patterns":["agent/*"],"level":"none"},
                {"name":"Everything","patterns":["*"],"level":"forbid"},
                {"name":"Late","patterns":["agent/x"],"level":"name"}]"#,
        );
        assert_eq!(
            types.rules(true, None).selected("agent/x").1.unwrap().name,
            "Drafts"
        );
        assert_eq!(
            types
                .rules(true, None)
                .selected("feature/y")
                .1
                .unwrap()
                .name,
            "Everything"
        );
        assert_eq!(
            chosen(&types, "agent/x", true, None),
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
            .map(|branch| chosen(&types, branch, false, None).0)
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
            assert_eq!(
                chosen(&types, "feature/x", true, None),
                (Level::Click, None)
            );
            assert_eq!(
                chosen(&types, "feature/x", false, None),
                (Level::Name, None)
            );
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
        assert_eq!(
            newer.unwrap().rules(true, None).selected("a").0,
            Level::None
        );
        let missing = BranchTypes::load_from(Path::new("/nonexistent/agent-watch/types.json"));
        assert!(missing.rules(true, None).selected("anything").1.is_none());
    }
}
