"""Check shell tool calls before execution. Only the native CLI performs a push."""

from __future__ import annotations

import json
import os
import re
import shlex
import signal
import sys
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import subprocess

MAX_COMMAND = 1_000_000
MAX_DEPTH = 6
# Leave time to deny before the client hook times out.
TIME_BUDGET = 6.0
DEADLINE = [0.0]


class TimeBudgetError(Exception):
    """The time budget of this hook run is spent."""


class GitInspectionError(Exception):
    """A required Git fact could not be read."""


# --- Splitting a command the way a shell does ---------------------------------


@dataclass(eq=False)
class Word:
    text: str  # after quote removal; substitutions kept as written, e.g. $(git branch)
    has_substitution: bool = False
    quoted: bool = False


@dataclass(eq=False)
class Simple:
    words: list[Word] = field(default_factory=list)
    has_redirect: bool = False

    def texts(self) -> list[str]:
        return [word.text for word in self.words]


@dataclass(eq=False)
class Pipeline:
    commands: list[Simple] = field(default_factory=list)
    scope: int = 0  # the shell that runs it: a subshell, a substitution or a script has its own


@dataclass
class Scopes:
    """Which shell runs inside which: a child starts with its parent's state."""

    parents: dict[int, int] = field(default_factory=dict)
    next_id: int = 1

    def child_of(self, parent: int) -> int:
        scope = self.next_id
        self.next_id += 1
        self.parents[scope] = parent
        return scope


SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish"}
# Words that run the command after them; with the options that take a value.
WRAPPERS: dict[str, set[str]] = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S"},
    "command": set(),
    "builtin": set(),
    "exec": {"-a"},
    "nice": {"-n"},
    "nohup": set(),
    "time": set(),
    "timeout": {"-k", "-s", "--kill-after", "--signal"},
    "gtimeout": {"-k", "-s", "--kill-after", "--signal"},
    "xargs": {"-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a"},
    "stdbuf": {"-i", "-o", "-e"},
    "caffeinate": {"-t", "-w"},
    "chronic": set(),
    "ionice": {"-c", "-n", "-p"},
}
# Shell words that may stand before the command on the same line.
RESERVED = {"!", "{", "}", "if", "then", "elif", "else", "fi", "do", "done", "while", "until"}
# Programs that run a shell inside a container or a pod; its script is code too.
CONTAINER_TOOLS = {"docker", "podman", "nerdctl", "kubectl"}
SSH_VALUE_OPTIONS = set("bcDEeFIiJLlmOopQRSWw")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OPERATOR_CHARS = set(";&|()<>")


def basename(word: str) -> str:
    return word.rsplit("/", 1)[-1]


def command_index(words: Sequence[Word]) -> int:
    """Index of the word that names the program: after reserved words, assignments, wrappers."""
    index = 0
    while index < len(words) and words[index].text in RESERVED:
        index += 1
    while index < len(words):
        text = words[index].text
        if ASSIGNMENT.match(text):
            index += 1
            continue
        name = basename(text)
        if name not in WRAPPERS:
            return index
        index += 1
        while index < len(words) and words[index].text.startswith("-"):
            option = words[index].text
            index += 1
            if option == "--":
                break
            if option in WRAPPERS[name]:
                index += 1
        if name in ("timeout", "gtimeout") and index < len(words):
            index += 1  # the duration
    return index


def program(command: Simple) -> str:
    index = command_index(command.words)
    if index < len(command.words):
        return basename(command.words[index].text)
    return ""


def wrapper_names(command: Simple) -> set[str]:
    index = command_index(command.words)
    return {basename(word.text) for word in command.words[:index]} & set(WRAPPERS)


def find_closing(text: str, start: int, opening: str = "(", closing: str = ")") -> int:
    """Index of the bracket that closes one opened just before start; len(text) if none.

    Only for ${…} and $((…)), which hold no heredocs; $(…) is parsed properly.
    """
    depth = 1
    index = start
    while index < len(text):
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if char == "'":
            end = text.find("'", index + 1)
            index = len(text) if end < 0 else end + 1
            continue
        if char == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                index += 2 if text[index] == "\\" else 1
            index += 1
            continue
        if char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return len(text)


