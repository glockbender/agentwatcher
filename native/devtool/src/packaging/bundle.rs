use super::*;

pub(super) struct Settings {
    pub(super) dev: bool,
    pub(super) git: bool,
    pub(super) identity: Option<String>,
}

impl Settings {
    pub(super) fn from_env() -> Result<Self> {
        let dev = match std::env::var("AGENT_WATCH_FLAVOR")
            .as_deref()
            .unwrap_or("production")
        {
            "production" => false,
            "dev" => true,
            other => return Err(format!("unknown AGENT_WATCH_FLAVOR: {other}")),
        };
        let git = !dev
            || match std::env::var("AGENT_WATCH_DEV_GIT")
                .as_deref()
                .unwrap_or("0")
            {
                "1" => true,
                "0" => false,
                _ => return Err("AGENT_WATCH_DEV_GIT must be 0 or 1".into()),
            };
        Ok(Self {
            dev,
            git,
            identity: std::env::var("AGENT_WATCH_SIGNING_IDENTITY")
                .ok()
                .filter(|s| !s.is_empty()),
        })
    }

    pub(super) fn build(
        &self,
        root: &Path,
        configuration: &str,
        destination: Option<&Path>,
    ) -> Result<PathBuf> {
        if !matches!(configuration, "debug" | "release") {
            return Err("build-app [debug|release] [output.app]".into());
        }
        let name = if self.dev {
            "Agent Watch Dev"
        } else {
            "AgentWatch"
        };
        let app = destination.map_or_else(
            || root.join("dist").join(format!("{name}.app")),
            |p| root.join(p),
        );
        let parent = app.parent().ok_or("missing bundle parent")?;
        if app.extension() != Some(OsStr::new("app")) {
            return Err(format!("expected an .app path: {}", app.display()));
        }
        if self.dev
            && app.join("Contents/Info.plist").is_file()
            && plist(&app.join("Contents/Info.plist"), "CFBundleIdentifier")?
                == "com.glockbender.agentwatch"
        {
            return Err("Agent Watch Dev cannot replace the production app".into());
        }
        run_cmd(cmd("swift").args([
            "build",
            "--configuration",
            configuration,
            "-Xswiftc",
            "-warnings-as-errors",
        ]))?;
        let bin = PathBuf::from(output(cmd("swift").args([
            "build",
            "--configuration",
            configuration,
            "--show-bin-path",
        ]))?);
        // Build next to the destination so failed compilation or signing preserves the previous copy.
        let stage = scratch(parent)?;
        let staged = stage.join(app.file_name().ok_or("missing bundle name")?);
        self.assemble(root, &bin, &staged, name)
            .map_err(|e| format!("{e}\nBuild files: {}", stage.display()))?;
        trash(&app)?;
        io(fs::rename(&staged, &app), &app)?;
        trash(&stage)?;
        Ok(app)
    }

    fn assemble(&self, root: &Path, bin: &Path, app: &Path, name: &str) -> Result {
        let contents = app.join("Contents");
        let executables = contents.join("MacOS");
        let resources = contents.join("Resources");
        let frameworks = contents.join("Frameworks");
        for dir in [&executables, &resources, &frameworks] {
            dirs(dir)?;
        }
        for product in ["AgentWatch", "AgentWatchSend"] {
            copy(&bin.join(product), &executables.join(product))?;
        }
        run_cmd(
            cmd("ditto")
                .arg(bin.join("Sparkle.framework"))
                .arg(frameworks.join("Sparkle.framework")),
        )?;
        let info = contents.join("Info.plist");
        copy(&root.join("Resources/Info.plist"), &info)?;
        if self.dev {
            for args in [
                &["-insert", "AgentWatchFlavor", "-string", "dev"][..],
                &[
                    "-replace",
                    "CFBundleIdentifier",
                    "-string",
                    "com.glockbender.agentwatch.dev",
                ],
                &["-replace", "CFBundleDisplayName", "-string", name],
                &["-replace", "CFBundleName", "-string", name],
                &[
                    "-replace",
                    "CFBundleURLTypes.0.CFBundleURLName",
                    "-string",
                    "com.glockbender.agentwatch.dev.navigation",
                ],
                &[
                    "-replace",
                    "CFBundleURLTypes.0.CFBundleURLSchemes.0",
                    "-string",
                    "agentwatch-dev",
                ],
                &["-remove", "SUFeedURL"],
                &["-remove", "SUPublicEDKey"],
                &["-insert", "SUEnableAutomaticChecks", "-bool", "false"],
            ] {
                run_cmd(cmd("plutil").args(args).arg(&info))?;
            }
        }
        let version = plist(&info, "CFBundleShortVersionString")?;
        replace_string(&info, "CFBundleVersion", &version)?;
        run_cmd(cmd("plutil").arg("-lint").arg(&info).stdout(Stdio::null()))?;
        let widget = contents.join("PlugIns/AgentWatchWidget.appex");
        let widget_bin = widget.join("Contents/MacOS/AgentWatchWidget");
        dirs(widget_bin.parent().unwrap())?;
        let widget_info = widget.join("Contents/Info.plist");
        copy(&root.join("WidgetExtension/Info.plist"), &widget_info)?;
        if self.dev {
            for (key, value) in [
                (
                    "CFBundleIdentifier",
                    "com.glockbender.agentwatch.dev.widget",
                ),
                ("CFBundleDisplayName", name),
                ("AgentWatchURLScheme", "agentwatch-dev"),
            ] {
                replace_string(&widget_info, key, value)?;
            }
        }
        for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
            replace_string(&widget_info, key, &version)?;
        }
        let arch = output(cmd("uname").arg("-m"))?;
        run_cmd(
            cmd("xcrun")
                .args([
                    "--sdk",
                    "macosx",
                    "swiftc",
                    "-parse-as-library",
                    "-application-extension",
                    "-O",
                    "-warnings-as-errors",
                    "-module-cache-path",
                ])
                .arg(bin.join("ModuleCache"))
                .arg("-target")
                .arg(format!("{arch}-apple-macosx14.0"))
                .arg(root.join("WidgetExtension/AgentWatchWidget.swift"))
                .arg("-o")
                .arg(widget_bin),
        )?;
        if self.git {
            let target = std::env::var_os("CARGO_TARGET_DIR")
                .filter(|s| !s.is_empty())
                .map_or_else(|| root.join(".build/devtool"), |p| root.join(p));
            run_cmd(
                cmd("rustup")
                    .args([
                        "run",
                        "1.98.1",
                        "cargo",
                        "build",
                        "--release",
                        "--no-default-features",
                        "--locked",
                        "--manifest-path",
                    ])
                    .arg(root.join("native/git-protection/Cargo.toml"))
                    .arg("--target-dir")
                    .arg(&target),
            )?;
            copy(
                &target.join("release/agent-watch-git"),
                &executables.join("AgentWatchGit"),
            )?;
            let hooks = resources.join("GitProtection/hooks");
            dirs(&hooks)?;
            copy(
                &root.join("Resources/GitProtection/hooks/git-guard.sh"),
                &hooks.join("git-guard.sh"),
            )?;
        }
        let identity = self.identity.clone().unwrap_or_else(|| {
            let local = "Agent Watch Developer";
            let identities = output(cmd("security").args(["find-identity", "-p", "codesigning"])).unwrap_or_default();
            if identities.contains(&format!("\"{local}\"")) { local.into() } else {
                eprintln!("warning: using ad-hoc signing. macOS permissions will be lost on rebuild. See AGENTS.md.");
                "-".into()
            }
        });
        let sign = || {
            let mut c = cmd("codesign");
            c.args(["--force", "--sign", &identity]);
            c
        };
        run_cmd(sign().arg(executables.join("AgentWatchSend")))?;
        if self.git {
            run_cmd(sign().arg(executables.join("AgentWatchGit")))?;
        }
        run_cmd(
            sign()
                .arg("--entitlements")
                .arg(root.join("WidgetExtension/Widget.entitlements"))
                .arg(widget),
        )?;
        run_cmd(sign().arg(app))
    }
}

