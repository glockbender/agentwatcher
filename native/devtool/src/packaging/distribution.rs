use super::*;
use serde_json::Value;
use std::io::Write;

const REPO: &str = "glockbender/agentwatcher";
const SPARKLE_VERSION: &str = "2.10.0";
const SPARKLE_SHA256: &str = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c";

fn digest(file: &Path) -> Result<String> {
    let text = output(cmd("shasum").args(["-a", "256"]).arg(file))?;
    text.split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| "shasum returned no checksum".into())
}

fn download(url: &str, file: &Path) -> Result {
    run_cmd(
        cmd("curl")
            .args([
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--user-agent",
                "AgentWatch",
                "--output",
            ])
            .arg(file)
            .arg(url),
    )
}

pub(super) fn sparkle_tools(root: &Path) -> Result<PathBuf> {
    if !io(
        fs::read_to_string(root.join("Package.swift")),
        &root.join("Package.swift"),
    )?
    .contains(&format!("exact: \"{SPARKLE_VERSION}\""))
    {
        return Err(format!(
            "update the Sparkle tools pin to match Package.swift (expected {SPARKLE_VERSION})"
        ));
    }
    let cache = root
        .join(".build")
        .join(format!("sparkle-tools-{SPARKLE_VERSION}"));
    let executable = cache.join("bin/sign_update");
    use std::os::unix::fs::PermissionsExt;
    let installed = || {
        fs::metadata(&executable).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if !installed() {
        let staging = scratch(cache.parent().unwrap())?;
        let archive_name = format!("Sparkle-{SPARKLE_VERSION}.tar.xz");
        let archive = staging.join(&archive_name);
        download(
            &format!(
                "https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/{archive_name}"
            ),
            &archive,
        )?;
        if digest(&archive)? != SPARKLE_SHA256 {
            return Err(format!(
                "{archive_name} does not match its published checksum"
            ));
        }
        let unpacked = staging.join("tools");
        dirs(&unpacked)?;
        run_cmd(
            cmd("tar")
                .arg("-xf")
                .arg(&archive)
                .arg("-C")
                .arg(&unpacked)
                .arg("bin"),
        )?;
        // Concurrent builds can share the completed cache.
        if !installed() {
            let renamed = fs::rename(&unpacked, &cache);
            if !installed() {
                io(renamed, &cache)?;
                return Err(format!("missing executable at {}", executable.display()));
            }
        }
        trash(&staging)?;
    }
    Ok(cache.join("bin"))
}

fn release_version(tag: &str) -> Result<&str> {
    let version = tag.strip_prefix('v').unwrap_or(tag);
    // The tag becomes part of local paths and of the public update URL.
    if version.is_empty()
        || !version.starts_with(|c: char| c.is_ascii_digit())
        || !version
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".+-".contains(&c))
    {
        return Err(format!("invalid release version {tag:?}"));
    }
    Ok(version)
}

fn public_url(tag: &str, zip: &str) -> String {
    format!("https://github.com/{REPO}/releases/download/{tag}/{zip}")
}

fn checksum(staging: &Path, name: &str) -> Result {
    let checksum = digest(&staging.join(name))?;
    let path = staging.join(format!("{name}.sha256"));
    io(fs::write(&path, format!("{checksum}  {name}\n")), &path)
}

fn verify_signature(root: &Path, key: &str, archive: &Path, signature: &str) -> Result {
    run_cmd(
        cmd("swift")
            .arg(root.join("scripts/eddsa-verify.swift"))
            .arg(key)
            .arg(archive)
            .arg(signature),
    )
}

