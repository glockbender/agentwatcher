//! Extracts commands and their working-directory scopes without executing shell input.
//! Heredoc bodies are code only when their pipeline feeds an interpreter.

use super::commands::{self, Embedded};
use std::mem;
use std::time::Instant;

pub(super) struct Command {
    pub(super) scope: usize,
    pub(super) words: Vec<String>,
}

pub(super) struct Parsed {
    pub(super) parents: Vec<usize>,
    pub(super) commands: Vec<Command>,
}

const DEPTH_LIMIT: usize = 6;
type Check<T> = Result<T, String>;

pub(super) fn parse(text: &str, deadline: Instant) -> Check<Parsed> {
    let normalized = normalize(text);
    let mut parsed = Parsed {
        parents: vec![0],
        commands: Vec::new(),
    };
    Parser::new(&normalized, 0, 0, 0, &mut parsed, deadline)?.scan(false)?;
    Ok(parsed)
}

fn normalize(text: &str) -> String {
    text.replace('\r', "").replace("\\\n", "")
}

#[derive(Default)]
struct Pipeline {
    commands: Vec<Command>,
    // Once a heredoc has been seen, remember whether a later stage interprets it as code.
    interpreters: Vec<bool>,
    delimiters: Vec<(usize, String)>,
}

struct Parser<'a, 'p> {
    text: &'a str,
    pos: usize,
    depth: usize,
    scope: usize,
    parsed: &'p mut Parsed,
    deadline: Instant,
    words: Vec<String>,
    pipe: Pipeline,
    redirected: bool,
    heredocs: Vec<(bool, String)>,
    groups: Vec<(u8, usize)>,
}

impl<'a, 'p> Parser<'a, 'p> {
    fn new(
        text: &'a str,
        pos: usize,
        depth: usize,
        scope: usize,
        parsed: &'p mut Parsed,
        deadline: Instant,
    ) -> Check<Self> {
        if depth > DEPTH_LIMIT {
            return Err("The shell nesting is too deep to check. Split the command.".into());
        }
        Ok(Self {
            text,
            pos,
            depth,
            scope,
            parsed,
            deadline,
            words: vec![],
            redirected: false,
            pipe: Pipeline::default(),
            heredocs: vec![],
            groups: vec![],
        })
    }