def option_values(arguments: Sequence[str], start: int = 0) -> tuple[int, set[str], set[str]]:
    """Walks the options of a shell: (index of the first operand, its letters, its -o names)."""
    index = start
    letters: set[str] = set()
    names: set[str] = set()
    while index < len(arguments):
        word = arguments[index]
        if word in ("-o", "+o", "-O", "+O"):
            if index + 1 < len(arguments) and word == "-o":
                names.add(arguments[index + 1])
            index += 2
        elif word in ("--rcfile", "--init-file"):
            index += 2
        elif word == "--":
            return index + 1, letters, names
        elif word.startswith("--"):
            index += 1
        elif word.startswith("-") and len(word) > 1:
            letters.update(word[1:])
            index += 1
            if word[-1] in "oO" and index < len(arguments):
                # -euo pipefail: the cluster's last letter takes the next word
                if word[-1] == "o":
                    names.add(arguments[index])
                index += 1
        else:
            break
    return index, letters, names


def shell_script(arguments: Sequence[str]) -> str | None:
    """The script of `sh -c SCRIPT`, from the words after the shell's name."""
    index, letters, _ = option_values(arguments)
    if "c" in letters and index < len(arguments):
        return arguments[index]
    return None


def ssh_remote_command(arguments: Sequence[str]) -> str:
    index = 0
    while index < len(arguments) and arguments[index].startswith("-"):
        option = arguments[index]
        index += 1
        if len(option) == 2 and option[1] in SSH_VALUE_OPTIONS:
            index += 1
    return " ".join(arguments[index + 1 :])


def shell_position(command: Simple) -> int | None:
    """Index of the shell word this command runs: itself, or one inside a container."""
    words = command.texts()
    index = command_index(command.words)
    if index >= len(words):
        return None
    if basename(words[index]) in SHELLS:
        return index
    if basename(words[index]) in CONTAINER_TOOLS:
        for position in range(index + 1, len(words)):
            if basename(words[position]) in SHELLS:
                return position
    return None


def reads_stdin_as_code(command: Simple) -> bool:
    """A shell that would run what it reads on stdin: no -c script of its own."""
    words = command.texts()
    position = shell_position(command)
    if position is not None:
        return shell_script(words[position + 1 :]) is None
    index = command_index(command.words)
    name = program(command)
    if name == "ssh":
        remote = ssh_remote_command(words[index + 1 :]).split()
        if not remote:
            return True
        return basename(remote[0]) in SHELLS and shell_script(remote[1:]) is None
    if index >= len(words) and "sudo" in wrapper_names(command):
        return any(word in ("-s", "-i") for word in words)
    return False


