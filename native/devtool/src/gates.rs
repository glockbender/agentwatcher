//! Repository-local Git gates. Verify the same tree that Git is about to record or send.
use std::{
    io::{self, BufRead},
    process::Command,
};

fn git(args: &[&str]) -> Result<Vec<u8>, String> {
    let output = Command::new("git")
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).into_owned());
    }
    Ok(output.stdout)
}

fn needs_branch_check(lines: impl BufRead, head: &str) -> Result<bool, String> {
    let mut branches = false;
    for line in lines.lines() {
        let line = line.map_err(|e| e.to_string())?;
        let fields: Vec<_> = line.split_whitespace().collect();
        let [_, local, remote, _] = fields.as_slice() else {
            return Err("Invalid Git pre-push input".into());
        };
        if local.bytes().all(|b| b == b'0') || remote.starts_with("refs/tags/") {
            continue;
        }
        if *local != head {
            return Err(
                "pre-push: check out the commit being pushed before running the gate".into(),
            );
        }
        branches = true;
    }
    Ok(branches)
}

// Git exports its repository location to hooks. Every test Git process must discover its own working directory.
fn isolate_repository(command: &mut Command) -> Result<(), String> {
    let names = git(&["rev-parse", "--local-env-vars"])?;
    for name in String::from_utf8(names).map_err(|e| e.to_string())?.lines() {
        command.env_remove(name);
    }
    Ok(())
}

pub fn run(command: &str) -> Result<(), String> {
    let pushing = command == "pre-push";
    if pushing {
        let head = git(&["rev-parse", "HEAD"])?;
        if !needs_branch_check(io::stdin().lock(), String::from_utf8_lossy(&head).trim())? {
            println!("pre-push: only tags or deletions; skipping the branch gate");
            return Ok(());
        }
    }
    let mut diff = Command::new("git");
    diff.args(["diff", "--quiet"]);
    if pushing {
        diff.arg("HEAD");
    }
    if !diff.status().map_err(|e| e.to_string())?.success()
        || !git(&["ls-files", "--others", "--exclude-standard", "-z"])?.is_empty()
    {
        return Err(format!(
            "{command}: the working tree contains changes outside the commit being checked"
        ));
    }
    let task = if pushing { "verify-all" } else { "verify" };
    let mut checks = Command::new("task");
    if std::env::var_os("GIT_INDEX_FILE").is_some() {
        let index = git(&["rev-parse", "--path-format=absolute", "--git-path", "index"])?;
        checks.env(
            "AGENT_WATCH_VERIFY_INDEX",
            String::from_utf8(index)
                .map_err(|e| e.to_string())?
                .trim_end_matches('\n'),
        );
    }
    isolate_repository(&mut checks)?;
    let status = checks.arg(task).status().map_err(|e| e.to_string())?;
    if !status.success() {
        return Err(format!("task {task}: {status}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_git_discovers_its_fixture_when_started_from_a_repository_hook() {
        let scratch = Command::new("mktemp")
            .args(["-d", "-t", "agent-watch-gate"])
            .output()
            .unwrap();
        assert!(scratch.status.success());
        let dir = std::path::PathBuf::from(String::from_utf8(scratch.stdout).unwrap().trim());
        let git_in_fixture = |args: &[&str]| {
            let mut command = Command::new("git");
            command
                .current_dir(&dir)
                .args(args)
                .env("GIT_DIR", dir.join("unrelated-metadata"))
                .env("GIT_WORK_TREE", dir.join("unrelated-checkout"))
                .env("GIT_INDEX_FILE", dir.join("unrelated-index"));
            isolate_repository(&mut command).unwrap();
            let output = command.output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap()
        };
        git_in_fixture(&["init", "-q", "--template="]);
        let top = git_in_fixture(&["rev-parse", "--show-toplevel"]);
        assert_eq!(
            std::fs::canonicalize(top.trim()).unwrap(),
            std::fs::canonicalize(&dir).unwrap()
        );
        assert!(dir.join(".git").is_dir());
        assert!(!dir.join("unrelated-metadata").exists());
        #[cfg(target_os = "macos")]
        assert!(
            Command::new("/usr/bin/trash")
                .arg(dir)
                .status()
                .unwrap()
                .success()
        );
    }
    #[test]
    fn a_mixed_push_checks_only_the_branches_being_sent() {
        assert!(
            !needs_branch_check(
                "tag def refs/tags/v1 000\nold 000 refs/heads/old abc\n".as_bytes(),
                "abc"
            )
            .unwrap()
        );
        assert!(
            needs_branch_check(
                "tag def refs/tags/v1 000\nmain abc refs/heads/main def\n".as_bytes(),
                "abc"
            )
            .unwrap()
        );
        assert!(needs_branch_check("old def refs/heads/old abc\n".as_bytes(), "abc").is_err());
    }
}