    fn remaining(&self) -> &'a str {
        &self.text[self.pos..]
    }

    fn child_scope(&mut self) -> usize {
        let id = self.parsed.parents.len();
        self.parsed.parents.push(self.scope);
        id
    }

    fn nested(&mut self, text: &str) -> Check<()> {
        if text.is_empty() {
            return Ok(());
        }
        let scope = self.child_scope();
        Parser::new(
            &normalize(text),
            0,
            self.depth + 1,
            scope,
            self.parsed,
            self.deadline,
        )?
        .scan(false)?;
        Ok(())
    }

    fn nested_command(&mut self, words: Vec<String>, depth: usize) -> Check<Option<Command>> {
        if depth > DEPTH_LIMIT {
            return Err("The shell nesting is too deep to check. Split the command.".into());
        }
        for script in commands::embedded(&words) {
            match script {
                Embedded::Script(text) => self.nested(&text)?,
                Embedded::Command(args) => {
                    if let Some(command) = self.nested_command(args.to_owned(), depth + 1)? {
                        self.parsed.commands.push(command);
                    }
                }
            }
        }
        if words
            .get(commands::command_index(&words))
            .is_some_and(|w| matches!(commands::basename(w), "cd" | "pushd" | "git"))
        {
            return Ok(Some(Command {
                words,
                scope: self.scope,
            }));
        }
        Ok(None)
    }

    fn end_command(&mut self) -> Check<()> {
        if !self.words.is_empty() || self.redirected {
            let words = mem::take(&mut self.words);
            self.pipe.interpreters.push(commands::reads_stdin(&words));
            if let Some(command) = self.nested_command(words, self.depth)? {
                self.pipe.commands.push(command);
            }
            self.redirected = false;
        }
        Ok(())
    }

    fn end_pipeline(&mut self) -> Check<()> {
        self.end_command()?;
        let mut pipe = mem::take(&mut self.pipe);
        self.parsed.commands.append(&mut pipe.commands);
        // A heredoc on one command also supplies a shell downstream of that command.
        let mut feeds_shell = false;
        for flag in pipe.interpreters.iter_mut().rev() {
            feeds_shell |= *flag;
            *flag = feeds_shell;
        }
        self.heredocs.extend(
            pipe.delimiters
                .into_iter()
                .map(|(index, delimiter)| (pipe.interpreters.get(index) == Some(&true), delimiter)),
        );
        Ok(())
    }

    fn read_heredocs(&mut self) -> Check<()> {
        for (code, delimiter) in mem::take(&mut self.heredocs) {
            let start = self.pos;
            let mut end = start;
            while self.pos < self.text.len() {
                let line_start = self.pos;
                let line = self
                    .remaining()
                    .split_once('\n')
                    .map_or(self.remaining(), |(line, _)| line);
                self.pos = (self.pos + line.len() + 1).min(self.text.len());
                if line.trim_matches([' ', '\t']) == delimiter {
                    end = line_start;
                    break;
                }
                end = self.pos;
            }
            if code {
                self.nested(&self.text[start..end])?;
            }
        }
        Ok(())
    }

    fn open(&mut self, kind: u8) -> Check<()> {
        self.end_pipeline()?;
        self.groups.push((kind, self.scope));
        if kind == b'(' {
            self.scope = self.child_scope();
        }
        Ok(())
    }

    fn close(&mut self, kind: u8) -> Check<bool> {
        if self.groups.last().is_none_or(|(open, _)| *open != kind) {
            return Ok(false);
        }
        self.end_pipeline()?;
        self.scope = self.groups.pop().unwrap().1;
        Ok(true)
    }

    fn scan(mut self, until_paren: bool) -> Check<usize> {
        while self.pos < self.text.len() {
            if Instant::now() >= self.deadline {
                return Err(super::TIMEOUT.into());
            }
            let rest = self.remaining();
            match rest.as_bytes()[0] {
                b' ' | b'\t' => self.pos += 1,
                b'\n' => {
                    self.pos += 1;
                    self.end_pipeline()?;
                    self.read_heredocs()?;
                }
                b'#' => self.pos += rest.find('\n').unwrap_or(rest.len()),
                b';' | b'&' | b'|'
                    if rest.starts_with(";;")
                        || rest.starts_with("&&")
                        || rest.starts_with("||") =>
                {
                    self.pos += 2;
                    self.end_pipeline()?;
                }
                b';' => {
                    self.pos += 1;
                    self.end_pipeline()?;
                }
                b'|' => {
                    self.pos += if rest.starts_with("|&") { 2 } else { 1 };
                    self.end_command()?;
                }
                b'&' if !rest.starts_with("&>") => {
                    self.pos += 1;
                    self.end_pipeline()?;
                }
                b'(' if rest.starts_with("((")
                    && (self.words.is_empty() || self.words == ["for"]) =>
                {
                    let end = rest[2..].find("))").map_or(rest.len(), |n| n + 4);
                    self.words.push(rest[..end].to_owned());
                    self.pos += end;
                }
                b'(' => {
                    self.pos += 1;
                    self.open(b'(')?;
                }
                b')' => {
                    self.pos += 1;
                    if !self.close(b'(')? {
                        self.end_pipeline()?;
                        if until_paren {
                            return Ok(self.pos);
                        }
                    }
                }
                _ => {
                    if let Some((op, len)) = redirect(rest) {
                        self.pos += len;
                        self.read_redirect(op)?;
                    } else {
                        let (word, quoted) = self.word()?;
                        if !quoted && self.words.is_empty() && word == "{" {
                            self.open(b'{')?;
                        } else if quoted
                            || word != "}"
                            || !self.words.is_empty()
                            || !self.close(b'{')?
                        {
                            self.words.push(word);
                        }
                    }
                }
            }
        }
        self.end_pipeline()?;
        self.read_heredocs()?;
        Ok(self.pos)
    }

    fn read_redirect(&mut self, op: &str) -> Check<()> {
        self.redirected = true;
        self.pos += self
            .remaining()
            .bytes()
            .take_while(|b| matches!(b, b' ' | b'\t'))
            .count();
        if matches!(op, ">&" | "<&") {
            let digits = self
                .remaining()
                .bytes()
                .take_while(u8::is_ascii_digit)
                .count();
            let hyphen = self.remaining()[digits..].starts_with('-');
            if digits > 0 || hyphen {
                self.pos += digits + usize::from(hyphen);
                return Ok(());
            }
        }
        let (target, _) = self.word()?;
        if matches!(op, "<<" | "<<-") {
            self.pipe
                .delimiters
                .push((self.pipe.interpreters.len(), target));
        }
        Ok(())
    }

    fn substitution(&mut self) -> Check<()> {
        let child = self.child_scope();
        self.pos = Parser::new(
            self.text,
            self.pos + 2,
            self.depth + 1,
            child,
            self.parsed,
            self.deadline,
        )?
        .scan(true)?;
        Ok(())
    }

    fn arithmetic(&mut self, inner: &str) -> Check<()> {
        let mut rest = inner;
        while let Some(i) = rest.find("$(") {
            if rest[i..].starts_with("$((") {
                rest = &rest[i + 3..];
                continue;
            }
            let body = &rest[i + 2..];
            let end = closing(body, b'(', b')');
            self.nested(&body[..end])?;
            rest = &body[(end + 1).min(body.len())..];
        }
        Ok(())
    }

    fn expansion(&mut self, out: &mut Vec<u8>) -> Check<bool> {
        let rest = self.remaining();
        let start = self.pos;
        if let Some(inner) = rest.strip_prefix("$((") {
            let end = closing(inner, b'(', b')');
            self.arithmetic(&inner[..end])?;
            self.pos += (3
                + end
                + 1
                + usize::from(inner.get(end + 1..).is_some_and(|s| s.starts_with(')'))))
            .min(rest.len());
        } else if rest.starts_with("$(") || rest.starts_with("<(") || rest.starts_with(">(") {
            self.substitution()?;
        } else if let Some(inner) = rest.strip_prefix('`') {
            let end = inner.find('`').unwrap_or(inner.len());
            self.nested(&inner[..end])?;
            self.pos += (end + 2).min(rest.len());
        } else {
            return Ok(false);
        }
        out.extend_from_slice(&self.text.as_bytes()[start..self.pos]);
        Ok(true)
    }

    fn word(&mut self) -> Check<(String, bool)> {
        let mut out = Vec::new();
        let mut double = false;
        let mut quoted = false;
        while self.pos < self.text.len() {
            // Structural characters are ASCII; copy other bytes as an intact UTF-8 character.
            let rest = self.remaining();
            let b = rest.as_bytes()[0];
            if (matches!(b, b'$' | b'`') || (!double && matches!(b, b'<' | b'>')))
                && self.expansion(&mut out)?
            {
                continue;
            }
            if !double && (matches!(b, b' ' | b'\t' | b'\n') || b";&|()<>".contains(&b)) {
                break;
            }
            if b == b'"' {
                double = !double;
                quoted = true;
                self.pos += 1;
            } else if b == b'\\' {
                let following = rest[1..].chars().next();
                if double && following.is_none_or(|c| !matches!(c, '$' | '`' | '"' | '\\')) {
                    out.push(b);
                }
                self.pos += 1;
                if let Some(c) = following {
                    out.extend_from_slice(&self.text.as_bytes()[self.pos..self.pos + c.len_utf8()]);
                    self.pos += c.len_utf8();
                }
            } else if !double && (b == b'\'' || rest.starts_with("$'")) {
                let ansi = b == b'$';
                let begin = 1 + usize::from(ansi);
                let inner = &rest[begin..];
                let end = quote_end(inner.as_bytes(), b'\'', ansi);
                out.extend_from_slice(&inner.as_bytes()[..end]);
                self.pos += (begin + end + 1).min(rest.len());
                quoted = true;
            } else if !double && rest.starts_with("${") {
                let len = (closing(&rest[2..], b'{', b'}') + 3).min(rest.len());
                out.extend_from_slice(&rest.as_bytes()[..len]);
                self.pos += len;
            } else {
                let len = rest.chars().next().unwrap().len_utf8();
                out.extend_from_slice(&rest.as_bytes()[..len]);
                self.pos += len;
            }
        }
        String::from_utf8(out)
            .map(|text| (text, quoted))
            .map_err(|_| "Invalid shell text.".into())
    }
}

