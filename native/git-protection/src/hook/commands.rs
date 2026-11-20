//! Which shell words name a program, and which arguments that program executes as code.

pub(super) fn basename(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

fn wrapper(name: &str) -> Option<&'static [&'static str]> {
    Some(match name {
        "sudo" => &["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"],
        "doas" => &["-u", "-C"],
        "env" => &["-u", "-C", "-S", "--split-string"],
        "exec" => &["-a"],
        "nice" => &["-n"],
        "timeout" | "gtimeout" => &["-k", "-s", "--kill-after", "--signal"],
        "xargs" => &["-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a"],
        "stdbuf" => &["-i", "-o", "-e"],
        "caffeinate" => &["-t", "-w"],
        "ionice" => &["-c", "-n", "-p"],
        "command" | "builtin" | "nohup" | "time" | "chronic" => &[],
        _ => return None,
    })
}

fn assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| {
        let mut bytes = name.bytes();
        bytes
            .next()
            .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
            && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
    })
}

pub(super) fn command_index(words: &[String]) -> usize {
    let mut i = words
        .iter()
        .take_while(|word| {
            matches!(
                word.as_str(),
                "!" | "{"
                    | "}"
                    | "if"
                    | "then"
                    | "elif"
                    | "else"
                    | "fi"
                    | "do"
                    | "done"
                    | "while"
                    | "until"
            )
        })
        .count();
    while let Some(word) = words.get(i) {
        if assignment(word) {
            i += 1;
            continue;
        }
        let name = basename(word);
        let Some(options) = wrapper(name) else { break };
        i += 1;
        while let Some(option) = words.get(i).filter(|o| o.starts_with('-')) {
            i += 1;
            if option == "--" {
                break;
            }
            i += usize::from(options.contains(&option.as_str()));
        }
        i += usize::from(matches!(name, "timeout" | "gtimeout"));
    }
    i.min(words.len())
}

pub(super) fn git_subcommand(args: &[String]) -> usize {
    let mut i = 0;
    while let Some(option) = args.get(i).filter(|o| o.starts_with('-')) {
        i += if matches!(
            option.as_str(),
            "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" | "--config-env"
        ) {
            2
        } else {
            1
        };
    }
    i.min(args.len())
}

fn is_shell(word: &str) -> bool {
    matches!(
        basename(word),
        "sh" | "bash" | "zsh" | "dash" | "ksh" | "fish"
    )
}

fn shell_position(words: &[String], i: usize) -> Option<usize> {
    let name = basename(words.get(i)?);
    if is_shell(name) {
        return Some(i);
    }
    if matches!(name, "docker" | "podman" | "nerdctl" | "kubectl") {
        return words[i + 1..]
            .iter()
            .position(|w| is_shell(w))
            .map(|n| i + 1 + n);
    }
    None
}

fn shell_script<T: AsRef<str>>(args: &[T]) -> Option<&str> {
    let mut i = 0;
    let mut script = false;
    while let Some(option) = args.get(i).map(AsRef::as_ref) {
        match option {
            "-o" | "+o" | "-O" | "+O" | "--rcfile" | "--init-file" => i += 2,
            "--" => {
                i += 1;
                break;
            }
            _ if option.starts_with("--") => i += 1,
            _ if option.starts_with('-') && option.len() > 1 => {
                script |= option.contains('c');
                i += 1 + usize::from(option.ends_with(['o', 'O']));
            }
            _ => break,
        }
    }
    args.get(i).filter(|_| script).map(AsRef::as_ref)
}

fn remote_script(args: &[String]) -> String {
    let mut i = 0;
    while let Some(option) = args.get(i).filter(|w| w.starts_with('-')) {
        i += 1 + usize::from(
            option.len() == 2 && b"bcDEeFIiJLlmOopQRSWw".contains(&option.as_bytes()[1]),
        );
    }
    args.get(i + 1..).unwrap_or_default().join(" ")
}

pub(super) fn reads_stdin(words: &[String]) -> bool {
    let i = command_index(words);
    if let Some(shell) = shell_position(words, i) {
        return shell_script(&words[shell + 1..]).is_none();
    }
    if words.get(i).is_some_and(|w| basename(w) == "ssh") {
        let remote = remote_script(&words[i + 1..]);
        let args: Vec<_> = remote.split_whitespace().collect();
        return args.is_empty() || (is_shell(args[0]) && shell_script(&args[1..]).is_none());
    }
    i == words.len()
        && words.iter().any(|w| basename(w) == "sudo")
        && words.iter().any(|w| matches!(w.as_str(), "-s" | "-i"))
}

pub(super) enum Embedded<'a> {
    Script(String),
    Command(&'a [String]),
}

pub(super) fn embedded(words: &[String]) -> Vec<Embedded<'_>> {
    let mut result = Vec::new();
    let i = command_index(words);
    let mut has_env = false;
    for (position, word) in words[..i].iter().enumerate() {
        has_env |= basename(word) == "env";
        if has_env
            && matches!(word.as_str(), "-S" | "--split-string")
            && let Some(value) = words.get(position + 1)
        {
            result.push(Embedded::Script(value.clone()));
        }
    }
    let Some(name) = words.get(i).map(|w| basename(w)) else {
        return result;
    };
    let rest = &words[i + 1..];
    if let Some(shell) = shell_position(words, i) {
        if let Some(script) = shell_script(&words[shell + 1..]) {
            result.push(Embedded::Script(script.to_owned()));
        }
        return result;
    }
    match name {
        "eval" => result.push(Embedded::Script(rest.join(" "))),
        "ssh" => result.push(Embedded::Script(remote_script(rest))),
        "watch" => {
            let mut pos = 0;
            while let Some(option) = rest.get(pos).filter(|w| w.starts_with('-')) {
                pos += 1 + usize::from(matches!(
                    option.as_str(),
                    "-n" | "--interval" | "-q" | "--equexit"
                ));
            }
            if let Some(script) = rest.get(pos..) {
                result.push(Embedded::Script(script.join(" ")));
            }
        }
        "parallel" => {
            if let Some(template) = rest
                .iter()
                .find(|w| !w.starts_with('-'))
                .filter(|w| *w != ":::")
            {
                result.push(Embedded::Script(template.clone()));
            }
        }
        "git" => {
            let pos = git_subcommand(rest);
            if let [subcommand, operation, args @ ..] = &rest[pos..] {
                if subcommand == "submodule" && operation == "foreach" {
                    let script = args
                        .iter()
                        .map(String::as_str)
                        .filter(|w| !matches!(*w, "--recursive" | "-q" | "--quiet"))
                        .collect::<Vec<_>>()
                        .join(" ");
                    result.push(Embedded::Script(script));
                } else if subcommand == "bisect" && operation == "run" {
                    result.push(Embedded::Command(args));
                }
            }
        }
        "find" => {
            for (j, word) in rest.iter().enumerate() {
                if matches!(word.as_str(), "-exec" | "-execdir")
                    && rest.get(j + 1).is_some_and(|w| is_shell(w))
                    && let Some(script) = shell_script(&rest[j + 2..])
                {
                    result.push(Embedded::Script(script.to_owned()));
                }
            }
        }
        _ => {}
    }
    result
}
