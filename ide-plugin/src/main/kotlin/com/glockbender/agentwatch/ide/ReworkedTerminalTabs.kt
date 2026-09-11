package com.glockbender.agentwatch.ide

import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.IdeFocusManager
import com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTabsManager
import com.intellij.terminal.frontend.view.TerminalView

/**
 * The terminal tabs of the engine that became the default in 2026.1.
 *
 * Kept in a file of its own, and reached only from behind a `LinkageError` guard, because every
 * type named here appeared after the `since-build` this plugin declares. A JVM resolves a class's
 * symbols the first time that class is touched, so an IDE without this API fails here and nowhere
 * else — and fails with an `Error` rather than an `Exception`, which is why the caller catches
 * `LinkageError` and not `Exception`.
 *
 * Everything used here is `@ApiStatus.Experimental`: allowed to a plugin, but free to change
 * between releases. There is no stable alternative. The reworked engine keeps its shell in a
 * session behind the view, and the tab carries no `TerminalWidget` at all — so the tty connector
 * the classic path reads simply does not exist on this side.
 */
internal object ReworkedTerminalTabs {
    suspend fun of(project: Project): List<TerminalTab> =
        TerminalToolWindowTabsManager.getInstance(project).tabs.mapNotNull { tab ->
            val shell = shellProcessID(tab.view) ?: return@mapNotNull null
            TerminalTab(project, tab.content, shell) { focus(project, tab.view) }
        }

    suspend fun describe(project: Project): List<String> {
        val tabs = TerminalToolWindowTabsManager.getInstance(project).tabs
        if (tabs.isEmpty()) {
            return listOf("${project.name}: reworked terminal holds no tabs")
        }
        return tabs.map { tab ->
            val started = if (tab.view.startupOptionsDeferred.isCompleted) "started" else "starting"
            "${project.name}/${tab.content.displayName}: reworked, $started," +
                " shell=${shellProcessID(tab.view)}"
        }
    }

    /**
     * The shell's process number, or nothing while the tab is still starting.
     *
     * Read without waiting on purpose. This runs over every tab of every open project, so one tab
     * whose shell never started would otherwise hold up the whole protocol command — and a tab
     * with an agent running in it completed this long ago.
     */
    private suspend fun shellProcessID(view: TerminalView): Long? {
        val options = view.startupOptionsDeferred
        if (!options.isCompleted) {
            return null
        }
        // Completed, so this does not suspend; it only unwraps. It still throws when the tab
        // failed to start, which is a "no shell here" and not something to report.
        return runCatching { options.await() }.getOrNull()?.pid
    }

    private fun focus(project: Project, view: TerminalView) {
        // The classic widget focuses itself; a view only says which of its components should take
        // the caret, and leaves the asking to the platform.
        IdeFocusManager.getInstance(project).requestFocus(view.preferredFocusableComponent, true)
    }
}
