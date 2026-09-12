package com.glockbender.agentwatch.ide

import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.IdeFocusManager
import com.intellij.ui.content.Content
import kotlinx.coroutines.Deferred
import java.lang.reflect.Method
import javax.swing.JComponent

/**
 * The terminal engine introduced after our minimum supported platform, 251.
 *
 * None of its types may occur in plugin bytecode signatures: 251 cannot resolve them, even
 * though the classic path still works there. Only this adapter discovers the newer API by
 * name, through the plugin's own classloader and its declared terminal dependency. The
 * process ID and focus component still come from the same public experimental getters.
 */
internal object ReworkedTerminalTabs {
    private val api by lazy { ReworkedTerminalApi.load() }

    suspend fun of(project: Project): List<TerminalTab> {
        val api = api ?: return emptyList()
        return api.tabs(project).mapNotNull { tab ->
            val view = api.view(tab) ?: return@mapNotNull null
            val shell = api.shellProcessID(view) ?: return@mapNotNull null
            val content = api.content(tab) ?: return@mapNotNull null
            TerminalTab(project, content, shell) {
                api.focusComponent(view)?.let { IdeFocusManager.getInstance(project).requestFocus(it, true) }
            }
        }
    }

    suspend fun describe(project: Project): List<String> {
        val api = api ?: return listOf("${project.name}: reworked terminal API absent")
        val tabs = api.tabs(project)
        if (tabs.isEmpty()) {
            return listOf("${project.name}: reworked terminal holds no tabs")
        }
        return tabs.map { tab ->
            val view = api.view(tab)
            "${project.name}/${api.content(tab)?.displayName}: reworked," +
                " shell=${view?.let { api.shellProcessID(it) }}"
        }
    }
}

/** Exact members used on 261, resolved together so a partial API is unavailable as a whole. */
internal class ReworkedTerminalApi private constructor(
    private val getInstance: Method,
    private val getTabs: Method,
    private val getView: Method,
    private val getContent: Method,
    private val getStartupOptions: Method,
    private val getProcessID: Method,
    private val getFocusComponent: Method,
) {
    fun tabs(project: Project): List<Any> =
        (getTabs.invoke(getInstance.invoke(null, project)) as? List<*>)?.filterNotNull() ?: emptyList()

    fun view(tab: Any): Any? = getView.invoke(tab)

    fun content(tab: Any): Content? = getContent.invoke(tab) as? Content

    fun focusComponent(view: Any): JComponent? = getFocusComponent.invoke(view) as? JComponent

    /** A starting or failed shell must not hold up a protocol command for all other tabs. */
    suspend fun shellProcessID(view: Any): Long? {
        val options = getStartupOptions.invoke(view) as? Deferred<*> ?: return null
        if (!options.isCompleted || options.isCancelled) {
            return null
        }
        val started = options.await() ?: return null
        return (getProcessID.invoke(started) as? Number)?.toLong()
    }

    companion object {
        fun load(
            loadClass: (String) -> Class<*> = { Class.forName(it, false, ReworkedTerminalApi::class.java.classLoader) },
        ): ReworkedTerminalApi? = try {
            val manager = loadClass("com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTabsManager")
            val tab = loadClass("com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTab")
            val view = loadClass("com.intellij.terminal.frontend.view.TerminalView")
            val startup = loadClass("org.jetbrains.plugins.terminal.session.TerminalStartupOptions")
            ReworkedTerminalApi(
                getInstance = manager.getMethod("getInstance", Project::class.java),
                getTabs = manager.getMethod("getTabs"),
                getView = tab.getMethod("getView"),
                getContent = tab.getMethod("getContent"),
                getStartupOptions = view.getMethod("getStartupOptionsDeferred"),
                getProcessID = startup.getMethod("getPid"),
                getFocusComponent = view.getMethod("getPreferredFocusableComponent"),
            )
        } catch (_: ReflectiveOperationException) {
            null
        } catch (_: LinkageError) {
            null
        }
    }
}
