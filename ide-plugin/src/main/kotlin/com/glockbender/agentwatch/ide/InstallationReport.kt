package com.glockbender.agentwatch.ide

import java.nio.file.Path
import java.nio.file.Paths

/**
 * How the plugin answers the one question Agent Watch cannot answer by itself: am I here?
 *
 * A directory on disk proves that a file was copied. It does not prove that this IDE read it,
 * loaded it, or is the version Agent Watch expects — and those are the three ways an install
 * quietly fails. So the answer comes from inside the IDE: Agent Watch opens the plugin's own
 * address with a token it just made up, and the plugin writes that token back into a file
 * Agent Watch owns. The token is what makes the answer an answer rather than a leftover from
 * a week ago.
 *
 * The same reply carries the plugin's version and the IDE's build, because "installed" and
 * "installed and current" are different states in the tooling window, and because the reply
 * doubles as the measurement of whether the address reaches this product at all.
 */
object InstallationReport {
    /**
     * The place Agent Watch reads, named here rather than taken from the address.
     *
     * Taking it from the address would be neater and is the reason not to: any page in a
     * browser can open a `jetbrains://` link, so a path parameter would hand the whole web a
     * way to make the IDE write a file wherever the IDE can write. Hard-coded, the worst a
     * hostile link can do is overwrite our own reply with a token nobody is waiting for.
     */
    fun replyFile(userHome: Path, dataDirectory: String): Path =
        userHome
            .resolve("Library/Application Support/AgentWatch/ide-plugins")
            .resolve("$dataDirectory.json")

    /**
     * The token as it will be written, or nothing when it is not a token.
     *
     * Agent Watch makes these, but the address they arrive in is open to anyone, so the shape
     * is checked rather than trusted: letters and digits, long enough to be worth comparing,
     * short enough that the file stays a file.
     */
    fun acceptedToken(raw: String?): String? {
        val token = raw ?: return null
        if (token.length !in 8..64) {
            return null
        }
        return token.takeIf { it.all(Char::isLetterOrDigit) }
    }

    /** The reply itself. Hand-built because it has four fields and no library is worth it. */
    fun reply(token: String, pluginVersion: String?, ideBuild: String, answeredAt: String): String =
        """
        {"token":${quoted(token)},"pluginVersion":${quoted(pluginVersion)},"ideBuild":${quoted(ideBuild)},"answeredAt":${quoted(answeredAt)}}
        """.trimIndent()

    /** The last component of the IDE's configuration path is what JetBrains calls the data
     * directory name — the same name Agent Watch reads out of `product-info.json` in the
     * bundle, which is what lets the two sides meet on one file name. */
    fun dataDirectory(configPath: String): String =
        Paths.get(configPath).fileName?.toString() ?: "unknown"

    private fun quoted(value: String?): String {
        if (value == null) {
            return "null"
        }
        val escaped = StringBuilder(value.length + 2)
        for (character in value) {
            when {
                character == '"' || character == '\\' -> escaped.append('\\').append(character)
                character < ' ' -> escaped.append("\\u%04x".format(character.code))
                else -> escaped.append(character)
            }
        }
        return "\"$escaped\""
    }
}
