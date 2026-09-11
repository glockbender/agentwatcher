package com.glockbender.agentwatch.ide

import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindowManager
import com.intellij.terminal.ui.TerminalWidget
import com.intellij.ui.content.Content
import org.jetbrains.plugins.terminal.ShellTerminalWidget
import org.jetbrains.plugins.terminal.TerminalOptionsProvider
import org.jetbrains.plugins.terminal.TerminalToolWindowFactory
import org.jetbrains.plugins.terminal.TerminalToolWindowManager

private val LOG = logger<TerminalTab>()

/**
 * One terminal tab of one project, the shell running in it, and how to put the caret back in it.
 *
 * The two terminal engines share nothing at this level: the classic one hands out a widget that
 * owns the shell's tty connector and can focus itself, the reworked one a view that does neither.
 * So a tab carries what the caller actually needs — a process number to match on and a way to
 * focus — instead of the engine's own object.
 */
class TerminalTab(
    val project: Project,
    val content: Content,
    val shellProcessID: Long,
    val focusShell: () -> Unit,
)

/**
 * The terminal tabs of one project, each with the process number of its shell.
 *
 * Both engines are asked, and the answers added together. Not for symmetry: the engine is a
 * setting (Settings | Tools | Terminal | Engine), it can be changed while the IDE runs, and tabs
 * opened before the change keep the engine they were opened with. Neither manager knows about the
 * other's tabs, so neither list is ever the whole answer on its own.
 *
 * The reworked engine has been the default since 2026.1, and this function used to come back
 * empty on a stock install of it: a reworked tab keeps no `TerminalWidget`, and
 * `findWidgetByContent` — which is the classic path below — reads a key that only the classic
 * manager ever writes.
 */
suspend fun terminalTabs(project: Project): List<TerminalTab> =
    reworkedTabs(project) + classicTabs(project)

/**
 * Whether [processID] is this shell's, or something it started.
 *
 * The agent is not the shell: `claude` runs as a child of the shell the tab opened, and a
 * shell may have wrapped it in more than one process. So the question is ancestry, asked
 * upwards from the agent — the direction that terminates, since every chain reaches init.
 *
 * The depth is a guard against nothing in particular, which is why it is generous: a chain
 * that long means something is wrong with the tree and the honest answer is "no".
 */
fun isDescendant(processID: Long, shellProcessID: Long, maximumDepth: Int = 32): Boolean {
    var handle = ProcessHandle.of(processID).orElse(null) ?: return false
    repeat(maximumDepth) {
        if (handle.pid() == shellProcessID) {
            return true
        }
        handle = handle.parent().orElse(null) ?: return false
    }
    return false
}

/**
 * What this plugin can actually see of one project's terminal, said in words for the log.
 *
 * Written because the first measurement on a live IDE came back as "no tabs at all", and an
 * empty list has too many causes to act on. It now names the engine in the settings and asks both
 * managers, so the line distinguishes an IDE whose reworked API this plugin cannot reach from one
 * where it can but the tabs have no shell yet.
 */
suspend fun describeTerminalTabs(project: Project): List<String> {
    val engine = runCatching { TerminalOptionsProvider.instance.terminalEngine.name }
        .getOrElse { "unreadable" }
    val reworked = try {
        ReworkedTerminalTabs.describe(project)
    } catch (error: LinkageError) {
        listOf("${project.name}: reworked terminal API absent ($error)")
    }
    return listOf("${project.name}: engine setting is $engine") + reworked + describeClassicTabs(project)
}

/** Bringing one tab to the front, once its window already is. */
object TerminalToolWindow {
    fun activate(tab: TerminalTab) {
        // The tool window may be collapsed, and a selected tab inside a collapsed tool window
        // is not something a person can see.
        ToolWindowManager.getInstance(tab.project)
            .getToolWindow(TerminalToolWindowFactory.TOOL_WINDOW_ID)
            ?.activate(null, true)
        // The tab's own content manager rather than the tool window's: a split terminal nests
        // one inside the other, and this is the same question for either engine.
        tab.content.manager?.setSelectedContent(tab.content, true)
        tab.focusShell()
    }
}

private suspend fun reworkedTabs(project: Project): List<TerminalTab> =
    try {
        ReworkedTerminalTabs.of(project)
    } catch (error: LinkageError) {
        // Expected on an IDE older than the reworked API, which `since-build` still admits. The
        // classic path below is the whole answer there, so this is a note and not a failure.
        LOG.info("agent-watch: reworked terminal API absent, classic tabs only ($error)")
        emptyList()
    }

private fun classicTabs(project: Project): List<TerminalTab> {
    val toolWindow = TerminalToolWindowManager.getInstance(project).toolWindow ?: return emptyList()
    return toolWindow.contentManager.contents.mapNotNull { content ->
        val widget = TerminalToolWindowManager.findWidgetByContent(content) ?: return@mapNotNull null
        val shell = shellProcessID(widget) ?: return@mapNotNull null
        TerminalTab(project, content, shell) { widget.requestFocus() }
    }
}

/**
 * The shell behind a classic tab's widget.
 *
 * Through the platform's own unwrapper rather than a cast: a connector is routinely wrapped, and
 * `as? ProcessTtyConnector` answers "no shell here" for every wrapped one instead of looking
 * inside. A remote session has no local process and correctly comes back as nothing.
 */
private fun shellProcessID(widget: TerminalWidget): Long? {
    val connector = runCatching { widget.ttyConnector }.getOrNull() ?: return null
    return ShellTerminalWidget.getProcessTtyConnector(connector)?.process?.pid()
}

private fun describeClassicTabs(project: Project): List<String> {
    val toolWindow = TerminalToolWindowManager.getInstance(project).toolWindow
        ?: return listOf("${project.name}: no terminal tool window")
    val contents = toolWindow.contentManager.contents
    if (contents.isEmpty()) {
        return listOf("${project.name}: terminal tool window holds no tabs")
    }
    return contents.map { content ->
        val widget = TerminalToolWindowManager.findWidgetByContent(content)
        "${project.name}/${content.displayName}: classic widget=${widget?.javaClass?.name}" +
            ", shell=${widget?.let(::shellProcessID)}"
    }
}
