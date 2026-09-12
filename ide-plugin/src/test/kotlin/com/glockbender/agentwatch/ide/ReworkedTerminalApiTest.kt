package com.glockbender.agentwatch.ide

import com.intellij.openapi.project.Project
import com.intellij.ui.content.Content
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.runBlocking
import javax.swing.JComponent
import javax.swing.JPanel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame

class ReworkedTerminalApiTest {
    @Test
    fun `the adapter resolves the actual build platform API`() {
        // Reflection is outside the binary verifier's reach. Check the actual terminal
        // classes on the build platform, not only stand-ins with matching method names.
        assertNotNull(ReworkedTerminalApi.load())
    }

    @Test
    fun `an older platform without reworked classes is supported`() {
        assertNull(ReworkedTerminalApi.load { throw ClassNotFoundException(it) })
    }

    @Test
    fun `a partially changed API is unavailable rather than half initialized`() {
        assertNull(ReworkedTerminalApi.load { Any::class.java })
    }

    @Test
    fun `a started shell supplies its PID and focus target`() = runBlocking {
        val api = fakeApi()
        val view = View(CompletableDeferred(Startup(1234)))

        assertEquals(1234L, api.shellProcessID(view))
        assertSame(view.preferredFocusableComponent, api.focusComponent(view))
    }

    @Test
    fun `starting and failed shells are skipped without waiting`() = runBlocking {
        val api = fakeApi()
        assertNull(api.shellProcessID(View(CompletableDeferred())))
        val failed = CompletableDeferred<Startup>()
        failed.completeExceptionally(IllegalStateException("shell failed"))
        assertNull(api.shellProcessID(View(failed)))
        assertNull(api.shellProcessID(View(CompletableDeferred(Startup(null)))))
    }

    private fun fakeApi(): ReworkedTerminalApi = assertNotNull(
        ReworkedTerminalApi.load { name ->
            when (name.substringAfterLast('.')) {
                "TerminalToolWindowTabsManager" -> Manager::class.java
                "TerminalToolWindowTab" -> Tab::class.java
                "TerminalView" -> View::class.java
                "TerminalStartupOptions" -> Startup::class.java
                else -> throw ClassNotFoundException(name)
            }
        }
    )

    class Manager {
        val tabs: List<Tab> = emptyList()
        companion object {
            @JvmStatic
            fun getInstance(@Suppress("UNUSED_PARAMETER") project: Project): Manager = Manager()
        }
    }

    class Tab(val view: View, val content: Content?)
    class View(val startupOptionsDeferred: Deferred<Startup>) {
        val preferredFocusableComponent: JComponent = JPanel()
    }
    class Startup(val pid: Long?)
}
