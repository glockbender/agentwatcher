use crate::domain::{Arguments, Plan, Risk, repository_name, valid_oid, valid_text};
use crate::levels::{self, BranchTypes, Level};
use crate::process::{self, Cancellation, Output};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// How long one preparation step may take: it reads the repository or asks the remote.
const STEP_SECONDS: u64 = 30;

/// Names the git subcommand and why it stopped, so one failure can be told from
/// another. Only the subcommand: its arguments may hold a remote URL.
///
/// `step_deadline_first` says the step's own deadline came before the confirmation's:
/// then an expiry is the step running out of time. The decision rests on the reason,
/// not on the clock, so a cancellation just before the deadline still reads as one.
fn preparation_failure(
    args: &[&str],
    error: &process::RunError,
    step_deadline_first: bool,
) -> String {
    let mut rest = args;
    while let ["-c", _, tail @ ..] = rest {
        rest = tail;
    }
    let name = rest.first().copied().unwrap_or("?");
    let why = match error {
        process::RunError::Interrupted(reason)
            if step_deadline_first && reason == process::EXPIRED =>
        {
            format!("it did not finish in {STEP_SECONDS} seconds")
        }
        process::RunError::NotStarted(reason)
        | process::RunError::SpawnFailed(reason)
        | process::RunError::Interrupted(reason) => reason.trim_end_matches('.').to_owned(),
    };
    format!("Git could not finish preparation: `git {name}` stopped ({why}); nothing was pushed.")
}

pub struct Git {
    binary: String,
    environment: Vec<(OsString, OsString)>,
    cancel: Cancellation,
    deadline: Instant,
}

impl Git {
    pub fn new(cancel: Cancellation, deadline: Instant) -> Result<Self, String> {
        let binary = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
            .map(|p| p.join("git"))
            .find(|p| p.is_file())
            .and_then(|p| p.canonicalize().ok())
            .and_then(|p| p.to_str().map(str::to_owned))
            .ok_or("Git is not installed.")?;
        let mut environment: Vec<_> = std::env::vars_os()
            .filter(|(key, _)| !key.to_string_lossy().starts_with("GIT_"))
            .collect();
        for (key, value) in [
            ("GIT_TERMINAL_PROMPT", "0"),
            ("GIT_ALLOW_PROTOCOL", "https:ssh:file"),
            ("GIT_NO_REPLACE_OBJECTS", "1"),
            ("GIT_SSH_COMMAND", "ssh -oBatchMode=yes"),
        ] {
            environment.push((key.into(), value.into()));
        }
        Ok(Self {
            binary,
            environment,
            cancel,
            deadline,
        })
    }

    pub fn command(&self, args: &[String]) -> Command {
        let mut command = Command::new(&self.binary);
        command
            .args(args)
            .env_clear()
            .envs(self.environment.iter().cloned());
        command
    }

    fn run(&self, repo: &str, args: &[&str]) -> Result<Output, String> {
        let command: Vec<String> = ["-C", repo]
            .into_iter()
            .chain(args.iter().copied())
            .map(str::to_owned)
            .collect();
        let step = Instant::now() + Duration::from_secs(STEP_SECONDS);
        process::run(
            &mut self.command(&command),
            &self.cancel,
            self.deadline.min(step),
            self.deadline,
        )
        .map_err(|error| preparation_failure(args, &error, step <= self.deadline))
    }

    fn read(&self, repo: &str, args: &[&str]) -> Result<String, String> {
        let output = self.run(repo, args)?;
        if !output.status.success() {
            return Err(
                "Git could not inspect the repository or destination; nothing was pushed.".into(),
            );
        }
        Ok(output
            .stdout
            .strip_suffix('\n')
            .unwrap_or(&output.stdout)
            .into())
    }