class Parser:
    """Turns command text into pipelines, nested ones included.

    The text of a heredoc counts as code only when a shell reads it (`bash <<EOF`,
    `ssh host <<EOF`, or a later `| bash` in the pipeline); otherwise it is data
    being written, like the script in `cat > s.sh <<EOF`. A quoted string is one
    word; it is parsed as code only as the script of `sh -c`, `eval`, `ssh` and
    the like. A $(…) is parsed by a parser of its own that stops at its `)`.
    """

    def __init__(
        self,
        text: str,
        depth: int = 0,
        *,
        start: int = 0,
        until_paren: bool = False,
        scopes: Scopes | None = None,
        scope: int = 0,
        normalized: bool = False,
    ) -> None:
        if not normalized:
            text = text.replace("\r", "").replace("\\\n", "")
        self.text = text
        self.position = start
        self.depth = depth
        self.until_paren = until_paren
        self.scopes = scopes if scopes is not None else Scopes()
        self.scope = scope
        self.pipelines: list[Pipeline] = []
        self.pipeline = Pipeline()
        self.command = Simple()
        # Heredocs started on the current line: (pipeline, command, delimiter).
        self.pending: list[tuple[Pipeline, Simple, str]] = []
        # Parentheses create a shell scope; braces keep the existing working folder.
        self.groups: list[tuple[str, int]] = []

    def parse(self) -> list[Pipeline]:
        if self.depth > MAX_DEPTH:
            self.position = len(self.text)
            return []
        text = self.text
        while self.position < len(text):
            char = text[self.position]
            if char in " \t":
                self.position += 1
            elif char == "\n":
                self.position += 1
                self.end_pipeline()
                self.read_heredocs()
            elif char == "#":
                end = text.find("\n", self.position)
                end = len(text) if end < 0 else end
                self.position = end
            elif text.startswith("&&", self.position) or text.startswith("||", self.position):
                self.position += 2
                self.end_pipeline()
            elif text.startswith(";;", self.position):
                self.position += 2
                self.end_pipeline()
            elif char == ";":
                self.position += 1
                self.end_pipeline()
            elif text.startswith("|&", self.position):
                self.position += 2
                self.end_command()
            elif char == "|":
                self.position += 1
                self.end_command()
            elif char == "&" and not text.startswith("&>", self.position):
                self.position += 1
                self.end_pipeline()
            elif char == "(":
                words = self.command.texts()
                if text.startswith("((", self.position) and words in ([], ["for"]):
                    # Arithmetic: (( i++ )), and the head of for ((;;)).
                    end = text.find("))", self.position + 2)
                    end = len(text) if end < 0 else end
                    self.command.words.append(Word(text[self.position : end + 2]))
                    self.position = end + 2
                else:
                    self.position += 1
                    self.open_group("(")
            elif char == ")":
                self.position += 1
                if self.close_group("("):
                    continue
                if self.until_paren:
                    self.end_pipeline()
                    return self.pipelines
                self.end_pipeline()
            elif self.at_redirect():
                self.read_redirect()
            else:
                word = self.read_word()
                if word is None:
                    continue
                if word.text == "{" and not word.quoted and not self.command.words:
                    self.open_group("{")
                elif word.text == "}" and not word.quoted and not self.command.words:
                    if not self.close_group("{"):
                        self.command.words.append(word)
                else:
                    self.command.words.append(word)
        self.end_pipeline()
        self.read_heredocs()
        return self.pipelines

    # Groups: ( … ) runs in a subshell of its own; { …; } in the same shell.

    def open_group(self, kind: str) -> None:
        self.end_pipeline()
        self.groups.append((kind, self.scope))
        if kind == "(":
            self.scope = self.scopes.child_of(self.scope)

    def close_group(self, kind: str) -> bool:
        if not self.groups or self.groups[-1][0] != kind:
            return False
        self.end_pipeline()
        _, self.scope = self.groups.pop()
        return True

    def end_command(self) -> None:
        if self.command.words or self.command.has_redirect:
            self.pipeline.commands.append(self.command)
            self.parse_scripts(self.command)
        self.command = Simple()

    def end_pipeline(self) -> None:
        self.end_command()
        if self.pipeline.commands:
            self.pipeline.scope = self.scope
            self.pipelines.append(self.pipeline)
        self.pipeline = Pipeline()

    def nested(self, text: str) -> None:
        scope = self.scopes.child_of(self.scope)
        self.pipelines.extend(Parser(text, self.depth + 1, scopes=self.scopes, scope=scope).parse())

    def nested_command(self, words: Sequence[Word]) -> None:
        """Words that another program runs as a command of their own: git bisect run …"""
        if not words:
            return
        command = Simple(list(words))
        self.pipelines.append(Pipeline([command], scope=self.scope))
        self.parse_scripts(command)

    def substitution(self, start: int) -> int:
        """Parses $(…) or <(…) from start; returns the index just after its `)`."""
        if self.depth >= MAX_DEPTH:
            return find_closing(self.text, start) + 1
        scope = self.scopes.child_of(self.scope)
        inner = Parser(
            self.text,
            self.depth + 1,
            start=start,
            until_paren=True,
            scopes=self.scopes,
            scope=scope,
            normalized=True,
        )
        self.pipelines.extend(inner.parse())
        return inner.position

    def parse_scripts(self, command: Simple) -> None:
        """Code that this command runs from its arguments: sh -c, eval, ssh, and the like."""
        words = command.texts()
        index = command_index(command.words)
        for position, word in enumerate(words[:index]):
            # env -S 'cmd args' splits the string and runs it.
            if basename(word) == "env":
                for offset in range(position + 1, index):
                    if words[offset] in ("-S", "--split-string") and offset + 1 < len(words):
                        self.nested(words[offset + 1])
        if index >= len(words):
            return
        name = basename(words[index])
        rest = words[index + 1 :]
        shell = shell_position(command)
        if shell is not None:
            script = shell_script(words[shell + 1 :])
            if script is not None:
                self.nested(script)
        elif name == "eval":
            self.nested(" ".join(rest))
        elif name == "ssh":
            remote = ssh_remote_command(rest)
            if remote:
                self.nested(remote)
        elif name == "watch":
            position = 0
            while position < len(rest) and rest[position].startswith("-"):
                takes_value = rest[position] in ("-n", "--interval", "-q", "--equexit")
                position += 2 if takes_value else 1
            if position < len(rest):
                self.nested(" ".join(rest[position:]))
        elif name == "parallel":
            template = [word for word in rest if not word.startswith("-")][:1]
            if template and template[0] != ":::":
                self.nested(template[0])
        elif name == "git":
            self.git_runs(command.words[index + 1 :])
        elif name == "find":
            for position, word in enumerate(words):
                if word in ("-exec", "-execdir") and position + 1 < len(words):
                    if basename(words[position + 1]) in SHELLS:
                        script = shell_script(words[position + 2 :])
                        if script is not None:
                            self.nested(script)

    def git_runs(self, arguments: Sequence[Word]) -> None:
        """git submodule foreach CMD runs CMD with sh; git bisect run CMD execs it."""
        texts = [word.text for word in arguments]
        position = git_subcommand(texts)
        if position + 1 >= len(texts):
            return
        sub, after = texts[position], texts[position + 1]
        if sub == "submodule" and after == "foreach":
            rest = [
                word
                for word in texts[position + 2 :]
                if word not in ("--recursive", "-q", "--quiet")
            ]
            if rest:
                self.nested(" ".join(rest))
        elif sub == "bisect" and after == "run":
            self.nested_command(arguments[position + 2 :])

    # Heredocs.

    def read_heredocs(self) -> None:
        pending, self.pending = self.pending, []
        # Whether a shell reads stdin at or after each command, once per pipeline.
        code_after: dict[int, list[bool]] = {}
        for pipeline, command, delimiter in pending:
            lines = []
            while self.position < len(self.text):
                end = self.text.find("\n", self.position)
                end = len(self.text) if end < 0 else end
                line = self.text[self.position : end]
                self.position = end + 1
                if line.strip(" \t") == delimiter:
                    break
                lines.append(line)
            body = "\n".join(lines)
            commands = pipeline.commands or [command]
            key = id(pipeline)
            if key not in code_after:
                flags = [reads_stdin_as_code(each) for each in commands]
                for position in range(len(flags) - 2, -1, -1):
                    flags[position] = flags[position] or flags[position + 1]
                code_after[key] = flags
            place = next((n for n, each in enumerate(commands) if each is command), 0)
            if code_after[key] and code_after[key][place]:
                self.nested(body)

    # Redirections.

    def at_redirect(self) -> bool:
        text = self.text[self.position :]
        return bool(re.match(r"(\d*|&)(>>?|<<?<?|>\||<>|>&|<&)", text)) and not re.match(
            r"[<>]\(", text
        )

    def read_redirect(self) -> None:
        match = re.match(r"(\d*|&)(<<<|<<-|<<|>>|>\||<>|>&|<&|>|<)", self.text[self.position :])
        assert match is not None
        op = match.group(1) + match.group(2) if match.group(1) == "&" else match.group(2)
        self.command.has_redirect = True
        self.position += match.end()
        while self.position < len(self.text) and self.text[self.position] in " \t":
            self.position += 1
        if op in (">&", "<&"):
            duplicate = re.match(r"\d+-?|-", self.text[self.position :])
            if duplicate:
                self.position += duplicate.end()
                return
        target = self.read_word()
        target_text = target.text if target is not None else ""
        if op in ("<<", "<<-"):
            self.pending.append((self.pipeline, self.command, target_text))

    # Words.

    def read_word(self) -> Word | None:
        text = self.text
        parts: list[str] = []
        substitution = quoted = False
        start = self.position
        while self.position < len(text):
            char = text[self.position]
            if char in " \t\n" or char in OPERATOR_CHARS:
                if char in "<>" and text.startswith("(", self.position + 1):
                    # Process substitution <(…) / >(…): it runs a command.
                    end = self.substitution(self.position + 2)
                    parts.append(text[self.position : end])
                    substitution = True
                    self.position = end
                    continue
                break
            if char == "\\":
                parts.append(text[self.position + 1 : self.position + 2])
                self.position += 2
            elif char == "'":
                end = text.find("'", self.position + 1)
                end = len(text) if end < 0 else end
                parts.append(text[self.position + 1 : end])
                self.position = end + 1
                quoted = True
            elif text.startswith("$'", self.position):
                end = self.position + 2
                while end < len(text) and text[end] != "'":
                    end += 2 if text[end] == "\\" else 1
                parts.append(text[self.position + 2 : end])
                self.position = end + 1
                quoted = True
            elif char == '"':
                substitution = self.read_double_quoted(parts) or substitution
                quoted = True
            elif char == "`":
                end = text.find("`", self.position + 1)
                end = len(text) if end < 0 else end
                self.nested(text[self.position + 1 : end])
                parts.append(text[self.position : end + 1])
                substitution = True
                self.position = end + 1
            elif text.startswith("$((", self.position):
                end = find_closing(text, self.position + 3)
                self.arithmetic(text[self.position + 3 : end])
                parts.append(text[self.position : end + 2])
                self.position = end + 2
            elif text.startswith("$(", self.position):
                end = self.substitution(self.position + 2)
                parts.append(text[self.position : end])
                substitution = True
                self.position = end
            elif text.startswith("${", self.position):
                end = find_closing(text, self.position + 2, "{", "}")
                parts.append(text[self.position : end + 1])
                self.position = end + 1
            else:
                parts.append(char)
                self.position += 1
        if self.position == start:
            self.position += 1
            return None
        return Word("".join(parts), substitution, quoted)

    def read_double_quoted(self, parts: list[str]) -> bool:
        text = self.text
        self.position += 1
        substitution = False
        while self.position < len(text) and text[self.position] != '"':
            char = text[self.position]
            if char == "\\" and self.position + 1 < len(text):
                following = text[self.position + 1]
                parts.append(following if following in '$`"\\' else char + following)
                self.position += 2
            elif text.startswith("$((", self.position):
                end = find_closing(text, self.position + 3)
                self.arithmetic(text[self.position + 3 : end])
                parts.append(text[self.position : end + 2])
                self.position = end + 2
            elif text.startswith("$(", self.position):
                end = self.substitution(self.position + 2)
                parts.append(text[self.position : end])
                substitution = True
                self.position = end
            elif char == "`":
                end = text.find("`", self.position + 1)
                end = len(text) if end < 0 else end
                self.nested(text[self.position + 1 : end])
                parts.append(text[self.position : end + 1])
                substitution = True
                self.position = end + 1
            else:
                parts.append(char)
                self.position += 1
        self.position += 1
        return substitution

    def arithmetic(self, inner: str) -> None:
        """$((…)) is arithmetic, not a command; a $(…) inside it does run."""
        index = inner.find("$(")
        while index >= 0:
            if inner.startswith("$((", index):
                index = inner.find("$(", index + 3)
                continue
            end = find_closing(inner, index + 2)
            self.nested(inner[index + 2 : end])
            index = inner.find("$(", end)


