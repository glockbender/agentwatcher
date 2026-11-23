//! Classify shell pushes and explain which remote references may change.
//! The Git commands in this module only read local references and configuration.

use super::commands::{basename, command_index, git_subcommand};
use super::shell::Parsed;
use crate::levels::{BranchTypes, Level};
use crate::process::{self, Cancellation, Output};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

struct Repository<'a> {
    path: &'a Path,
    cancel: &'a Cancellation,
    deadline: Instant,
}

impl Repository<'_> {
    fn query(&self, args: &[&str]) -> Result<Output, String> {
        let mut command = Command::new("git");
        command.arg("-C").arg(self.path).args(args);
        process::run(&mut command, self.cancel, self.deadline, self.deadline).map_err(|_| {
            if Instant::now() >= self.deadline {
                super::TIMEOUT
            } else {
                "The repository could not be inspected."
            }
            .to_owned()
        })
    }

    fn branch(&self, context: &Context) -> Result<String, String> {
        if !context.switched.is_empty() {
            return Ok(context.switched.clone());
        }
        let output = self.query(&["rev-parse", "--abbrev-ref", "HEAD"])?;
        let branch = output.stdout.trim();
        if !output.status.success() || branch.is_empty() {
            return Err("The current branch could not be determined.".into());
        }
        Ok(branch.to_owned())
    }

    fn push_config_risks(
        &self,
        remote: Option<&str>,
        refspecs: &[&str],
        implicit: bool,
    ) -> Result<Vec<String>, String> {
        let output = self.query(&[
            "config",
            "--null",
            "--get-regexp",
            r"^(push\.default|remote\..*\.(mirror|push))$",
        ])?;
        if !matches!(output.status.code(), Some(0 | 1)) {
            return Err("Git push defaults could not be read.".into());
        }

        let mut default = "simple".to_owned();
        let mut configured_refspec = false;
        let mut mirror = false;
        for record in output.stdout.split_terminator('\0') {
            let (key, value) = record.split_once('\n').unwrap_or((record, ""));
            if key == "push.default" {
                default = value.to_ascii_lowercase();
            } else if let Some((name, setting)) = key
                .strip_prefix("remote.")
                .and_then(|key| key.rsplit_once('.'))
                && remote.is_none_or(|remote| remote == name)
            {
                match setting {
                    "push" => configured_refspec = true,
                    "mirror" => {
                        mirror |= !matches!(
                            value.to_ascii_lowercase().as_str(),
                            "false" | "no" | "off" | "0"
                        );
                    }
                    _ => {}
                }
            }
        }

        let mut risks = Vec::new();
        if mirror {
            risks.push("the remote defaults to a mirror push".into());
        }
        let unmapped = refspecs.iter().any(|reference| !reference.contains(':'));
        let default = default.as_str();
        if (configured_refspec && (implicit || unmapped))
            || (implicit && !matches!(default, "simple" | "current" | "nothing"))
            || (unmapped && matches!(default, "upstream" | "tracking"))
        {
            risks.push(
                "the push destination depends on Git configuration; name the exact destination"
                    .into(),
            );
        }
        Ok(risks)
    }

    /// The remote a push without a remote operand goes to, in Git's own order.
    fn implicit_remote(&self, branch: &str) -> Result<String, String> {
        for key in [
            format!("branch.{branch}.pushRemote"),
            "remote.pushDefault".into(),
            format!("branch.{branch}.remote"),
        ] {
            let output = self.query(&["config", "--get", &key])?;
            let value = output.stdout.trim();
            if output.status.success() && !value.is_empty() {
                return Ok(value.into());
            }
        }
        Ok("origin".into())
    }

    /// The branch a push of a local name updates. Without `:<dst>` Git updates the source's
    /// own full ref, so the name must resolve to exactly `refs/heads/<name>`: `heads/trunk`
    /// resolving to `refs/heads/trunk` is refused, because the floor would be asked about
    /// another branch than the one pushed.
    fn local_branch(&self, name: &str) -> Result<Option<String>, String> {
        if !matches!(name, "HEAD" | "@") && !plain(name) {
            return Ok(None);
        }
        let output = self.query(&["rev-parse", "--symbolic-full-name", name])?;
        let full = output.stdout.trim();
        let Some(branch) = full.strip_prefix("refs/heads/") else {
            return Ok(None);
        };
        let exact = matches!(name, "HEAD" | "@") || name == full || name == branch;
        Ok((output.status.success() && exact && plain(branch)).then(|| branch.to_owned()))
    }

    /// Whether the floor leaves the branch alone, asked of the remote the way a push asks.
    /// Any doubt keeps the floor.
    fn below_floor(&self, remote: &str, branch: &str) -> bool {
        let Some(path) = self.path.to_str() else {
            return false;
        };
        plain(remote)
            && crate::git::Git::new(self.cancel.clone(), self.deadline)
                .and_then(|git| git.protected(path, remote, branch))
                == Ok(false)
    }

    fn known_branch(&self, name: &str) -> Result<bool, String> {
        for reference in [
            format!("refs/heads/{name}"),
            format!("refs/remotes/*/{name}"),
        ] {
            if !self
                .query(&["for-each-ref", "--format=%(refname)", &reference])?
                .stdout
                .trim()
                .is_empty()
            {
                return Ok(true);
            }
        }
        Ok(false)
    }
}