    fn identity(&self, repo: &str, remote: &str) -> Result<(String, String, String), String> {
        let root = canonical(&self.read(repo, &["rev-parse", "--show-toplevel"])?)?;
        let directory = canonical(&self.read(&root, &["rev-parse", "--absolute-git-dir"])?)?;
        let grafts =
            Path::new(&root).join(self.read(&root, &["rev-parse", "--git-path", "info/grafts"])?);
        if grafts.symlink_metadata().is_ok() {
            return Err(
                "Legacy Git grafts are unsupported; the real history must be checked.".into(),
            );
        }
        let unsafe_config = self.run(&root, &["config", "--get-regexp", r"^(url\..*\.(insteadof|pushinsteadof)|core\.sshcommand|remote\..*\.(receivepack|uploadpack|vcs))$"])?;
        if unsafe_config.status.code() != Some(1) {
            return Err("Custom URL rewrites and transport commands are unsupported.".into());
        }
        // A remote from `.git/branches` or `.git/remotes` brings push refspecs that no
        // configuration read here can see, so only a remote defined in the config is used.
        let defined = self.run(&root, &["config", "--get", &format!("remote.{remote}.url")])?;
        // An empty value clears the list of URLs, and Git falls back to the legacy files.
        if !defined.status.success() || defined.stdout.trim().is_empty() {
            return Err("Only a remote defined in the Git configuration is supported.".into());
        }
        let urls = self.read(&root, &["remote", "get-url", "--push", "--all", remote])?;
        let urls: Vec<_> = urls.lines().collect();
        if urls.len() != 1 {
            return Err("Exactly one push URL is required.".into());
        }
        repository_name(urls[0])?;
        Ok((root, directory, urls[0].into()))
    }

    fn object(&self, repo: &str, source: &str, destination: &str) -> Result<String, String> {
        let kind = if destination.starts_with("refs/heads/") {
            "commit"
        } else {
            "object"
        };
        let oid = self.read(
            repo,
            &[
                "rev-parse",
                "--verify",
                "--end-of-options",
                &format!("{source}^{{{kind}}}"),
            ],
        )?;
        if !valid_oid(&oid) {
            return Err("Git returned an invalid source object identifier.".into());
        }
        Ok(oid)
    }

    fn protected_branch(&self, repo: &str, url: &str, destination: &str) -> Result<bool, String> {
        if main_branch(destination) {
            return Ok(true);
        }
        let advertised = self.read(repo, &["ls-remote", "--symref", "--", url, "HEAD"])?;
        let head = advertised
            .lines()
            .filter_map(|line| line.strip_prefix("ref: ")?.strip_suffix("\tHEAD"))
            .find(|reference| reference.starts_with("refs/heads/"));
        if head == Some(destination) {
            return Ok(true);
        }
        let configured = self.run(
            repo,
            &[
                "config",
                "--local",
                "--includes",
                "--null",
                "--get-all",
                "mothership.protectedBranch",
            ],
        )?;
        let branch = destination
            .strip_prefix("refs/heads/")
            .unwrap_or(destination);
        match configured.status.code() {
            Some(0)
                if configured
                    .stdout
                    .split_terminator('\0')
                    .any(|name| name == branch) =>
            {
                Ok(true)
            }
            Some(0 | 1) if head.is_some() => Ok(false),
            Some(0 | 1) => Err(
                "The remote did not advertise its default branch. The operation was stopped."
                    .into(),
            ),
            _ => Err("Git could not read the configured protected branches.".into()),
        }
    }

    /// The level of a force push or deletion of a branch. The remote is asked for its
    /// default branch only when the chosen level is below the floor, so an operation the
    /// branch types leave alone asks exactly what it asked before they existed.
    fn level(
        &self,
        repo: &str,
        url: &str,
        destination: &str,
        delete: bool,
    ) -> Result<(Level, Option<String>), String> {
        let branch = destination
            .strip_prefix("refs/heads/")
            .unwrap_or(destination);
        let types = BranchTypes::load();
        let common = if types.has_repository_rules() {
            Some(levels::canonical_directory(
                Path::new(repo),
                &self.read(repo, levels::COMMON_DIRECTORY_ARGS)?,
            )?)
        } else {
            None
        };
        let (chosen, kind) = levels::chosen(&types, branch, delete, common.as_deref());
        let level = if chosen < Level::Name {
            levels::with_floor(chosen, self.protected_branch(repo, url, destination)?)
        } else {
            chosen
        };
        Ok((level, kind))
    }

    /// The floor for the hook: whether `main`, `master`, the remote's default branch or a
    /// project rule protects the branch, asked through the same checked remote as a push.
    ///
    /// Git matches even a full `refs/heads/x` against the remote's refs by suffix, so a remote
    /// ref such as `refs/tags/refs/heads/x` would take the push: any listed ref other than the
    /// branch itself counts as protected, as it stops a push.
    pub fn protected(&self, repo: &str, remote: &str, branch: &str) -> Result<bool, String> {
        let (root, _, url) = self.identity(repo, remote)?;
        let destination = format!("refs/heads/{branch}");
        if self.protected_branch(&root, &url, &destination)? {
            return Ok(true);
        }
        let listing = self.read(&root, &["ls-remote", "--refs", "--", &url, &destination])?;
        Ok(listing
            .lines()
            .any(|line| line.split_once('\t').map(|(_, name)| name) != Some(destination.as_str())))
    }

