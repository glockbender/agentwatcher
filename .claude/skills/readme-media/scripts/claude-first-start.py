#!/usr/bin/env python3
"""claude-first-start.py [--approve-managed-settings] — start Claude Code once, with no window.

Run inside the virtual machine, in the checkout. Claude Code is started in a pseudo-terminal and
answers nothing of its own accord: whatever its first start shows is printed, so a new screen is
seen rather than recorded on camera. With --approve-managed-settings it accepts the settings the
signed-in organisation manages, the screen "Managed settings require approval" — a choice its
owner made (vm.md), never one to make for them. It stops once the prompt is ready.
"""
import os
import pty
import re
import select
import signal
import sys
import time

APPROVAL = "Managed settings require approval"
# The input box under a started session; the first-start screens have no "? for shortcuts".
READY = "for shortcuts"
SECONDS = 60


def screen_text(raw: bytes) -> str:
    text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]", b"", raw)
    return text.decode("utf-8", "replace")


def main() -> int:
    approve = "--approve-managed-settings" in sys.argv
    command = ["claude", "--setting-sources", "project,local", "--strict-mcp-config", "--permission-mode", "default"]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", IS_DEMO="1")
        os.execvp(command[0], command)
    import fcntl, struct, termios

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    raw, approved, ready = b"", False, False
    end = time.time() + SECONDS
    while time.time() < end and not ready:
        if fd not in select.select([fd], [], [], 0.2)[0]:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        raw += chunk
        # The terminal's answers to what a TUI asks before drawing: the cursor and the colours.
        if b"\x1b[6n" in chunk:
            os.write(fd, b"\x1b[1;1R")
        for query, answer in ((b"\x1b]10;?", b"\x1b]10;rgb:ffff/ffff/ffff\x07"), (b"\x1b]11;?", b"\x1b]11;rgb:0000/0000/0000\x07")):
            if query in chunk:
                os.write(fd, answer)
        flat = screen_text(raw).replace(" ", "")
        if not approved and APPROVAL.replace(" ", "") in flat:
            if not approve:
                break
            time.sleep(0.5)
            os.write(fd, b"\r")  # "1. Yes, I trust these settings" is selected (Claude Code 2.1.294)
            approved = True
        ready = READY.replace(" ", "") in flat
    # SIGTERM, not SIGKILL: a start that never exits counts as a failed start of the fullscreen
    # renderer, and after a few Claude Code turns it off and says so on every screen. Measured on
    # Claude Code 2.1.294.
    # Its output is read while it exits: unread, the pseudo-terminal fills and Claude never does.
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if os.waitpid(pid, os.WNOHANG)[0]:
            break
        if fd in select.select([fd], [], [], 0.1)[0]:
            try:
                os.read(fd, 65536)
            except OSError:
                pass
    else:
        os.kill(pid, signal.SIGKILL)
    lines = [line.strip() for line in screen_text(raw).splitlines() if line.strip()]
    print("\n".join(lines[-25:]))
    print(f"--- approved managed settings: {approved}; prompt ready: {ready}")
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
