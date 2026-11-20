use serde::Deserialize;
use serde_json::{Value, json};
use std::path::Path;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Arguments {
    pub repository: String,
    #[serde(default = "default_remote")]
    pub remote: String,
    pub destination: String,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default, deserialize_with = "source_argument")]
    pub source: Option<String>,
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub delete: bool,
}

fn source_argument<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    String::deserialize(deserializer).map(Some)
}

fn default_remote() -> String {
    "origin".into()
}

pub fn valid_text(text: &str) -> bool {
    !text.is_empty() && !text.chars().any(char::is_control)
}

pub fn valid_oid(oid: &str) -> bool {
    matches!(oid.len(), 40 | 64)
        && oid
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn repository_name(url: &str) -> Result<String, String> {
    if !valid_text(url) || url.starts_with('-') {
        return Err("The push URL is not supported.".into());
    }
    let (path, local) = if let Some((scheme, rest)) = url.split_once("://") {
        if !matches!(scheme, "https" | "ssh" | "file") || rest.contains(['?', '#']) {
            return Err(
                "Only HTTPS, SSH and local file URLs without query or fragment are supported."
                    .into(),
            );
        }
        let (authority, path) = rest
            .split_once('/')
            .ok_or("The URL needs a repository path.")?;
        if scheme == "file" {
            if !authority.is_empty() {
                return Err("Only local file URLs are supported.".into());
            }
        } else {
            let host = if let Some((user, host)) = authority.split_once('@') {
                if scheme != "ssh" || user.is_empty() || user.contains(':') {
                    return Err("Use a push URL without embedded credentials.".into());
                }
                host
            } else {
                authority
            };
            if host.is_empty()
                || !host
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".-:[]".contains(&b))
            {
                return Err("The push URL needs a valid host.".into());
            }
        }
        let bytes = path.as_bytes();
        let mut decoded = Vec::new();
        let mut index = 0;
        while index < bytes.len() {
            if bytes[index] == b'%' {
                let hex = path
                    .get(index + 1..index + 3)
                    .ok_or("Invalid URL escape.")?;
                decoded.push(u8::from_str_radix(hex, 16).map_err(|_| "Invalid URL escape.")?);
                index += 3;
            } else {
                decoded.push(bytes[index]);
                index += 1;
            }
        }
        (
            String::from_utf8(decoded).map_err(|_| "Invalid URL text.")?,
            scheme == "file",
        )
    } else if url.starts_with('/') {
        (url.to_owned(), true)
    } else if let Some((host, path)) = url.split_once(':') {
        if host.is_empty()
            || path.is_empty()
            || path.contains(':')
            || !host
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b".-_@".contains(&b))
        {
            return Err("The SSH destination is not supported.".into());
        }
        (path.to_owned(), false)
    } else {
        return Err("Use an absolute local path or an HTTPS/SSH push URL.".into());
    };
    if !valid_text(&path) {
        return Err("The repository path contains control characters.".into());
    }
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let name = if local {
        Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
    } else {
        path.trim_start_matches('/')
    };
    if matches!(name, "" | "." | "..") {
        return Err("The URL does not identify a repository.".into());
    }
    Ok(name.into())
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Risk {
    ProtectedBranch,
    ForceUpdate,
    DeleteBranch,
    DeleteProtectedBranch,
    DeleteTag,
}

pub struct Plan {
    pub repository: String,
    pub git_directory: String,
    pub remote: String,
    pub url: String,
    pub name: String,
    pub destination: String,
    pub source: String,
    pub new: String,
    pub old: String,
    pub delete: bool,
    pub risks: Vec<Risk>,
    pub reason: Option<String>,
    pub remote_options: Vec<String>,
    pub command: Vec<String>,
}

pub fn quote(text: &str) -> String {
    if !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&b))
    {
        text.into()
    } else {
        format!("'{}'", text.replace('\'', "'\"'\"'"))
    }
}

impl Plan {
    pub fn single_click_delete(&self) -> bool {
        self.risks == [Risk::DeleteBranch]
    }

    pub fn stopped(&self, reason: &str) -> Value {
        json!({"status":"not_pushed", "message":format!("{reason} Do not retry automatically. The user may run the command in a terminal."), "repository":self.name, "manual_command":self.command.iter().map(|s| quote(s)).collect::<Vec<_>>().join(" ")})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_and_quoted_commands() {
        for url in [
            "git@example.invalid:owner/project.git",
            "https://example.invalid/owner/project.git",
            "ssh://git@example.invalid/owner/project.git",
        ] {
            assert_eq!(repository_name(url).unwrap(), "owner/project");
        }
        for url in [
            "ext::bad command",
            "https://user@host/project",
            "ssh://u:p@host/p",
            "https://host/p?token=x",
            "https://host/p#fragment",
            "relative",
            "file://remote/p",
            "https://host/p%0a",
        ] {
            assert!(repository_name(url).is_err(), "{url}");
        }
        assert_eq!(quote("a'b $()"), "'a'\"'\"'b $()'");
    }
}