fn protected(name: &str) -> bool {
    matches!(name, "main" | "master" | "heads/main" | "heads/master")
        || name.ends_with("/heads/main")
        || name.ends_with("/heads/master")
}

/// Whether the command is plain text the shell runs as written. The parser does not look into
/// every expansion (a heredoc body, `${x:-$(…)}`), so a push may skip its window only when the
/// input has no expansion, quote, redirection or second line at all.
pub(super) fn literal(command: &str) -> bool {
    command
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || " -_./:+=,@".contains(c))
}

/// A name with nothing the shell or Git would expand or read as another ref.
fn plain(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('-')
        && !name.contains("..")
        && !name
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "$`*?[\\~^:@{}".contains(c))
}

/// A destination Git can only read as a branch: a short `<dst>` is matched against the
/// remote's refs, where `v1`, `tags/v1` or `heads/main` name something else.
fn explicit_branch(name: &str) -> Option<String> {
    name.strip_prefix("refs/heads/")
        .filter(|branch| plain(branch))
        .map(str::to_owned)
}

/// What a branch type says about one force push or deletion.
enum Outcome {
    /// The type is `none`, the destination is a branch and the floor leaves it alone.
    Allowed,
    Forbidden {
        branch: String,
        kind: String,
    },
    /// Everything else goes to the confirmation, as before types existed.
    Checked,
}

/// Decides one destination. Git is asked only when a type would allow or forbid, so with no
/// matching type a command is inspected exactly as before types existed.
fn outcome(
    types: &BranchTypes,
    allow: bool,
    candidate: Option<&str>,
    resolve: impl FnOnce() -> Result<Option<(String, String)>, String>,
    repo: &Repository,
) -> Result<Outcome, String> {
    let interesting = |name: &str| {
        types
            .matching(name)
            .is_some_and(|kind| matches!(kind.level, Level::None | Level::Forbid))
    };
    if !types.has_none_or_forbid() || candidate.is_some_and(|name| !interesting(name)) {
        return Ok(Outcome::Checked);
    }
    let Some((branch, remote)) = resolve()? else {
        return Ok(Outcome::Checked);
    };
    Ok(match types.matching(&branch) {
        Some(kind) if kind.level == Level::Forbid => Outcome::Forbidden {
            branch,
            kind: kind.name.clone(),
        },
        Some(kind) if kind.level == Level::None && allow && repo.below_floor(&remote, &branch) => {
            Outcome::Allowed
        }
        _ => Outcome::Checked,
    })
}

#[derive(Default)]
struct Context {
    switched: String,
    deleted_tags: HashSet<String>,
    deleted_branches: HashSet<String>,
}