    fn risks(args: &Arguments, level: Level) -> Vec<Risk> {
        if args.delete {
            let risk = if !args.destination.starts_with("refs/heads/") {
                Risk::DeleteTag
            } else if level >= Level::Name {
                Risk::DeleteProtectedBranch
            } else {
                Risk::DeleteBranch
            };
            return vec![risk];
        }
        let mut risks = Vec::new();
        if main_branch(&args.destination) {
            risks.push(Risk::ProtectedBranch);
        }
        if args.force {
            risks.push(Risk::ForceUpdate);
        }
        risks
    }

    fn pin_remote(&self, repo: &str, remote: &str, url: &str) -> Result<Vec<String>, String> {
        let key = format!("remote.{remote}.pushurl");
        let single: Vec<String> = vec![
            "-c".into(),
            format!("remote.{remote}.mirror=false"),
            "-c".into(),
            format!("{key}={url}"),
        ];
        let mut reset = vec!["-c".into(), format!("{key}=")];
        reset.extend(single.iter().cloned());
        let mut probe: Vec<&str> = reset.iter().map(String::as_str).collect();
        probe.extend(["remote", "get-url", "--push", "--all", remote]);
        let result = self.run(repo, &probe)?;
        if result.status.success() && result.stdout.lines().collect::<Vec<_>>() == [url] {
            return Ok(reset);
        }
        if self
            .run(repo, &["config", "--get-all", &key])?
            .status
            .code()
            != Some(1)
        {
            return Err("This Git cannot reset an existing pushurl safely. Use a newer Git or run the push manually; nothing was pushed.".into());
        }
        Ok(single)
    }