@dataclass
class Folders:
    """The folder each shell is in: a subshell starts in its parent's, and its cd ends with it."""

    parents: Mapping[int, int]
    start: str
    by_scope: dict[int, str] = field(default_factory=dict)

    def of(self, scope: int) -> str:
        if scope not in self.by_scope:
            parent = self.parents.get(scope)
            inherited = self.of(parent) if parent is not None and parent != scope else self.start
            self.by_scope[scope] = inherited
        return self.by_scope[scope]

    def move(self, scope: int, folder: str) -> None:
        self.by_scope[scope] = folder


def git_subcommand(arguments: Sequence[str]) -> int:
    """Index of git's subcommand in the words after `git`, past its own options."""
    position = 0
    while position < len(arguments) and arguments[position].startswith("-"):
        option = arguments[position]
        if option in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"):
            position += 2
        else:
            position += 1
    return position


PROTECTED = ("main", "master")
CURRENT_BRANCH_WORDS = ("HEAD", "@")


def run_git(repo: str, *arguments: str) -> subprocess.CompletedProcess[str] | None:
    """git in the time left; when that runs out, the whole guard stops (TimeBudgetError)."""
    import subprocess

    left = DEADLINE[0] - time.monotonic()
    if left <= 0:
        raise TimeBudgetError("git did not answer in time")
    try:
        return subprocess.run(
            ["git", "-C", repo, *arguments], capture_output=True, text=True, timeout=left
        )
    except subprocess.TimeoutExpired as error:
        raise TimeBudgetError("git did not answer in time") from error
    except OSError:
        return None


