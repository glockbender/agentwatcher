"""Prepare or inspect a local Git project for a manual desktop-client confirmation test."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


BASELINE = "fixture-before.json"
FORMAT = "agent-watch-desktop-git-v1"


def git_environment(folder):
    git = shutil.which("git.exe" if os.name == "nt" else "git")
    if not git:
        raise ValueError("Git was not found on PATH.")
    home = folder / "home"
    temp = folder / "tmp"
    paths = [str(Path(git).resolve().parent)]
    env = {
        "HOME": str(home), "USERPROFILE": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"), "GIT_CONFIG_NOSYSTEM": "1", "GIT_ATTR_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": "file", "GIT_OPTIONAL_LOCKS": "0",
        "TMPDIR": str(temp), "TEMP": str(temp), "TMP": str(temp), "LANG": "C",
    }
    if os.name == "nt":
        windows = Path(os.environ["SystemRoot"])
        paths.extend((str(windows / "System32"), str(windows)))
        env.update(SystemRoot=str(windows), WINDIR=str(windows), COMSPEC=str(windows / "System32" / "cmd.exe"),
                   APPDATA=str(home / "AppData" / "Roaming"), LOCALAPPDATA=str(home / "AppData" / "Local"),
                   HOMEDRIVE=home.drive, HOMEPATH=str(home)[len(home.drive):])
    else:
        paths.extend(os.defpath.split(os.pathsep))
    env["PATH"] = os.pathsep.join(paths)
    return str(Path(git).resolve()), env


def create_pair(folder, git, env):
    """Called only inside a new fixture, also by the macOS MCP probe."""
    repo = folder / "project"
    remote = folder / "remote.git"

    def run(cwd, *args):
        subprocess.run([git, *args], cwd=cwd, env=env, check=True, capture_output=True, timeout=20)

    run(folder, "init", "--template=", "-b", "trunk", str(repo))
    run(repo, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid",
        "commit", "--allow-empty", "-m", "Synthetic fixture")
    for branch in ("feature/example", "main", "release"):
        run(repo, "branch", branch)
    run(folder, "clone", "--bare", "--no-local", "--template=", "--", str(repo), str(remote))
    run(repo, "remote", "add", "origin", str(remote))
    run(repo, "config", "--local", "mothership.protectedBranch", "release")
    return repo, remote


def read_git(git, env, cwd, *arguments):
    result = subprocess.run([git, *arguments], cwd=cwd, env=env, check=True, capture_output=True, timeout=15)
    return result.stdout.decode("utf-8").removesuffix("\n").removesuffix("\r")


def snapshot(folder, git, env):
    repo, remote = folder / "project", folder / "remote.git"
    if repo.is_symlink() or remote.is_symlink() or not repo.is_dir() or not remote.is_dir():
        raise ValueError("Missing local fixture repositories.")
    # Inspect the bare repository directly, never a remote URL. Check the project still
    # belongs to this fixture before presenting it as the place for the manual test.
    git_dir = read_git(git, env, remote, "rev-parse", "--absolute-git-dir")
    tree = read_git(git, env, repo, "rev-parse", "--show-toplevel")
    push_urls = read_git(git, env, repo, "remote", "get-url", "--push", "--all", "origin").splitlines()
    if (Path(git_dir).resolve() != remote or Path(tree).resolve() != repo or len(push_urls) != 1
            or os.path.normcase(os.path.normpath(push_urls[0])) != os.path.normcase(str(remote))
            or read_git(git, env, remote, "rev-parse", "--is-bare-repository") != "true"):
        raise ValueError("The fixture repositories or the push destination changed.")
    refs = {"HEAD": read_git(git, env, remote, "symbolic-ref", "HEAD")}
    for line in read_git(git, env, remote, "for-each-ref", "--format=%(refname) %(objectname)").splitlines():
        name, oid = line.split(" ", 1)
        refs[name] = oid
    return refs


def require_local_drive(path):
    if os.name == "nt":
        import ctypes
        if path.drive.startswith("\\\\") or ctypes.windll.kernel32.GetDriveTypeW(path.anchor) == 4:
            raise ValueError("Choose a local drive. Network drives and UNC paths are not supported.")


def local_folder(path):
    if any(char in str(path) for char in "\r\n"):
        raise ValueError("Choose a fixture path without line breaks.")
    require_local_drive(path.absolute())
    folder = path.parent.resolve(strict=True) / path.name
    require_local_drive(folder)
    if folder.is_symlink():
        raise ValueError("Choose a local fixture directory, not a symbolic link.")
    return folder


def prepare(folder):
    # Exclusive creation precedes every write, including home, config, repositories and baseline.
    folder.mkdir(exist_ok=False)
    (folder / "home").mkdir()
    (folder / "tmp").mkdir()
    git, env = git_environment(folder)
    repo, remote = create_pair(folder, git, env)
    refs = snapshot(folder, git, env)
    with (folder / BASELINE).open("x", encoding="utf-8") as record:
        json.dump({"format": FORMAT, "remoteRefs": refs}, record, indent=2)
        record.write("\n")
    print(f"Fixture directory: {folder}\nDesktop project: {repo}\nLocal remote: {remote}")
    for name, value in sorted(refs.items()):
        print(f"{name}  {value}")
    return 0


def status(folder):
    marker = folder / BASELINE
    if marker.is_symlink() or not marker.is_file():
        raise ValueError("Missing fixture baseline. Use the directory printed at preparation.")
    baseline = json.loads(marker.read_text(encoding="utf-8"))
    if not isinstance(baseline, dict) or baseline.get("format") != FORMAT or not isinstance(baseline.get("remoteRefs"), dict):
        raise ValueError("Unknown fixture baseline.")
    before = baseline["remoteRefs"]
    now = snapshot(folder, *git_environment(folder))
    for name in sorted(set(before) | set(now)):
        if before.get(name) == now.get(name):
            print(f"{name}  {now[name]}")
        else:
            print(f"CHANGED {name}  {before.get(name, '(absent)')} -> {now.get(name, '(absent)')}")
    if before == now:
        print("Remote references match the baseline.")
        return 0
    print("Remote references changed.")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "status"))
    parser.add_argument("folder", type=Path)
    args = parser.parse_args()
    try:
        folder = local_folder(args.folder)
        return prepare(folder) if args.action == "prepare" else status(folder)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Cannot {args.action} fixture: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
