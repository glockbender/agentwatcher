package com.glockbender.agentwatch.ide

import java.nio.file.Paths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The reply an installation screen waits for, and the one parameter that arrives from outside.
 */
class InstallationReportTest {
    @Test
    fun `a token is written back so the answer belongs to the question`() {
        val reply = InstallationReport.reply(
            token = "abc12345",
            pluginVersion = "0.1.0",
            ideBuild = "GO-261.26222.72",
            answeredAt = "2026-09-10T21:00:00Z",
        )

        assertEquals(
            """{"token":"abc12345","pluginVersion":"0.1.0","ideBuild":"GO-261.26222.72","answeredAt":"2026-09-10T21:00:00Z"}""",
            reply,
        )
    }

    /** A plugin loaded from a sandbox has no version at all, and the file still has to parse. */
    @Test
    fun `a missing version is null and not an empty string`() {
        val reply = InstallationReport.reply("abc12345", null, "GO-261", "now")

        assertEquals("""{"token":"abc12345","pluginVersion":null,"ideBuild":"GO-261","answeredAt":"now"}""", reply)
    }

    /**
     * None of these fields is ours end to end — the build string comes from the platform —
     * so anything quoted is escaped rather than trusted.
     */
    @Test
    fun `a quote inside a value does not break the file`() {
        val reply = InstallationReport.reply("abc12345", "0.1\"0", "GO-261", "now")

        assertEquals("""{"token":"abc12345","pluginVersion":"0.1\"0","ideBuild":"GO-261","answeredAt":"now"}""", reply)
    }

    /**
     * The address is open to anyone: a page in a browser can open a `jetbrains://` link. So
     * the token is checked for shape before it is written into a file, and nothing else in
     * the reply comes from the address at all.
     */
    @Test
    fun `only something shaped like a token is accepted`() {
        assertEquals("abc12345", InstallationReport.acceptedToken("abc12345"))
        assertNull(InstallationReport.acceptedToken(null))
        assertNull(InstallationReport.acceptedToken("short"))
        assertNull(InstallationReport.acceptedToken("a".repeat(65)))
        assertNull(InstallationReport.acceptedToken("../../etc/passwd"))
        assertNull(InstallationReport.acceptedToken("abc 12345"))
    }

    /**
     * One file per IDE, named the way both sides can arrive at independently: the plugin from
     * its own configuration path, Agent Watch from `product-info.json` in the bundle.
     */
    @Test
    fun `the reply is filed under the data directory name of this IDE`() {
        val file = InstallationReport.replyFile(Paths.get("/Users/x"), "GoLand2026.1")

        assertEquals(
            Paths.get("/Users/x/Library/Application Support/AgentWatch/ide-plugins/GoLand2026.1.json"),
            file,
        )
        assertEquals(
            "GoLand2026.1",
            InstallationReport.dataDirectory("/Users/x/Library/Application Support/JetBrains/GoLand2026.1"),
        )
    }
}
