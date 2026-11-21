use crate::execution::{Env, executable, isolated, output};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

type Refs = BTreeMap<String, String>;
const BASELINE: &str = "fixture-before.json";
const FORMAT: &str = "agent-watch-desktop-git-v1";

#[cfg(windows)]
fn local_drive(path: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use std::path::{Component, Prefix};
    use windows_sys::Win32::Storage::FileSystem::GetDriveTypeW;
    let drive = match path.components().next() {
        Some(Component::Prefix(prefix)) => match prefix.kind() {
            Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => drive,
            _ => anyhow::bail!("Choose a local drive, not a network path."),
        },
        _ => anyhow::bail!("Missing drive letter"),
    };
    let root: Vec<u16> = std::ffi::OsStr::new(&format!("{}:\\", drive as char))
        .encode_wide()
        .chain(Some(0))
        .collect();
    // GetDriveTypeW needs a NUL-terminated drive root; root lives through the call.
    let kind = unsafe { GetDriveTypeW(root.as_ptr()) };
    ensure!(kind != 4 && kind > 1, "Choose a local drive.");
    Ok(())
}

fn canonical(path: &Path) -> Result<PathBuf> {
    #[cfg(windows)]
    {
        Ok(dunce::canonicalize(path)?)
    }
    #[cfg(not(windows))]
    {
        Ok(path.canonicalize()?)
    }
}

fn folder(path: &Path) -> Result<PathBuf> {
    ensure!(
        !path.to_string_lossy().contains(['\r', '\n']),
        "Line breaks in fixture path"
    );
    let path = std::path::absolute(path)?;
    #[cfg(windows)]
    local_drive(&path)?;
    let parent = canonical(
        path.parent()
            .context("Name a fixture directory below its parent")?,
    )?;
    let result = parent.join(path.file_name().context("Missing fixture name")?);
    #[cfg(windows)]
    local_drive(&result)?;
    ensure!(
        !result.is_symlink(),
        "The fixture directory is a symbolic link"
    );
    Ok(result)
}

pub(crate) struct Fixture {
    pub repo: PathBuf,
    pub remote: PathBuf,
    pub env: Env,
    root: PathBuf,
    git: PathBuf,
}

