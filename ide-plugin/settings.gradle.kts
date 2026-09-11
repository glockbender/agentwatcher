// A build of its own, deliberately not part of the Swift package: `swift build` never sees
// this directory, and Gradle never sees the rest of the repository.
rootProject.name = "agent-watch-ide"

plugins {
    // Lets the build fetch the JDK it needs instead of requiring one to be installed first.
    // With the wrapper fetching Gradle and this fetching the toolchain, `./gradlew` is the
    // only thing a person needs to have — nothing is installed on the machine outside
    // Gradle's own cache.
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