def current_branch(repo: str) -> str:
    result = run_git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if result is None or result.returncode != 0 or not result.stdout.strip():
        raise GitInspectionError("The current branch could not be determined.")
    return result.stdout.strip()


def push_config_risks(repo: str, remote: str | None, refspecs: Sequence[str], implicit: bool) -> list[str]:
    result = run_git(repo, "config", "--null", "--get-regexp", r"^(push\.default|remote\..*\.(mirror|push))$")
    if result is None or result.returncode not in (0, 1):
        raise GitInspectionError("Git push defaults could not be read.")
    push_default = "simple"
    refspec = mirror = False
    for entry in result.stdout.split("\0"):
        key, _, value = entry.partition("\n")
        if key == "push.default":
            push_default = value.lower()
        elif key and (remote is None or key.rsplit(".", 1)[0] == f"remote.{remote}"):
            if key.endswith(".push"):
                refspec = True
            elif key.endswith(".mirror"):
                mirror |= value.lower() not in {"false", "no", "off", "0"}
    risks = ["the remote defaults to a mirror push"] if mirror else []
    unmapped = any(":" not in word for word in refspecs)
    if (refspec and (implicit or unmapped)
            or implicit and push_default not in {"simple", "current", "nothing"}
            or unmapped and push_default in {"upstream", "tracking"}):
        risks.append("the push destination depends on Git configuration; name the exact destination")
    return risks