fn appcast(root: &Path, app: &Path, archive: &Path, version: &str, file: &Path) -> Result<bool> {
    let Some(private_key) = std::env::var_os("SPARKLE_PRIVATE_KEY").filter(|v| !v.is_empty())
    else {
        eprintln!("warning: no SPARKLE_PRIVATE_KEY, skipping appcast.xml");
        return Ok(false);
    };
    let key = plist(&app.join("Contents/Info.plist"), "SUPublicEDKey")?;
    let tools = sparkle_tools(root)?;
    let mut signer = cmd(tools.join("sign_update"))
        .args(["--ed-key-file", "-"])
        .arg(archive)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| e.to_string())?;
    let written = signer
        .stdin
        .take()
        .unwrap()
        .write_all(private_key.as_encoded_bytes());
    drop(private_key);
    let signed = signer.wait_with_output().map_err(|e| e.to_string())?;
    written.map_err(|e| format!("writing to Sparkle signing tool: {e}"))?;
    if !signed.status.success() {
        return Err(format!("Sparkle signing tool returned {}", signed.status));
    }
    let attrs = String::from_utf8(signed.stdout).map_err(|e| e.to_string())?;
    let signature = attrs
        .split_once("edSignature=\"")
        .and_then(|(_, s)| s.split_once('"'))
        .ok_or("missing Sparkle EdDSA signature")?
        .0;
    verify_signature(root, &key, archive, signature)?;
    let url = public_url(&format!("v{version}"), &format!("AgentWatch-{version}.zip"));
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let xml = output(cmd(exe).args(["appcast", version, &url, attrs.trim()]))?;
    io(fs::write(file, format!("{xml}\n")), file)?;
    Ok(true)
}

pub(super) fn release(root: &Path) -> Result {
    let dist = root.join("dist");
    let version = plist(
        &root.join("Resources/Info.plist"),
        "CFBundleShortVersionString",
    )?;
    release_version(&version)?;
    let identity = std::env::var("AGENT_WATCH_RELEASE_IDENTITY")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "-".into());
    if identity == "-" {
        eprintln!(
            "warning: building an ad-hoc signed release. See docs/distribution.md for quarantine handling. Set AGENT_WATCH_RELEASE_IDENTITY for a Developer ID signature."
        );
    }
    let app = bundle::Settings {
        dev: false,
        git: true,
        identity: Some(identity),
    }
    .build(root, "release", None)?;
    let staging = scratch(&dist)?;
    let zip = format!("AgentWatch-{version}.zip");
    let archive = staging.join(&zip);
    run_cmd(
        cmd("ditto")
            .args(["-c", "-k", "--keepParent"])
            .arg(&app)
            .arg(&archive),
    )?;
    checksum(&staging, &zip)?;
    let unpacked = staging.join("unpacked");
    run_cmd(cmd("ditto").args(["-x", "-k"]).arg(&archive).arg(&unpacked))?;
    run_cmd(
        cmd("codesign")
            .args(["--verify", "--strict"])
            .arg(unpacked.join("AgentWatch.app")),
    )?;
    let has_appcast = appcast(root, &app, &archive, &version, &staging.join("appcast.xml"))?;
    let dmg = format!("AgentWatch-{version}.dmg");
    let image_root = staging.join("image");
    dirs(&image_root)?;
    run_cmd(
        cmd("ditto")
            .arg(&app)
            .arg(image_root.join("AgentWatch.app")),
    )?;
    io(
        std::os::unix::fs::symlink("/Applications", image_root.join("Applications")),
        &image_root,
    )?;
    run_cmd(
        cmd("hdiutil")
            .args(["create", "-quiet", "-volname", "Agent Watch", "-srcfolder"])
            .arg(image_root)
            .args(["-format", "UDZO"])
            .arg(staging.join(&dmg)),
    )?;
    checksum(&staging, &dmg)?;
    run_cmd(
        cmd("codesign")
            .args(["--verify", "--strict", "--verbose=1"])
            .arg(&app),
    )?;
    println!("Gatekeeper verdict");
    let _gatekeeper = cmd("spctl")
        .args(["--assess", "--type", "execute", "--verbose=4"])
        .arg(&app)
        .status()
        .map_err(|e| e.to_string())?;
    let mut artifacts = vec![format!("{zip}.sha256"), zip, format!("{dmg}.sha256"), dmg];
    if has_appcast {
        artifacts.push("appcast.xml".into());
    } else {
        trash(&dist.join("appcast.xml"))?;
    }
    for file in artifacts {
        let path = dist.join(&file);
        io(fs::rename(staging.join(&file), &path), &path)?;
        println!("{}", path.display());
    }
    trash(&staging)
}

struct Release {
    tag: String,
    assets: Value,
    draft_access: bool,
}