impl Context {
    fn checkout(&mut self, args: &[String]) {
        if args.iter().any(|w| w == "--") {
            return;
        }
        let tracking = args.iter().any(|w| matches!(w.as_str(), "-t" | "--track"));
        for (i, word) in args.iter().enumerate() {
            if matches!(word.as_str(), "-b" | "-B" | "-c" | "-C") {
                self.switched = args.get(i + 1).cloned().unwrap_or_default();
                break;
            }
            if !word.starts_with('-') {
                let branch = if tracking {
                    word.split_once('/').map_or(word.as_str(), |(_, tail)| tail)
                } else {
                    word
                };
                branch.clone_into(&mut self.switched);
            }
        }
    }
}

// Each flag mirrors an independent Git push option; several can apply to one command.
#[allow(clippy::struct_excessive_bools)]
#[derive(Default)]
struct Push<'a> {
    dry: bool,
    force: bool,
    all: bool,
    delete: bool,
    tags_only: bool,
    prune: bool,
    remote_option: Option<&'a str>,
    operands: Vec<&'a str>,
    /// Set by any option outside the few a branch type may let through without a window.
    unusual: bool,
}

/// Whether an argument of `git push` can do more than force or delete the named refs. Only a
/// push made of plain options and ref names may skip the window; `--mirror`, `--tags`,
/// `--all`, `--prune`, `--receive-pack`, submodule pushes and anything unknown may not.
fn unusual(arg: &str) -> bool {
    if !arg.starts_with('-') || arg == "--" {
        return false;
    }
    if let Some(letters) = arg.strip_prefix('-').filter(|rest| !rest.starts_with('-')) {
        return !letters.bytes().all(|letter| b"fduqv".contains(&letter));
    }
    let name = arg.split_once('=').map_or(arg, |(option, _)| option);
    !matches!(
        name,
        "--force"
            | "--force-with-lease"
            | "--force-if-includes"
            | "--delete"
            | "--set-upstream"
            | "--quiet"
            | "--verbose"
            | "--no-verify"
            | "--progress"
            | "--no-progress"
            | "--porcelain"
    )
}

fn abbreviated(arg: &str, names: &[&str]) -> bool {
    let name = arg.split_once('=').map_or(arg, |(option, _)| option);
    name.starts_with("--") && name.len() > 2 && names.iter().any(|full| full.starts_with(name))
}

impl<'a> Push<'a> {
    fn operand(&mut self, arg: &'a str) {
        let reference = if let Some(reference) = arg.strip_prefix('+') {
            self.force = true;
            reference
        } else {
            arg
        };
        self.operands.push(reference);
    }

    fn parse(arguments: &'a [String]) -> Self {
        let mut push = Self {
            unusual: arguments.iter().any(|arg| unusual(arg)),
            ..Self::default()
        };
        let mut args = arguments.iter();
        while let Some(arg) = args.next() {
            let arg = arg.as_str();
            if arg == "--" {
                for operand in args {
                    push.operand(operand);
                }
                break;
            }
            if arg == "-n" || (arg.starts_with("--dr") && "--dry-run".starts_with(arg)) {
                push.dry = true;
            } else if arg.starts_with("--no-dr") && "--no-dry-run".starts_with(arg) {
                push.dry = false;
            } else if abbreviated(
                arg,
                &[
                    "--force",
                    "--force-if-includes",
                    "--force-with-lease",
                    "--mirror",
                ],
            ) {
                push.force = true;
            } else if abbreviated(arg, &["--all", "--branches"]) {
                push.all = true;
            } else if matches!(arg, "--prune" | "--prun" | "--pru") {
                push.prune = true;
            } else if matches!(arg, "--no-prune" | "--no-prun" | "--no-pru") {
                push.prune = false;
            } else if abbreviated(arg, &["--delete"]) {
                push.delete = true;
            } else if abbreviated(arg, &["--tags"]) {
                push.tags_only = true;
            } else if abbreviated(arg, &["--no-tags"]) {
                push.tags_only = false;
            } else if abbreviated(arg, &["--repo"]) {
                push.remote_option = match arg.split_once('=') {
                    Some((_, value)) => Some(value),
                    None => args.next().map(String::as_str),
                };
            } else if arg == "-o"
                || abbreviated(arg, &["--receive-pack", "--exec", "--push-option"])
            {
                if !arg.contains('=') {
                    args.next();
                }
            } else if let Some(letters) = arg.strip_prefix('-').filter(|s| !s.is_empty()) {
                if !letters.starts_with('-') {
                    let mut letters = letters.bytes();
                    while let Some(letter) = letters.next() {
                        match letter {
                            b'o' => {
                                if letters.len() == 0 {
                                    args.next();
                                }
                                break;
                            }
                            b'n' => push.dry = true,
                            b'f' => push.force = true,
                            b'd' => push.delete = true,
                            _ => {}
                        }
                    }
                }
            } else {
                push.operand(arg);
            }
        }
        push
    }