fn redirect(rest: &str) -> Option<(&str, usize)> {
    if rest.starts_with("<(") || rest.starts_with(">(") {
        return None;
    }
    let prefix = if rest.starts_with('&') {
        1
    } else {
        rest.bytes().take_while(u8::is_ascii_digit).count()
    };
    let suffix = &rest[prefix..];
    let op = ["<<<", "<<-", "<<", ">>", ">|", "<>", ">&", "<&", ">", "<"]
        .into_iter()
        .find(|s| suffix.starts_with(s))?;
    Some((
        if rest.starts_with('&') {
            &rest[..prefix + op.len()]
        } else {
            op
        },
        prefix + op.len(),
    ))
}

fn quote_end(bytes: &[u8], quote: u8, escaped: bool) -> usize {
    let mut i = 0;
    while let Some(&b) = bytes.get(i) {
        if b == quote {
            return i;
        }
        i += if escaped && b == b'\\' { 2 } else { 1 };
    }
    bytes.len()
}

fn closing(text: &str, opening: u8, close: u8) -> usize {
    let bytes = text.as_bytes();
    let mut depth = 1usize;
    let mut i = 0;
    while let Some(&b) = bytes.get(i) {
        match b {
            b'\\' => i += 2,
            b'\'' | b'"' => i += 2 + quote_end(&bytes[i + 1..], b, b == b'"'),
            b if b == opening => {
                depth += 1;
                i += 1;
            }
            b if b == close => {
                depth -= 1;
                if depth == 0 {
                    return i;
                }
                i += 1;
            }
            _ => i += 1,
        }
    }
    bytes.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heredoc_is_code_only_if_downstream_interprets_it() {
        let script = "cat <<'A' | cat\ngit push origin main\nA\ncat <<'B' | bash\ngit push origin topic\nB\n";
        let parsed = parse(script, Instant::now() + std::time::Duration::from_secs(1)).unwrap();
        assert_eq!(parsed.commands.len(), 1);
        assert_eq!(parsed.commands[0].words, ["git", "push", "origin", "topic"]);
        assert_ne!(parsed.commands[0].scope, 0);
    }

    #[test]
    fn excessive_shell_depth_is_rejected() {
        let script = format!(
            "{}git status{}",
            "$(".repeat(DEPTH_LIMIT + 1),
            ")".repeat(DEPTH_LIMIT + 1)
        );
        assert!(parse(&script, Instant::now() + std::time::Duration::from_secs(1)).is_err());
    }
}