def is_known_branch(repo: str, name: str) -> bool:
    result = run_git(repo, "for-each-ref", "--format=%(refname)", f"refs/heads/{name}")
    if result is not None and result.stdout.strip():
        return True
    result = run_git(repo, "for-each-ref", "--format=%(refname)", f"refs/remotes/*/{name}")
    return result is not None and bool(result.stdout.strip())


def is_local_tag(repo: str, name: str) -> bool:
    result = run_git(repo, "show-ref", "--verify", "--quiet", f"refs/tags/{name}")
    return result is not None and result.returncode == 0


def is_protected(ref: str) -> bool:
    for name in PROTECTED:
        if ref in (name, "heads/" + name) or ref.endswith("/heads/" + name):
            return True
    return False


@dataclass
class GitContext:
    home: str
    switched: str = ""  # the branch a checkout/switch earlier in the command moved to
    deleted_tags: set[str] = field(default_factory=set)  # tags a `git tag -d` removed
    # Branches a `git branch -d` removed: deleting them on the remote is no tag delete.
    deleted_branches: set[str] = field(default_factory=set)

    def resolve(self, path: str, cwd: str) -> str:
        if path == "~":
            return self.home
        if path.startswith("~/"):
            return os.path.join(self.home, path[2:])
        return os.path.join(cwd, path)


def push_option(argument: str, *names: str) -> bool:
    option = argument.partition("=")[0]
    return (
        option.startswith("--")
        and len(option) > 2
        and any(name.startswith(option) for name in names)
    )