impl Fixture {
    fn at(root: PathBuf) -> Result<Self> {
        let git = executable("git")?;
        let home = root.join("home");
        let temp = root.join("tmp");
        let mut env = Env::new();
        for key in ["HOME", "USERPROFILE"] {
            env.insert(key.into(), home.clone().into());
        }
        for key in ["TMPDIR", "TEMP", "TMP"] {
            env.insert(key.into(), temp.clone().into());
        }
        env.insert("XDG_CONFIG_HOME".into(), home.join(".config").into());
        env.insert("GIT_CONFIG_GLOBAL".into(), home.join(".gitconfig").into());
        for (key, value) in [
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("GIT_ATTR_NOSYSTEM", "1"),
            ("GIT_TERMINAL_PROMPT", "0"),
            ("GIT_ALLOW_PROTOCOL", "file"),
            ("GIT_OPTIONAL_LOCKS", "0"),
            ("LANG", "C"),
        ] {
            env.insert(key.into(), value.into());
        }
        let mut paths = vec![git.parent().context("Missing Git directory")?.to_owned()];
        #[cfg(not(windows))]
        paths.extend(["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map(PathBuf::from));
        #[cfg(windows)]
        {
            let windows =
                PathBuf::from(std::env::var_os("SystemRoot").context("Missing SystemRoot")?);
            paths.extend([windows.join("System32"), windows.clone()]);
            for key in ["SystemRoot", "WINDIR"] {
                env.insert(key.into(), windows.clone().into());
            }
            env.insert("COMSPEC".into(), windows.join("System32/cmd.exe").into());
            env.insert("APPDATA".into(), home.join("AppData/Roaming").into());
            env.insert("LOCALAPPDATA".into(), home.join("AppData/Local").into());
            if let Some((drive, tail)) = home.to_string_lossy().split_once(':') {
                env.insert("HOMEDRIVE".into(), format!("{drive}:").into());
                env.insert("HOMEPATH".into(), tail.into());
            }
        }
        env.insert("PATH".into(), std::env::join_paths(paths)?);
        Ok(Self {
            repo: root.join("project"),
            remote: root.join("remote.git"),
            env,
            root,
            git,
        })
    }

    fn git(&self, cwd: &Path, args: &[&str]) -> Result<String> {
        output(
            isolated(&self.git, cwd, &self.env).args(args),
            Duration::from_secs(90),
        )
    }

    pub fn snapshot(&self) -> Result<Refs> {
        for path in [&self.remote, &self.repo] {
            ensure!(
                path.is_dir() && !path.is_symlink(),
                "Missing local fixture repository: {}",
                path.display()
            );
        }
        let git_dir = self.git(&self.remote, &["rev-parse", "--absolute-git-dir"])?;
        let tree = self.git(&self.repo, &["rev-parse", "--show-toplevel"])?;
        let url = self.git(
            &self.repo,
            &["remote", "get-url", "--push", "--all", "origin"],
        )?;
        ensure!(
            canonical(Path::new(&git_dir))? == self.remote
                && canonical(Path::new(&tree))? == self.repo
                && url.lines().count() == 1
                && Path::new(&url) == self.remote
                && self.git(&self.remote, &["rev-parse", "--is-bare-repository"])? == "true",
            "The fixture repositories or the push destination changed"
        );
        let mut refs = Refs::new();
        refs.insert(
            "HEAD".into(),
            self.git(&self.remote, &["symbolic-ref", "HEAD"])?,
        );
        for row in self
            .git(
                &self.remote,
                &["for-each-ref", "--format=%(refname) %(objectname)"],
            )?
            .lines()
        {
            let (name, oid) = row.split_once(' ').context("Invalid ref listing")?;
            refs.insert(name.into(), oid.into());
        }
        Ok(refs)
    }

    #[cfg(target_os = "macos")]
    pub fn home(&self) -> PathBuf {
        self.root.join("home")
    }
}

pub(crate) fn prepare(path: &Path) -> Result<Fixture> {
    let root = folder(path)?;
    fs::create_dir(&root).with_context(|| format!("Creating new fixture at {}", root.display()))?;
    let f = Fixture::at(root)?;
    fs::create_dir(f.root.join("tmp"))?;
    fs::create_dir(f.root.join("home"))?;
    f.git(&f.root, &["init", "--template=", "-b", "trunk", "project"])?;
    f.git(
        &f.repo,
        &[
            "-c",
            "user.name=Probe",
            "-c",
            "user.email=probe@example.invalid",
            "commit",
            "--allow-empty",
            "-m",
            "Synthetic fixture",
        ],
    )?;
    for name in ["feature/example", "main", "release"] {
        f.git(&f.repo, &["branch", name])?;
    }
    f.git(
        &f.root,
        &[
            "clone",
            "--bare",
            "--no-local",
            "--template=",
            "--",
            "project",
            "remote.git",
        ],
    )?;
    output(
        isolated(&f.git, &f.repo, &f.env)
            .args(["remote", "add", "origin"])
            .arg(&f.remote),
        Duration::from_secs(90),
    )?;
    f.git(
        &f.repo,
        &["config", "--local", "mothership.protectedBranch", "release"],
    )?;
    let refs = f.snapshot()?;
    let mut file = fs::File::create_new(f.root.join(BASELINE))?;
    writeln!(
        file,
        "{}",
        serde_json::to_string_pretty(&json!({"format":FORMAT,"remoteRefs":refs}))?
    )?;
    println!(
        "Desktop project: {}\nLocal remote: {}",
        f.repo.display(),
        f.remote.display()
    );
    for (name, oid) in refs {
        println!("{name}  {oid}");
    }
    Ok(f)
}

pub(crate) fn status(path: &Path) -> Result<bool> {
    let f = Fixture::at(folder(path)?)?;
    let record = f.root.join(BASELINE);
    ensure!(
        record.is_file() && !record.is_symlink(),
        "Missing local fixture baseline"
    );
    let record: Value = serde_json::from_slice(&fs::read(record)?)?;
    ensure!(record["format"] == FORMAT, "Unknown fixture baseline");
    let before: Refs = serde_json::from_value(record["remoteRefs"].clone())?;
    let now = f.snapshot()?;
    let names = before
        .keys()
        .chain(now.keys())
        .collect::<std::collections::BTreeSet<_>>();
    for name in names {
        if before.get(name) != now.get(name) {
            println!(
                "CHANGED {name}  {} -> {}",
                before.get(name).map_or("(absent)", String::as_str),
                now.get(name).map_or("(absent)", String::as_str)
            );
        } else {
            println!("{name}  {}", now[name]);
        }
    }
    if now == before {
        println!("Remote references match the baseline.");
    } else {
        println!("Remote references changed.");
    }
    Ok(now == before)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_detects_a_new_remote_ref_and_prepare_preserves_existing_data() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let dir = temp.path().join("fixture with spaces");
        let fixture = prepare(&dir)?;
        assert!(prepare(&dir).is_err());
        assert!(status(&dir)?);
        let old = fixture.snapshot()?;
        assert_eq!(old["HEAD"], "refs/heads/trunk");
        fixture.git(
            &fixture.remote,
            &["update-ref", "refs/heads/new", "refs/heads/main"],
        )?;
        assert!(!status(&dir)?);
        Ok(())
    }

    #[test]
    fn refuses_to_inspect_changed_push_destination() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let dir = temp.path().join("fixture");
        let fixture = prepare(&dir)?;
        fixture.git(
            &fixture.repo,
            &["remote", "set-url", "--push", "origin", "unused"],
        )?;
        assert!(fixture.snapshot().is_err());
        Ok(())
    }
}
