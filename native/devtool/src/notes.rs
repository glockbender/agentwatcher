use regex::Regex;
use std::{fs, process::Command};

fn read(path: &str) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))
}

fn section<'a>(text: &'a str, version: &str) -> Result<(&'a str, &'a str), String> {
    let prefix = format!("## [{version}]");
    let mut lines = text.split_inclusive('\n');
    while let Some(line) = lines.next() {
        if line.starts_with(&prefix) {
            let start = text.len() - lines.clone().map(str::len).sum::<usize>();
            let len = lines
                .take_while(|s| !s.starts_with("## "))
                .map(str::len)
                .sum::<usize>();
            return Ok((
                line.trim_end_matches(['\r', '\n']),
                text[start..start + len].trim(),
            ));
        }
    }
    Err(format!(
        "CHANGELOG.md has no '## [{version}] - YYYY-MM-DD' section"
    ))
}

fn check(text: &str, version: &str) -> Result<(), String> {
    let (heading, body) = section(text, version)?;
    let mut errors = Vec::new();
    if !Regex::new(r"^ - [0-9]{4}-[0-9]{2}-[0-9]{2}$")
        .unwrap()
        .is_match(heading.strip_prefix(&format!("## [{version}]")).unwrap())
    {
        errors.push(format!(
            "'{heading}': the heading ends with ' - YYYY-MM-DD', the release date"
        ));
    }
    if body.is_empty() {
        errors.push(format!("'{heading}': the section is empty"));
    }
    let mut bullets = Vec::<String>::new();
    for line in body.lines() {
        if let Some(item) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) {
            bullets.push(item.to_owned());
        } else if line.starts_with("  ")
            && let Some(last) = bullets.last_mut()
        {
            last.push(' ');
            last.push_str(line.trim());
        }
    }
    for bullet in bullets {
        let length = bullet.split_whitespace().count();
        if length > 50 {
            errors.push(format!(
                "{length} words, the limit is 50: {}…",
                bullet.chars().take(60).collect::<String>()
            ));
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("\n"))
    }
}

fn xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn feed(
    version: &str,
    url: &str,
    sig: &str,
    changelog: &str,
    minimum: &str,
) -> Result<String, String> {
    let sig = sig.trim();
    if !Regex::new(r#"^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$"#)
        .unwrap()
        .is_match(sig)
    {
        return Err("Unexpected signature or archive length from sign_update".into());
    }
    let description = changelog.replace("]]>", "]]]]><![CDATA[>");
    let (version, url, minimum) = (xml(version), xml(url), xml(minimum));
    Ok(format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Watch</title>
    <item>
      <title>{version}</title>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{description}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sig} />
    </item>
  </channel>
</rss>
"#
    ))
}

pub fn run(command: &str, args: &[String]) -> Result<(), String> {
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    match (command, args.as_slice()) {
        ("changelog", [action @ ("check" | "section"), version, rest @ ..]) if rest.len() <= 1 => {
            let text = read(rest.first().copied().unwrap_or("CHANGELOG.md"))?;
            if *action == "check" {
                check(&text, version)
            } else {
                println!("{}", section(&text, version)?.1);
                Ok(())
            }
        }
        ("appcast", [version, url, sig, rest @ ..]) if rest.len() <= 1 => {
            let output = Command::new("/usr/bin/plutil")
                .args([
                    "-extract",
                    "LSMinimumSystemVersion",
                    "raw",
                    "-o",
                    "-",
                    "Resources/Info.plist",
                ])
                .output()
                .map_err(|e| e.to_string())?;
            if !output.status.success() {
                return Err("Cannot read LSMinimumSystemVersion from Resources/Info.plist".into());
            }
            let body = read(rest.first().copied().unwrap_or("CHANGELOG.md"))?;
            print!(
                "{}",
                feed(
                    version,
                    url,
                    sig,
                    &body,
                    String::from_utf8_lossy(&output.stdout).trim()
                )?
            );
            Ok(())
        }
        ("release-notes", [version]) => {
            let text = read("CHANGELOG.md")?;
            let changes = section(&text, version)?.1;
            let mut checksums = String::new();
            for ext in ["dmg", "zip"] {
                checksums.push_str(&read(&format!("dist/AgentWatch-{version}.{ext}.sha256"))?);
            }
            print!(
                include_str!("release-notes.md.in"),
                changes = changes,
                version = version,
                checksums = checksums.trim_end()
            );
            Ok(())
        }
        _ => Err(format!("Invalid arguments for {command}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const TEXT: &str = "## [Unreleased]\n\n- Next.\n\n## [1] - 2026-01-02\n\n### Fixed\n\n- One.\n\n## [0]\n\n- Zero.\n";
    #[test]
    fn reads_release_sections_and_checks_wrapped_bullets() {
        assert_eq!(section(TEXT, "1").unwrap().1, "### Fixed\n\n- One.");
        assert_eq!(section(TEXT, "0").unwrap().1, "- Zero.");
        assert!(check(TEXT, "1").is_ok());
        assert!(check(TEXT, "2").is_err());
        assert!(check(TEXT, "0").unwrap_err().contains("YYYY-MM-DD"));
        assert!(
            check("## [1] - 2026-01-02\n## [0]", "1")
                .unwrap_err()
                .contains("empty")
        );
        let long = format!("- {}\n  {}", "word ".repeat(30), "more ".repeat(30));
        assert!(
            check(&TEXT.replace("- One.", &long), "1")
                .unwrap_err()
                .contains("60 words")
        );
    }
    #[test]
    fn feed_preserves_markup_inside_release_notes_and_escapes_attributes() {
        let sig = r#"sparkle:edSignature="abc+/==" length="100""#;
        let doc = feed(
            "1",
            "https://example.org/a?x=1&y=2",
            sig,
            "body ]]> tail & <tag>",
            "14.0",
        )
        .unwrap();
        assert!(doc.contains("x=1&amp;y=2"));
        assert!(doc.contains("body ]]]]><![CDATA[> tail & <tag>"));
        assert!(doc.contains(sig));
        assert!(doc.contains("<sparkle:version>1</sparkle:version>"));
        for bad in ["", r#"sparkle:edSignature="x" length="1" extra="tag""#] {
            assert!(feed("1", "url", bad, "", "14").is_err());
        }
    }
}