def check_push(repo: str, context: GitContext, arguments: Sequence[str], overrides: bool) -> list[str]:
    dry = force = push_all = delete = tags_only = prune = False
    refs: list[str] = []
    skip = False
    options = True
    remote_option = None
    read_remote = False
    for argument in arguments:
        if read_remote:
            remote_option = argument
            read_remote = False
            continue
        if skip:
            skip = False
            continue
        if options and argument == "--":
            options = False
            continue
        if not options:
            if argument.startswith("+"):
                force = True
                argument = argument[1:]
            refs.append(argument)
            continue
        if argument == "-n" or (argument.startswith("--dr") and "--dry-run".startswith(argument)):
            dry = True
        elif argument.startswith("--no-dr") and "--no-dry-run".startswith(argument):
            dry = False
        elif push_option(
            argument, "--force", "--force-if-includes", "--force-with-lease", "--mirror"
        ):
            force = True
        elif push_option(argument, "--all", "--branches"):
            push_all = True
        elif argument in ("--prune", "--prun", "--pru"):
            prune = True
        elif argument in ("--no-prune", "--no-prun", "--no-pru"):
            prune = False
        elif push_option(argument, "--delete"):
            delete = True
        elif push_option(argument, "--tags"):
            tags_only = True
        elif push_option(argument, "--no-tags"):
            tags_only = False
        elif push_option(argument, "--repo"):
            _, separator, value = argument.partition("=")
            if separator:
                remote_option = value
            else:
                read_remote = True
        elif argument == "-o" or push_option(
            argument, "--receive-pack", "--exec", "--push-option"
        ):
            skip = "=" not in argument
        elif argument.startswith("--"):
            pass
        elif argument.startswith("-") and len(argument) > 1:
            letters = argument[1:]
            for index, letter in enumerate(letters):
                if letter == "o":
                    skip = index == len(letters) - 1
                    break
                if letter == "n":
                    dry = True
                elif letter == "f":
                    force = True
                elif letter == "d":
                    delete = True
        elif argument.startswith("+"):
            force = True
            refs.append(argument[1:])
        else:
            refs.append(argument)
    if dry:
        return []
    risks = []
    if prune:
        risks.append("push --prune may delete remote branches or tags")
    if force:
        risks.append("force push")
    if push_all:
        risks.append("push --all includes main/master")

    def current() -> str:
        return context.switched or current_branch(repo)

    remote = refs[0] if refs else remote_option
    refspecs = refs[1:]
    implicit = not refspecs and not tags_only and not push_all
    if overrides:
        risks.append("command-local Git configuration may override push routing")
    risks.extend(push_config_risks(repo, remote, refspecs, implicit))
    after_tag_word = False
    for refspec in refspecs:
        if refspec == "tag":
            after_tag_word = True
            continue
        name = ""
        if delete:
            name = refspec
        elif refspec.startswith(":") and refspec != ":":
            name = refspec[1:]
        if name:
            if is_protected(name):
                risks.append("push targets main/master")
            elif name.startswith("refs/tags/") or after_tag_word or name in context.deleted_tags:
                risks.append(f"deletes tag '{name.rsplit('/', 1)[-1]}' on the remote")
            elif name.startswith("refs/heads/") or name in context.deleted_branches:
                risks.append(f"deletes branch '{name.rsplit('/', 1)[-1]}' on the remote")
            elif not is_known_branch(repo, name):
                if is_local_tag(repo, name) or re.match(r"^v?\d", name):
                    risks.append(f"deletes tag '{name}' on the remote")
                else:
                    risks.append(
                        f"deletes '{name}' on the remote; it is not a known branch, "
                        "so it may be a tag"
                    )
            else:
                risks.append(f"deletes branch '{name}' on the remote")
            after_tag_word = False
            continue
        after_tag_word = False
        if refspec == ":" or "*" in refspec:
            risks.append("pushes matching branches, main/master included")
            continue
        source, _, destination = refspec.partition(":")
        destination = destination or source
        if is_protected(destination):
            risks.append("push targets main/master")
        elif destination in CURRENT_BRANCH_WORDS or "$(" in destination or "`" in destination:
            branch = current()
            if branch in PROTECTED:
                risks.append(f"pushes the current branch '{branch}' (protected)")
    if implicit:
        branch = current()
        if branch in PROTECTED:
            risks.append(f"current branch is '{branch}' (protected)")
    return risks