fn replace_string(path: &Path, key: &str, value: &str) -> Result {
    run_cmd(
        cmd("plutil")
            .args(["-replace", key, "-string", value])
            .arg(path),
    )
}

pub(super) fn dev(root: &Path, git: bool) -> Result {
    let bundle = root.join("dist/Agent Watch Dev.app");
    if bundle.exists()
        && plist(&bundle.join("Contents/Info.plist"), "CFBundleIdentifier")?
            != "com.glockbender.agentwatch.dev"
    {
        return Err(format!("unexpected app at {}", bundle.display()));
    }
    // Restart only development instances, otherwise Launch Services reuses their old environment.
    run_cmd(cmd("osascript").args(["-l", "JavaScript", "-e", r"
ObjC.import('AppKit');
const running = () => $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.glockbender.agentwatch.dev');
const apps = running();
for (let i = 0; i < apps.count; ++i) apps.objectAtIndex(i).terminate;
const until = Date.now() + 10000;
while (Number(running().count) > 0) {
    if (Date.now() >= until) throw Error('Quit Agent Watch Dev before rebuilding.');
    $.NSThread.sleepForTimeInterval(0.1);
}"]))?;
    let settings = Settings {
        dev: true,
        git,
        identity: std::env::var("AGENT_WATCH_SIGNING_IDENTITY")
            .ok()
            .filter(|s| !s.is_empty()),
    };
    settings.build(root, "debug", Some(&bundle))?;
    if plist(&bundle.join("Contents/Info.plist"), "CFBundleIdentifier")?
        != "com.glockbender.agentwatch.dev"
    {
        return Err("unexpected development bundle identifier".into());
    }
    let support = PathBuf::from(std::env::var_os("HOME").ok_or("HOME is missing")?)
        .join("Library/Application Support");
    let home = if git {
        scratch(&std::env::temp_dir())?
    } else {
        support.join("AgentWatch Dev/Home")
    };
    if git {
        println!("Open a client with its isolated profile:");
        for (client, var) in [("claude", "CLAUDE_CONFIG_DIR"), ("codex", "CODEX_HOME")] {
            let profile = home.join(format!(".{client}"));
            run_cmd(
                cmd(bundle.join("Contents/MacOS/AgentWatch"))
                    .args(["--git-hooks", "install", client])
                    .arg(&profile),
            )?;
            let quote = |p: &Path| format!("'{}'", p.display().to_string().replace('\'', "'\\''"));
            println!(
                "  HOME={} {var}={} AGENT_WATCH_HOME_DIR={} {client}",
                quote(&home),
                quote(&profile),
                quote(&home)
            );
        }
        println!("Review the new hook in Codex before using this profile.");
    }
    println!("Agent Watch Dev home: {}", home.display());
    run_cmd(
        cmd("open")
            .args(["-n", "--env"])
            .arg(format!("AGENT_WATCH_HOME_DIR={}", home.display()))
            .arg("--env")
            .arg(format!("AGENT_WATCH_SUPPORT_DIR={}", support.display()))
            .arg(&bundle),
    )
}
