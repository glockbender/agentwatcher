import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    kotlin("jvm") version "2.4.20"
    id("org.jetbrains.intellij.platform") version "2.18.1"
}

group = "com.glockbender.agentwatch"
version = "0.1.3"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

// Built against an IDE that is already on the machine rather than one Gradle downloads: the
// distribution is a gigabyte and a person building this plugin has the IDE by definition.
// `-Pagentwatch.ide.path=…` overrides, which is also how another product — PyCharm, IDEA —
// gets built against.
val ideHome: String =
    (findProperty("agentwatch.ide.path") as String?)
        ?: listOf(
            "${System.getProperty("user.home")}/Applications/GoLand.app",
            "/Applications/GoLand.app",
            "${System.getProperty("user.home")}/Applications/IntelliJ IDEA.app",
            "/Applications/IntelliJ IDEA.app",
        ).firstOrNull { file(it).isDirectory }
        ?: error(
            "No JetBrains IDE found to build against. Pass -Pagentwatch.ide.path=/path/to/Your.app"
        )

dependencies {
    intellijPlatform {
        local(ideHome)
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
            // The IDE already on this machine, for the same reason the build uses it. The
            // verifier answers one question this project cannot answer by reading code: whether
            // every class the plugin references is reachable from the plugin's own classloader
            // at runtime — which is exactly what a dependency on a bundled plugin's module
            // decides. `task plugin` leaves it out; run `./gradlew verifyPlugin` when the set of
            // platform classes used changes, and before publishing.
            local(ideHome)
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