    fn risks(
        &self,
        repo: &Repository,
        context: &Context,
        overrides: bool,
        types: &BranchTypes,
        sole: bool,
    ) -> Result<Verdict, String> {
        let mut verdict = Verdict::default();
        if self.dry {
            return Ok(verdict);
        }
        // What the hook reads (HEAD, refs, configuration, the folder) must be what the push
        // will see, so only a lone `git push` of plain options may skip the window.
        let allow = sole && !self.unusual && context.switched.is_empty();
        let risks = &mut verdict.risks;
        if self.prune {
            risks.push("push --prune may delete remote branches or tags".into());
        }
        if self.all {
            risks.push("push --all includes main/master".into());
        }
        let remote = self.operands.first().copied().or(self.remote_option);
        let refspecs = self.operands.get(1..).unwrap_or_default();
        let implicit = refspecs.is_empty() && !self.tags_only && !self.all;
        if overrides {
            risks.push("command-local Git configuration may override push routing".into());
        }
        risks.extend(repo.push_config_risks(remote, refspecs, implicit)?);
        // A force push goes without a window only when every destination it rewrites is a
        // branch whose type says `none`; anything unproven keeps the check.
        let mut forced = Vec::new();
        let mut tag = false;
        for &reference in refspecs {
            if reference == "tag" {
                tag = true;
                continue;
            }
            let delete = if self.delete {
                Some(reference)
            } else {
                reference.strip_prefix(':')
            };
            if let Some(name) = delete.filter(|name| !name.is_empty()) {
                let decided = if tag {
                    Outcome::Checked
                } else {
                    deleted(repo, types, allow, remote, name)?
                };
                verdict.delete(decided, || deletion(repo, context, name, tag))?;
            } else if reference == ":" || reference.contains('*') {
                verdict
                    .risks
                    .push("pushes matching branches, main/master included".into());
                forced.push(Outcome::Checked);
            } else {
                let destination = reference
                    .split_once(':')
                    .map_or(
                        reference,
                        |(source, dest)| {
                            if dest.is_empty() { source } else { dest }
                        },
                    );
                if protected(destination) {
                    verdict.risks.push("push targets main/master".into());
                } else if matches!(destination, "HEAD" | "@")
                    || destination.contains("$(")
                    || destination.contains('`')
                {
                    let branch = repo.branch(context)?;
                    if matches!(branch.as_str(), "main" | "master") {
                        verdict
                            .risks
                            .push(format!("pushes the current branch '{branch}' (protected)"));
                    }
                }
                if self.force && !self.delete {
                    forced.push(if tag {
                        Outcome::Checked
                    } else {
                        let local = !reference.contains(':');
                        rewritten(repo, types, allow, remote, local, destination)?
                    });
                }
            }
            tag = false;
        }
        if implicit {
            self.current_branch(repo, context, types, allow, &mut verdict, &mut forced)?;
        }
        if self.force {
            verdict.force(forced, usize::from(self.prune));
        }
        Ok(verdict)
    }
}

impl Push<'_> {
    /// A push without refspecs, which goes to the current branch.
    fn current_branch(
        &self,
        repo: &Repository,
        context: &Context,
        types: &BranchTypes,
        allow: bool,
        verdict: &mut Verdict,
        forced: &mut Vec<Outcome>,
    ) -> Result<(), String> {
        let branch = repo.branch(context)?;
        if matches!(branch.as_str(), "main" | "master") {
            verdict
                .risks
                .push(format!("current branch is '{branch}' (protected)"));
        }
        if self.force && !self.delete {
            let remote = self.operands.first().copied().or(self.remote_option);
            forced.push(outcome(
                types,
                allow,
                Some(&branch),
                || {
                    let Some(branch) = repo.local_branch("HEAD")? else {
                        return Ok(None);
                    };
                    let remote = match remote {
                        Some(remote) => remote.to_owned(),
                        None => repo.implicit_remote(&branch)?,
                    };
                    Ok(Some((branch, remote)))
                },
                repo,
            )?);
        }
        Ok(())
    }
}

