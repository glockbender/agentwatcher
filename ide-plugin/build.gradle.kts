import org.jetbrains.intellij.platform.gradle.IntelliJPlatformType
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    kotlin("jvm") version "2.4.20"
    id("org.jetbrains.intellij.platform") version "2.18.1"
}

group = "com.glockbender.agentwatch"
version = "0.1.4"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

// Built against an IDE already on the machine when there is one: the distribution is about a
// gigabyte, and whoever writes this plugin has an IDE by definition. `-Pagentwatch.ide.path=…`
// names another one — that is how a build against PyCharm or IDEA is done.
// `-Pagentwatch.ide.download=true` ignores whatever is installed and builds against a fetched
// IDE. That is how the fallback below gets exercised on a machine that has an IDE.
val ideHome: String? =
    if (findProperty("agentwatch.ide.download") == "true") {
        null
    } else {
        (findProperty("agentwatch.ide.path") as String?)
            ?: listOf(
                "${System.getProperty("user.home")}/Applications/GoLand.app",
                "/Applications/GoLand.app",
                "${System.getProperty("user.home")}/Applications/IntelliJ IDEA.app",
                "/Applications/IntelliJ IDEA.app",
            ).firstOrNull { file(it).isDirectory }
    }

// Which IDE the downloaded build uses. Verification also covers the oldest supported IDE.
//
// Not the `sinceBuild` below: the build and reflection-contract test use 261, while the
// verifier also checks the minimum platform 251. New terminal types are resolved only by
// the adapter, so their names do not become binary links on older IDEs.
val fallbackIdeVersion = "2026.1.4"
val verificationIdeVersions = providers.gradleProperty("agentwatch.verify.versions")
    .map { versions -> versions.split(',').map { it.trim() }.filter { it.isNotEmpty() } }
    .getOrElse(listOf("2025.1", fallbackIdeVersion))
require(verificationIdeVersions.isNotEmpty()) { "agentwatch.verify.versions must name at least one IDE version" }

// The build/test platform requirement, checked before the reflection-contract test: `product-info.json`
// carries the build number, whose first three digits name the release — 261 is 2026.1.
// Older IDEs can run the plugin, but cannot test the newer adapter's actual API contract.
val minimumIdeRelease = 261
ideHome?.let { home ->
    val productInfo = file("$home/Contents/Resources/product-info.json")
    val release = if (productInfo.isFile) {
        Regex(""""buildNumber"\s*:\s*"(\d{3})""").find(productInfo.readText())?.groupValues?.get(1)?.toIntOrNull()
    } else {
        null
    }
    if (release != null && release < minimumIdeRelease) {
        error(
            "$home is build $release; this plugin needs 2026.1 (build 261) or newer. " +
                "Name another IDE with -Pagentwatch.ide.path=…, or build against one Gradle " +
                "fetches with -Pagentwatch.ide.download=true."
        )
    }
}

dependencies {
    intellijPlatform {
        // No IDE installed — a fresh machine, a continuous integration runner — and Gradle
        // fetches one instead of the build failing. It costs a gigabyte once and is cached
        // afterwards, which is a price worth paying only where the alternative is not
        // building at all. GoLand rather than IntelliJ IDEA Community, which would be the
        // smaller download: Community has no 2026.1 to fetch, and 2026.1 is where the
        // terminal classes the adapter contract test resolves first appeared.
        if (ideHome != null) {
            local(ideHome)
        } else {
            create(IntelliJPlatformType.GoLand, fallbackIdeVersion)
        }
        // The terminal tool window is where the sessions are. Bundled with every IDE, so it
        // is a dependency and not a download.
        bundledPlugin("org.jetbrains.plugins.terminal")
    }
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "251"
            // Left open on purpose: an upper bound turns every IDE update into a plugin that
            // silently stops loading, and the whole point of this plugin is that a person
            // does not have to think about it.
            untilBuild = provider { null }
        }
    }

    pluginVerification {
        ides {
            // Build against 261, verify both 251 and 261: the declared lower bound needs a
            // real check even on a development machine with only the newest IDE installed.
            // A comma-separated override allows a failing member to be reproduced alone.
            verificationIdeVersions.forEach { version ->
                create(IntelliJPlatformType.GoLand, version)
            }
        }
    }
}

kotlin {
    compilerOptions {
        // Below the compiler's own version and at or under what the IDE bundles: the plugin
        // brings no Kotlin runtime of its own — see `kotlin.stdlib.default.dependency` in
        // gradle.properties — so it must not ask the bundled one for anything newer.
        languageVersion = KotlinVersion.KOTLIN_2_2
        apiVersion = KotlinVersion.KOTLIN_2_2
    }
}

// The signed file keeps the name the application reads — `agent-watch-ide-<version>.zip` — so
// what CI hands to Marketplace and what goes into a release are one file under one name. A
// directory of its own, because `buildPlugin` writes the unsigned file under that same name in
// `build/distributions/`.
tasks.signPlugin {
    signedArchiveFile = layout.buildDirectory.file("signed/agent-watch-ide-$version.zip")
}

// Where Agent Watch looks for a plugin file to hand to an IDE. The application knows only this
// folder, never this repository: a release downloaded there later and a build put there now are
// the same fact to it.
//
// The file comes from the packaging task itself rather than from the newest name in
// `build/distributions/`. That directory keeps every version ever built, so picking by time
// staged whichever build ran last — rebuild an older version and the older file would quietly
// become the one offered to every IDE.
tasks.register<Copy>("stagePlugin") {
    description = "Copies the built plugin where Agent Watch looks for it"
    group = "distribution"
    from(tasks.named("buildPlugin"))
    into(File(System.getProperty("user.home"), "Library/Application Support/AgentWatch/ide-plugin"))
}
