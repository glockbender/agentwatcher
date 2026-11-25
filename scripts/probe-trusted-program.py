#!/usr/bin/env python3
"""Exercise a native launch boundary using small synthetic binaries, never Keychain.

Nothing here is installed or exposed by Agent Watch. The scratch directory is kept
for inspection; an isolated test host can remove its entire scratch area afterwards.
"""

import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


SYNTHETIC_VALUE = "AGENT_WATCH_SYNTHETIC_VALUE_NOT_A_SECRET"
HERE = Path(__file__).resolve().parent


def command(arguments, *, directory, environment, timeout=20):
    process = subprocess.Popen(
        [str(argument) for argument in arguments],
        cwd=directory,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        # macOS can briefly retain a terminated child until its new parent reaps it.
        deadline = time.monotonic() + 3
        while True:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("The timed-out process group still exists") from None
            time.sleep(0.02)
        raise TimeoutError("The synthetic experiment exceeded its time limit") from None
    return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, help="Parent for a new, isolated experiment directory")
    arguments = parser.parse_args()
    parent = arguments.scratch or os.environ.get("AGENT_WATCH_TEST_SCRATCH")
    root = Path(tempfile.mkdtemp(prefix="agent-watch-native-probe-", dir=parent)).resolve()
    work = root / "working-directory"
    work.mkdir(mode=0o700)
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "TMPDIR": str(root)}
    driver = root / "probe"
    approved = root / "approved"
    changed = root / "changed"
    builds = [
        ["/usr/bin/clang", "-Wall", "-Wextra", "-Werror", "-fno-modules",
         HERE / "trusted-program-probe.c", "-framework", "Security", "-framework", "CoreFoundation", "-o", driver],
        ["/usr/bin/clang", "-Wall", "-Wextra", "-Werror", "-fno-modules",
         HERE / "fixtures/trusted-program.c", "-o", approved],
        ["/usr/bin/clang", "-Wall", "-Wextra", "-Werror", "-fno-modules", "-DFIXTURE_VERSION=2",
         HERE / "fixtures/trusted-program.c", "-o", changed],
    ]
    for build in builds:
        result = command(build, directory=root, environment=environment)
        require(result.returncode == 0, "Could not compile a synthetic fixture: " + result.stderr)
    # '-' is an ad-hoc signature. No signing certificate or Keychain identity is used.
    for binary in (approved, changed):
        dependencies = command(["/usr/bin/otool", "-L", binary], directory=root, environment=environment)
        libraries = [line.strip().split(" (", 1)[0] for line in dependencies.stdout.splitlines()[1:]]
        require(dependencies.returncode == 0 and libraries == ["/usr/lib/libSystem.B.dylib"],
                "The fixture must link only the system C library")
        result = command(
            ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "hard,kill,runtime", binary],
            directory=root, environment=environment)
        require(result.returncode == 0, "Could not ad-hoc sign a synthetic fixture")
    identity = command([driver, "identity", approved], directory=root, environment=environment)
    require(identity.returncode == 0, "Could not establish the fixture's code identity")
    expected = identity.stdout.strip()
    receipt = work / "receipt"

    def run(program, *, replacement=None):
        mode = "run-replaced" if replacement else "run"
        invocation = [driver, mode, expected, program, work]
        if replacement:
            invocation.append(replacement)
        result = command(
            invocation, directory=root,
            environment={**environment, "AGENT_WATCH_UNEXPECTED_ENV": "must-not-be-inherited"})
        require(SYNTHETIC_VALUE not in result.stdout + result.stderr, "Program output escaped the boundary")
        require(result.stderr == "", "Unexpected launcher diagnostic")
        return result

    for _ in range(2):
        result = run(approved)
        require(result.returncode == 0 and result.stdout == "completed\n", "Approved fixture did not run")
        require(receipt.read_text() == "fixture-1\n", "The approved fixture did not use the fixed working directory")
        receipt.unlink()

    result = run(changed)
    require(result.returncode == 20 and result.stdout == "refused\n", "Changed program was not refused")
    require(not receipt.exists(), "Changed program ran before approval")

    candidate = root / "candidate"
    substitution = root / "substitution"
    shutil.copy2(approved, candidate)
    shutil.copy2(changed, substitution)
    result = run(candidate, replacement=substitution)
    require(result.returncode == 20 and result.stdout == "refused\n", "Path substitution was not refused")
    require(not receipt.exists(), "Substituted program ran before approval")

    script = root / "script"
    script.write_text("#!/bin/sh\nexit 0\n")
    script.chmod(0o700)
    result = run(script)
    require(result.returncode == 20 and result.stdout == "refused\n", "Script was not refused")
    alias = root / "alias"
    alias.symlink_to(approved)
    result = run(alias)
    require(result.returncode == 20 and result.stdout == "refused\n", "Symbolic link was not refused")

    changed_identity = command([driver, "identity", changed], directory=root, environment=environment)
    require(changed_identity.returncode == 0, "Could not identify the waiting fixture")
    try:
        command([driver, "run", changed_identity.stdout.strip(), changed, work],
                directory=root, environment=environment, timeout=10)
    except TimeoutError:
        require(receipt.read_text() == "fixture-2\n", "The waiting fixture did not start before the deadline")
    else:
        raise RuntimeError("The waiting fixture returned before the outer deadline")

    print("PASS: repeat launch, fixed arguments/environment/directory, suppressed output, changed binary, path substitution, script and symlink refusal.")
    print("Synthetic data only. Keychain and the real bot were not accessed.")
    print("PASS: deadline terminated the launcher and the running fixture; their process group is gone.")
    print("Scratch retained at " + str(root))


if __name__ == "__main__":
    main()
