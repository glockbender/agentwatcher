"""Build the Agent Watch executable from this checkout and its locked dependencies."""

import os
from pathlib import Path
import subprocess


def build_binary():
    root = Path(__file__).resolve().parents[1]
    default_target = os.environ.get("CARGO_TARGET_DIR") or root / ".build" / "git-protection"
    target = Path(default_target).resolve()
    subprocess.run(["rustup", "run", "1.98.1", "cargo", "build", "--release", "--no-default-features",
                    "--locked", "--manifest-path", root / "native/git-protection/Cargo.toml",
                    "--target-dir", target], check=True, timeout=600)
    return target / "release" / "agent-watch-git"


if __name__ == "__main__":
    print(build_binary())