/// How a deletion of `name` is decided.
fn deleted(
    repo: &Repository,
    types: &BranchTypes,
    allow: bool,
    remote: Option<&str>,
    name: &str,
) -> Result<Outcome, String> {
    outcome(
        types,
        allow,
        Some(name.strip_prefix("refs/heads/").unwrap_or(name)),
        || {
            Ok(remote
                .zip(explicit_branch(name))
                .map(|(remote, branch)| (branch, remote.to_owned())))
        },
        repo,
    )
}

/// How a force push of `source` to `destination` is decided.
fn rewritten(
    repo: &Repository,
    types: &BranchTypes,
    allow: bool,
    remote: Option<&str>,
    local: bool,
    destination: &str,
) -> Result<Outcome, String> {
    let candidate = (!matches!(destination, "HEAD" | "@")).then(|| {
        destination
            .strip_prefix("refs/heads/")
            .unwrap_or(destination)
    });
    outcome(
        types,
        allow,
        candidate,
        || {
            let Some(remote) = remote else {
                return Ok(None);
            };
            // `name:name` is not a local push: its `<dst>` is matched on the remote.
            let branch = if local {
                repo.local_branch(destination)?
            } else {
                explicit_branch(destination)
            };
            Ok(branch.map(|branch| (branch, remote.to_owned())))
        },
        repo,
    )
}

/// Why a command is denied: risks go to the confirmation window, forbidden operations go
/// nowhere but a person's terminal.
#[derive(Default)]
pub(super) struct Verdict {
    pub risks: Vec<String>,
    pub forbidden: Vec<String>,
}

impl Verdict {
    fn delete(
        &mut self,
        decided: Outcome,
        risk: impl FnOnce() -> Result<String, String>,
    ) -> Result<(), String> {
        match decided {
            Outcome::Allowed => {}
            Outcome::Forbidden { branch, kind } => self.forbidden.push(format!(
                "deleting branch '{branch}' is forbidden by branch type '{kind}'"
            )),
            Outcome::Checked => self.risks.push(risk()?),
        }
        Ok(())
    }

    /// A force push keeps its risk unless every destination it rewrites was allowed.
    fn force(&mut self, forced: Vec<Outcome>, position: usize) {
        let mut checked = forced.is_empty();
        for decided in forced {
            match decided {
                Outcome::Allowed => {}
                Outcome::Forbidden { branch, kind } => self.forbidden.push(format!(
                    "force push to '{branch}' is forbidden by branch type '{kind}'"
                )),
                Outcome::Checked => checked = true,
            }
        }
        if checked {
            self.risks.insert(position, "force push".into());
        }
    }
}

fn deletion(repo: &Repository, context: &Context, name: &str, tag: bool) -> Result<String, String> {
    if protected(name) {
        return Ok("push targets main/master".into());
    }
    let short = basename(name);
    if name.starts_with("refs/tags/") || tag || context.deleted_tags.contains(name) {
        return Ok(format!("deletes tag '{short}' on the remote"));
    }
    if name.starts_with("refs/heads/") || context.deleted_branches.contains(name) {
        return Ok(format!("deletes branch '{short}' on the remote"));
    }
    if repo.known_branch(name)? {
        return Ok(format!("deletes branch '{name}' on the remote"));
    }
    if name
        .strip_prefix('v')
        .unwrap_or(name)
        .chars()
        .next()
        .is_some_and(char::is_numeric)
        || repo
            .query(&[
                "show-ref",
                "--verify",
                "--quiet",
                &format!("refs/tags/{name}"),
            ])?
            .status
            .success()
    {
        return Ok(format!("deletes tag '{name}' on the remote"));
    }
    Ok(format!(
        "deletes '{name}' on the remote; it is not a known branch, so it may be a tag"
    ))
}