impl Release {
    fn load(tag: Option<&str>) -> Result<Self> {
        if let Some(tag) = tag {
            release_version(tag)?;
        }
        let text = match tag {
            Some(tag) => output(cmd("gh").args([
                "release",
                "view",
                tag,
                "--repo",
                REPO,
                "--json",
                "tagName,assets",
            ]))?,
            None => output(cmd("curl").args([
                "--fail",
                "--silent",
                "--show-error",
                "--user-agent",
                "AgentWatch",
                &format!("https://api.github.com/repos/{REPO}/releases/latest"),
            ]))?,
        };
        let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let release_tag = value[if tag.is_some() { "tagName" } else { "tag_name" }]
            .as_str()
            .ok_or("GitHub response has no release tag")?;
        if tag.is_some_and(|t| t != release_tag) {
            return Err("GitHub returned another release".into());
        }
        release_version(release_tag)?;
        if !value["assets"].is_array() {
            return Err("GitHub response has no release assets".into());
        }
        Ok(Self {
            tag: release_tag.into(),
            assets: value["assets"].clone(),
            draft_access: tag.is_some(),
        })
    }

    fn fetch(&self, dir: &Path, name: &str) -> Result<bool> {
        let Some(asset) = self
            .assets
            .as_array()
            .unwrap()
            .iter()
            .find(|asset| asset["name"] == name)
        else {
            return Ok(false);
        };
        if self.draft_access {
            run_cmd(
                cmd("gh")
                    .args([
                        "release",
                        "download",
                        &self.tag,
                        "--repo",
                        REPO,
                        "--pattern",
                        name,
                        "--dir",
                    ])
                    .arg(dir),
            )?;
        } else {
            let url = asset["browser_download_url"]
                .as_str()
                .ok_or("GitHub response has no asset URL")?;
            download(url, &dir.join(name))?;
        }
        Ok(true)
    }
}

fn feed_field(feed: &Path, field: &str) -> Result<String> {
    output(
        cmd("xmllint")
            .args([
                "--nonet",
                "--xpath",
                &format!("string(/rss/channel/item[1]/{field})"),
            ])
            .arg(feed),
    )
}

fn inspect(root: &Path, work: &Path, release: &Release) -> Result {
    let version = release_version(&release.tag)?;
    let name = format!("AgentWatch-{version}.zip");
    let sum_name = format!("{name}.sha256");
    for required in [&name, &sum_name] {
        if !release.fetch(work, required)? {
            return Err(format!("{} lacks {required}", release.tag));
        }
    }
    let archive = work.join(&name);
    let sum_file = work.join(sum_name);
    let expected = io(fs::read_to_string(&sum_file), &sum_file)?;
    let checksum = digest(&archive)?;
    if expected.split_whitespace().collect::<Vec<_>>() != [checksum.as_str(), name.as_str()] {
        return Err(format!("{name} does not match its checksum file"));
    }
    let unpacked = work.join("unpacked");
    run_cmd(cmd("ditto").args(["-x", "-k"]).arg(&archive).arg(&unpacked))?;
    let app = unpacked.join("AgentWatch.app");
    run_cmd(cmd("codesign").args(["--verify", "--strict"]).arg(&app))?;
    if plist(
        &app.join("Contents/Info.plist"),
        "CFBundleShortVersionString",
    )? != version
    {
        return Err(format!("archive version does not match {}", release.tag));
    }
    println!("Verified {name}, its checksum, bundle signature and version.");
    if !release.fetch(work, "appcast.xml")? {
        println!("This release has no Sparkle update feed.");
        return Ok(());
    }
    let feed = work.join("appcast.xml");
    let ns = "http://www.andymatuschak.org/xml-namespaces/sparkle";
    if feed_field(
        &feed,
        &format!("*[local-name()='version' and namespace-uri()='{ns}']"),
    )? != version
        || feed_field(&feed, "enclosure/@url")? != public_url(&release.tag, &name)
        || feed_field(&feed, "enclosure/@length")?
            != io(fs::metadata(&archive), &archive)?.len().to_string()
    {
        return Err(
            "Sparkle feed version, download URL or archive length does not match the release"
                .into(),
        );
    }
    let signature = feed_field(
        &feed,
        &format!("enclosure/@*[local-name()='edSignature' and namespace-uri()='{ns}']"),
    )?;
    verify_signature(
        root,
        &plist(&root.join("Resources/Info.plist"), "SUPublicEDKey")?,
        &archive,
        &signature,
    )?;
    println!("Verified the Sparkle update feed and archive signature.");
    Ok(())
}

pub(super) fn probe(root: &Path, tag: Option<&str>) -> Result {
    let release = Release::load(tag)?;
    let work = scratch(&std::env::temp_dir())?;
    println!("Checking {}", release.tag);
    inspect(root, &work, &release).map_err(|e| format!("{e}\nProbe files: {}", work.display()))?;
    trash(&work)
}