    fn validate(&self, args: &Arguments) -> Result<(), String> {
        if !Path::new(&args.repository).is_absolute() || !valid_text(&args.repository) {
            return Err("repository must be an absolute path without control characters.".into());
        }
        if !args
            .remote
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_alphanumeric())
            || !args
                .remote
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._/-".contains(&b))
        {
            return Err("remote must be a configured remote name, not a URL or an option.".into());
        }
        if !valid_text(&args.destination)
            || !args.destination.starts_with("refs/heads/")
                && !args.destination.starts_with("refs/tags/")
            || !self
                .run(&args.repository, &["check-ref-format", &args.destination])?
                .status
                .success()
        {
            return Err(
                "destination must be one valid explicit refs/heads/ or refs/tags/ ref.".into(),
            );
        }
        if args.delete && (args.force || args.source.is_some()) {
            return Err("A delete cannot also specify force or source.".into());
        }
        Ok(())
    }

    pub fn prepare(&self, args: &Arguments) -> Result<Plan, String> {
        self.validate(args)?;
        if let Some(reason) = &args.reason
            && (!valid_text(reason) || reason.chars().count() > 200)
        {
            return Err(
                "reason must contain 1 to 200 characters without control characters.".into(),
            );
        }
        let source = if args.delete {
            ""
        } else {
            args.source.as_deref().unwrap_or("HEAD")
        };
        if !args.delete && !valid_text(source) {
            return Err("source must be non-empty and contain no control characters.".into());
        }
        let (root, directory, url) = self.identity(&args.repository, &args.remote)?;
        let new = if args.delete {
            String::new()
        } else {
            self.object(&root, source, &args.destination)?
        };
        let listing = self.read(
            &root,
            &["ls-remote", "--refs", "--", &url, &args.destination],
        )?;
        let mut old = String::new();
        if !listing.is_empty() {
            let refs: Vec<_> = listing.lines().collect();
            if refs.len() != 1 {
                return Err("The destination returned more than the requested ref.".into());
            }
            let (oid, reference) = refs[0]
                .split_once('\t')
                .ok_or("Invalid remote ref listing.")?;
            if reference != args.destination || !valid_oid(oid) {
                return Err("The destination returned an invalid ref or object identifier.".into());
            }
            old = oid.into();
        }
        if args.delete && old.is_empty() {
            return Err("The ref to delete does not exist.".into());
        }
        if !old.is_empty() && old == new {
            return Err("The destination already points at this object; no push is needed.".into());
        }
        if !old.is_empty() && !args.delete && !args.force {
            if args.destination.starts_with("refs/tags/") {
                return Err(
                    "Replacing an existing tag requires force=true and explicit confirmation."
                        .into(),
                );
            }
            if !self
                .run(&root, &["merge-base", "--is-ancestor", &old, &new])?
                .status
                .success()
            {
                return Err("A normal push must preserve existing history. Fetch the remote ref first; if rewriting it is intended, request force=true.".into());
            }
        }
        let (level, branch_type) =
            if args.destination.starts_with("refs/heads/") && (args.delete || args.force) {
                self.level(&root, &url, &args.destination, args.delete)?
            } else {
                (Level::Name, None)
            };
        let risks = Self::risks(args, level);
        let options = self.pin_remote(&root, &args.remote, &url)?;
        let mut command = vec![self.binary.clone(), "-C".into(), root.clone()];
        command.extend(options.clone());
        command.extend([
            "push".into(),
            "--porcelain".into(),
            "--no-follow-tags".into(),
            "--recurse-submodules=no".into(),
            format!("--force-with-lease={}:{}", args.destination, old),
            "--".into(),
            args.remote.clone(),
            format!("{new}:{}", args.destination),
        ]);
        Ok(Plan {
            repository: root,
            git_directory: directory,
            remote: args.remote.clone(),
            name: repository_name(&url)?,
            url,
            destination: args.destination.clone(),
            source: source.into(),
            new,
            old,
            delete: args.delete,
            risks,
            level,
            branch_type,
            reason: args.reason.clone(),
            remote_options: options,
            command,
        })
    }

    pub fn unchanged(&self, plan: &Plan) -> Result<bool, String> {
        let approved_identity = (
            plan.repository.clone(),
            plan.git_directory.clone(),
            plan.url.clone(),
        );
        if self.identity(&plan.repository, &plan.remote)? != approved_identity {
            return Ok(false);
        }

        // The table can change while a window is open, and below the floor the remote can
        // start calling the branch its default. A level that rose stops the push.
        if plan.governed() {
            let (level, _) =
                self.level(&plan.repository, &plan.url, &plan.destination, plan.delete)?;
            // The remote HEAD lookup can block. Revalidate the destination after it.
            if level > plan.level
                || (level < Level::Name
                    && self.identity(&plan.repository, &plan.remote)? != approved_identity)
            {
                return Ok(false);
            }
        }

        Ok(
            self.pin_remote(&plan.repository, &plan.remote, &plan.url)? == plan.remote_options
                && (plan.delete
                    || self.object(&plan.repository, &plan.source, &plan.destination)? == plan.new),
        )
    }
}

fn canonical(path: &str) -> Result<String, String> {
    PathBuf::from(path)
        .canonicalize()
        .ok()
        .and_then(|p| p.to_str().map(str::to_owned))
        .ok_or_else(|| "The repository path could not be resolved.".into())
}

fn main_branch(destination: &str) -> bool {
    matches!(destination, "refs/heads/main" | "refs/heads/master")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::process::RunError;

    #[test]
    fn a_step_that_ran_out_of_time_says_how_long_it_had() {
        let error = RunError::Interrupted(crate::process::EXPIRED.into());
        let message = preparation_failure(&["ls-remote", "--", "https://x/y"], &error, true);
        assert!(message.contains("`git ls-remote` stopped (it did not finish in 30 seconds)"));
        assert!(!message.contains("https://x/y"), "{message}");
    }

    #[test]
    fn an_expired_confirmation_is_not_called_a_slow_step() {
        let error = RunError::Interrupted(crate::process::EXPIRED.into());
        let message = preparation_failure(&["ls-remote"], &error, false);
        assert!(message.contains("`git ls-remote` stopped (The confirmation expired)"));
    }

    #[test]
    fn a_cancellation_at_the_step_deadline_reads_as_a_cancellation() {
        let error = RunError::Interrupted("The request was cancelled.".into());
        let message = preparation_failure(&["fetch"], &error, true);
        assert!(message.contains("`git fetch` stopped (The request was cancelled)"));
    }

    #[test]
    fn config_overrides_are_skipped_when_naming_the_command() {
        let error = RunError::Interrupted("Git output could not be read.".into());
        let args = [
            "-c",
            "remote.origin.pushurl=",
            "-c",
            "a=b",
            "remote",
            "get-url",
        ];
        let message = preparation_failure(&args, &error, false);
        assert!(message.contains("`git remote` stopped (Git output could not be read)"));
    }
}