fn resolve(path: &str, cwd: &Path, home: &Path) -> PathBuf {
    match path {
        "~" => home.to_owned(),
        _ if path.starts_with("~/") => home.join(&path[2..]),
        _ => cwd.join(path),
    }
}

fn repository(here: &Path, home: &Path, prefix: &[String], options: &[String]) -> PathBuf {
    let mut folder = here.to_owned();
    let mut git_dir = prefix
        .iter()
        .filter(|w| !w.contains('$'))
        .filter_map(|w| w.strip_prefix("GIT_DIR="))
        .next_back()
        .unwrap_or("");
    for (i, option) in options.iter().enumerate() {
        let value = options.get(i + 1).filter(|w| !w.is_empty());
        if option == "-C"
            && let Some(path) = value
        {
            folder = resolve(path, &folder, home);
        } else if option == "--git-dir"
            && let Some(path) = value
        {
            git_dir = path;
        } else if let Some(path) = option.strip_prefix("--git-dir=") {
            git_dir = path;
        }
    }
    if git_dir.is_empty() {
        folder
    } else {
        resolve(git_dir, &folder, home)
    }
}

pub(super) fn check(
    parsed: Parsed,
    literal: bool,
    cwd: &Path,
    home: &Path,
    cancel: &Cancellation,
    deadline: Instant,
) -> Result<Verdict, String> {
    let mut folders = vec![None; parsed.parents.len()];
    folders[0] = Some(cwd.to_owned());
    let mut context = Context::default();
    let mut types = None;
    let mut verdict = Verdict::default();
    let mut seen = HashSet::new();
    let alone = literal && parsed.total == 1 && parsed.commands.len() == 1;
    for command in parsed.commands {
        if Instant::now() >= deadline {
            return Err(super::TIMEOUT.into());
        }
        let mut ancestor = command.scope;
        while folders[ancestor].is_none() {
            ancestor = parsed.parents[ancestor];
        }
        let here = folders[ancestor].as_deref().unwrap_or(cwd).to_owned();
        folders[command.scope] = Some(here.clone());
        let i = command_index(&command.words);
        let name = basename(&command.words[i]);
        let args = &command.words[i + 1..];
        if matches!(name, "cd" | "pushd") {
            if let Some(path) = args.first().filter(|w| !w.contains('$')) {
                folders[command.scope] = Some(resolve(path, &here, home));
            }
            continue;
        }
        let pos = git_subcommand(args);
        let Some((sub, rest)) = args[pos..].split_first() else {
            continue;
        };
        match sub.as_str() {
            "checkout" | "switch" => context.checkout(rest),
            "branch"
                if rest
                    .iter()
                    .any(|w| matches!(w.as_str(), "-d" | "-D" | "--delete")) =>
            {
                context
                    .deleted_branches
                    .extend(rest.iter().filter(|w| !w.starts_with('-')).cloned());
            }
            "tag" if rest.iter().any(|w| matches!(w.as_str(), "-d" | "--delete")) => context
                .deleted_tags
                .extend(rest.iter().filter(|w| !w.starts_with('-')).cloned()),
            "push" => {
                let prefix = &command.words[..i];
                let options = &args[..pos];
                let path = repository(&here, home, prefix, options);
                let overrides = options.iter().any(|word| {
                    word.starts_with("-c")
                        || word == "--config-env"
                        || word.starts_with("--config-env=")
                }) || prefix.iter().any(|word| {
                    word.starts_with("GIT_CONFIG") || word.starts_with("GIT_NAMESPACE=")
                });
                let found = Push::parse(rest).risks(
                    &Repository {
                        path: &path,
                        cancel,
                        deadline,
                    },
                    &context,
                    overrides,
                    types.get_or_insert_with(BranchTypes::load),
                    alone && i == 0 && pos == 0 && command.words[0] == "git",
                )?;
                for risk in found.risks {
                    if seen.insert(risk.clone()) {
                        verdict.risks.push(risk);
                    }
                }
                for refusal in found.forbidden {
                    if seen.insert(refusal.clone()) {
                        verdict.forbidden.push(refusal);
                    }
                }
            }
            _ => {}
        }
    }
    Ok(verdict)
}