def git_guard(
    pipelines: Sequence[Pipeline], cwd: str, home: str, scopes: Scopes
) -> tuple[str, str] | None:
    context = GitContext(home)
    folders = Folders(scopes.parents, cwd)
    risks: list[str] = []
    for pipeline, command in [(each, command) for each in pipelines for command in each.commands]:
        words = command.texts()
        index = command_index(command.words)
        if index >= len(words):
            continue
        here = folders.of(pipeline.scope)
        name = basename(words[index])
        if name in ("cd", "pushd") and index + 1 < len(words) and "$" not in words[index + 1]:
            folders.move(pipeline.scope, context.resolve(words[index + 1], here))
            continue
        if name != "git":
            continue
        # -C moves git's folder, one after another; a relative --git-dir or GIT_DIR
        # (also behind env) is taken from the folder that results.
        folder = here
        git_dir = ""
        for word in words[:index]:
            if word.startswith("GIT_DIR=") and "$" not in word:
                git_dir = word[len("GIT_DIR=") :]
        arguments = words[index + 1 :]
        position = git_subcommand(arguments)
        for offset in range(position):
            option = arguments[offset]
            value = arguments[offset + 1] if offset + 1 < position else ""
            if option == "-C" and value:
                folder = context.resolve(value, folder)
            elif option == "--git-dir" and value:
                git_dir = value
            elif option.startswith("--git-dir="):
                git_dir = option[len("--git-dir=") :]
        repo = context.resolve(git_dir, folder) if git_dir else folder
        if position >= len(arguments):
            continue
        sub = arguments[position]
        rest = arguments[position + 1 :]
        if sub in ("checkout", "switch") and "--" not in rest:
            tracking = any(word in ("--track", "-t") for word in rest)
            for offset, word in enumerate(rest):
                if word in ("-b", "-B", "-c", "-C"):
                    context.switched = rest[offset + 1] if offset + 1 < len(rest) else ""
                    break
                if not word.startswith("-"):
                    # --track origin/main creates and checks out main
                    context.switched = word.split("/", 1)[1] if tracking and "/" in word else word
        elif sub == "branch" and any(word in ("-d", "-D", "--delete") for word in rest):
            context.deleted_branches.update(word for word in rest if not word.startswith("-"))
        elif sub == "tag" and ("-d" in rest or "--delete" in rest):
            context.deleted_tags.update(word for word in rest if not word.startswith("-"))
        elif sub == "push":
            overrides = any(
                option in ("-c", "--config-env") or option.startswith(("-c", "--config-env="))
                for option in arguments[:position]
            ) or any(word.startswith(("GIT_CONFIG", "GIT_NAMESPACE=")) for word in words[:index])
            for risk in check_push(repo, context, rest, overrides):
                if risk not in risks:
                    risks.append(risk)
    if risks:
        return "ask", "; ".join(risks)
    return None


def deny(reason: str) -> str:
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "Agent Watch Git: " + reason,
    }}, separators=(",", ":"))


def inspect(payload: dict) -> str:
    tool = payload.get("tool_input")
    if not isinstance(tool, dict):
        return ""
    command = tool.get("command", tool.get("cmd"))
    if not isinstance(command, str) or not command.strip():
        return ""
    if len(command) > MAX_COMMAND:
        return deny("The command is too long to check. Split it into smaller commands.")
    cwd = payload.get("cwd") or os.getcwd()
    if tool.get("workdir"):
        cwd = os.path.join(cwd, tool["workdir"])
    DEADLINE[0] = time.monotonic() + TIME_BUDGET
    parser = Parser(command)
    result = git_guard(parser.parse(), cwd, os.path.expanduser("~"), parser.scopes)
    if result is None:
        return ""
    _, reason = result
    binary = Path(__file__).resolve().parents[3] / "MacOS" / "AgentWatchGit"
    return deny(
        f"{reason}. For one intended reference call {shlex.quote(str(binary))} push '<JSON object>' "
        "with repository (absolute working tree path), destination (refs/heads/name or refs/tags/name), "
        "remote (configured name, default origin), and reason. For deletion set delete to true and omit "
        "source and force. For an update use source (default HEAD) and set force to true only when "
        "explicitly requested. The CLI shows the user an approval window and executes the approved "
        "operation itself. Never answer the window, retry a refusal or execute a fallback push."
    )


def main() -> None:
    def timed_out(_signal, _frame):
        raise TimeBudgetError("the hook did not finish")

    signal.signal(signal.SIGALRM, timed_out)
    signal.setitimer(signal.ITIMER_REAL, TIME_BUDGET)
    try:
        payload = json.loads(sys.stdin.buffer.read())
        if not isinstance(payload, dict):
            raise ValueError("expected a hook event object")
        result = inspect(payload)
    except TimeBudgetError:
        result = deny("The repository could not be inspected before the hook deadline.")
    except GitInspectionError as error:
        result = deny(str(error))
    except Exception as error:
        result = deny(f"The hook could not check this command ({type(error).__name__}).")
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    if result:
        print(result)


if __name__ == "__main__":
    if sys.version_info < (3, 9):
        sys.exit(3)
    if sys.argv[1:] == ["--check"]:
        print("agent-watch-git-hook-ok")
    else:
        main()
