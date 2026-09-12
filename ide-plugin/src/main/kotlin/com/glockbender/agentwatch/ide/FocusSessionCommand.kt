package com.glockbender.agentwatch.ide

import com.intellij.ide.impl.ProjectUtil
import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.openapi.application.ApplicationInfo
import com.intellij.openapi.application.JBProtocolCommand
import com.intellij.openapi.application.JBProtocolCommandResult
import com.intellij.openapi.application.EDT
import com.intellij.openapi.application.PathManager
import com.intellij.openapi.diagnostic.thisLogger
import com.intellij.openapi.extensions.PluginId
import com.intellij.openapi.project.ProjectManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.file.Files
import java.nio.file.Paths
import java.time.Instant

/**
 * Everything Agent Watch asks of an IDE, behind one address.
 *
 * `jetbrains://goland/agent-watch/focus?pid=<agent process id>` brings the terminal tab a
 * session runs in to the front. `…/agent-watch/ping?token=…` answers that this plugin is
 * loaded here at all. That is the whole transport: the platform registers the URL scheme,
 * routes the address here and runs this command, so the plugin needs no socket, no port, no
 * discovery and no authorisation of its own.
 *
 * The process number is the join for focus, and it is the strongest one available: it does
 * not depend on what the tab is called, on the "Show application title in tab name" setting,
 * or on two sessions happening to have the same name. See `docs/session-focus-research.md`.
 */
class FocusSessionCommand : JBProtocolCommand(COMMAND) {
    override suspend fun executeAndGetResult(
        target: String?,
        parameters: Map<String, String>,
        fragment: String?,
    ): JBProtocolCommandResult = when (target) {
        FOCUS -> focus(parameters)
        PING -> ping(parameters)
        else -> failure("Agent Watch: unknown command '$target'")
    }

    private suspend fun focus(parameters: Map<String, String>): JBProtocolCommandResult {
        val agentProcessID = parameters[PID]?.toLongOrNull()
            ?: return failure("Agent Watch: focus needs a numeric $PID")

        val tab = ProjectManager.getInstance().openProjects
            .flatMap { terminalTabs(it) }
            .firstOrNull { isDescendant(agentProcessID, shellProcessID = it.shellProcessID) }
            // Not an error dialog: the session may be running in a terminal that is not this
            // IDE's, or in a project that has since been closed. Agent Watch has already
            // raised the application by the time this runs, so the person is looking at the
            // right window and a dialog would only be in the way.
            //
            // Said in the log, though, and with the numbers. A tab whose connector is not a
            // process is skipped silently by `terminalTabs`, and the new terminal engine is
            // exactly where that could start happening — a miss that left no trace would be
            // indistinguishable from a plugin that never ran.
            ?: return unmatched(agentProcessID)

        withContext(Dispatchers.EDT) {
            // The window first, then the tab inside it. `focusProjectWindow` is what raises
            // the right one of several project windows; selecting a tab in a window nobody
            // can see would be precision the person never gets to use.
            ProjectUtil.focusProjectWindow(tab.project, true)
            TerminalToolWindow.activate(tab)
        }
        return JBProtocolCommandResult(null, LEAVE_THE_WINDOWS_ALONE)
    }

    /**
     * Answers that this plugin is loaded in this IDE, by writing the token back.
     *
     * Silent on every path, including refusal. Agent Watch asks this while a person is
     * looking at an installation screen, and a dialog thrown onto the IDE — or a window
     * raised — would be an interruption in answer to a question the person did not ask.
     * Whether the answer arrived is read from the file; whether it was refused is read from
     * the log.
     */
    private suspend fun ping(parameters: Map<String, String>): JBProtocolCommandResult {
        val token = InstallationReport.acceptedToken(parameters[TOKEN])
        if (token == null) {
            thisLogger().info("agent-watch ping without a usable token; nothing written")
            return JBProtocolCommandResult(null, LEAVE_THE_WINDOWS_ALONE)
        }
        val version = PluginManagerCore.getPlugin(PluginId.getId(PLUGIN_ID))?.version
        val reply = InstallationReport.reply(
            token = token,
            pluginVersion = version,
            ideBuild = ApplicationInfo.getInstance().build.asString(),
            answeredAt = Instant.now().toString(),
        )
        val file = InstallationReport.replyFile(
            userHome = Paths.get(System.getProperty("user.home")),
            dataDirectory = InstallationReport.dataDirectory(PathManager.getConfigPath()),
        )
        withContext(Dispatchers.IO) {
            // Fail open, like everything else between these two programs: the cost of losing
            // this is an installation screen that says "not answering", and it must never be
            // an exception thrown out of a protocol command.
            runCatching {
                Files.createDirectories(file.parent)
                Files.writeString(file, reply)
            }.onFailure { thisLogger().info("agent-watch ping could not write $file: $it") }
        }
        return JBProtocolCommandResult(null, LEAVE_THE_WINDOWS_ALONE)
    }

    /**
     * The second argument of `JBProtocolCommandResult` is `focusIdeWindow`, not an error
     * flag — checked with `javap` against the installed platform jar. Worth naming, because
     * reading it as "something went wrong" is exactly the mistake that was made here: every
     * path that could not do its job asked the platform to raise a window, and with no
     * project chosen the platform picks one itself.
     *
     * A failure does ask for it: the message below is a dialog, and a dialog on a window
     * nobody can see is a dialog nobody can answer.
     */
    private fun failure(message: String) = JBProtocolCommandResult(message, FOCUS_IDE_WINDOW)

    private suspend fun unmatched(agentProcessID: Long): JBProtocolCommandResult {
        val projects = ProjectManager.getInstance().openProjects
        val shells = projects.flatMap { terminalTabs(it) }.map { it.shellProcessID }
        thisLogger().info(
            "no terminal tab owns process $agentProcessID; shells seen in open projects: $shells"
        )
        // The list above is empty for four different reasons, and which one it is decides
        // what to write next. So the miss says what was there instead.
        for (line in projects.flatMap { describeTerminalTabs(it) }) {
            thisLogger().info("agent-watch saw $line")
        }
        // Nothing raised and nothing said, which is what the comment above the call promised:
        // Agent Watch has already brought the application forward, so the person is looking
        // at the right window, and raising some other project's window would move them away
        // from it.
        return JBProtocolCommandResult(null, LEAVE_THE_WINDOWS_ALONE)
    }

    companion object {
        const val COMMAND: String = "agent-watch"
        const val FOCUS: String = "focus"
        const val PING: String = "ping"
        const val PID: String = "pid"
        const val TOKEN: String = "token"
        const val PLUGIN_ID: String = "com.glockbender.agentwatch"

        /** `JBProtocolCommandResult`'s second argument: whether the platform should bring
         * an IDE window forward once the command returns. */
        private const val FOCUS_IDE_WINDOW: Boolean = true
        private const val LEAVE_THE_WINDOWS_ALONE: Boolean = false
    }
}
