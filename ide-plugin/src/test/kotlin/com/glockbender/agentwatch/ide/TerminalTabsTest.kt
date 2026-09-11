package com.glockbender.agentwatch.ide

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The join between a session and a tab, tested against real processes.
 *
 * The shape under test is the one that happens in a terminal tab: the tab knows the shell it
 * started, and the agent is somewhere below it — usually a child, sometimes a grandchild
 * because a shell wrapped it. Nothing here mocks a process tree; the assertions are about
 * processes this test starts itself.
 */
class TerminalTabsTest {
    @Test
    fun `a direct child is a descendant`() {
        val child = ProcessBuilder("/bin/sleep", "30").start()
        try {
            assertTrue(isDescendant(child.pid(), ProcessHandle.current().pid()))
        } finally {
            child.destroyForcibly().waitFor()
        }
    }

    /// The shape a terminal tab actually has: the tab's shell, then whatever the shell ran.
    @Test
    fun `a grandchild is a descendant, which is the shape a shell makes`() {
        val shell = ProcessBuilder("/bin/sh", "-c", "sleep 30 & wait").start()
        try {
            val grandchild = waitForChild(shell.toHandle())
            assertTrue(isDescendant(grandchild.pid(), shell.pid()))
        } finally {
            shell.descendants().forEach { it.destroyForcibly() }
            shell.destroyForcibly().waitFor()
        }
    }

    @Test
    fun `the walk goes up and not down`() {
        val child = ProcessBuilder("/bin/sleep", "30").start()
        try {
            assertFalse(isDescendant(ProcessHandle.current().pid(), child.pid()))
        } finally {
            child.destroyForcibly().waitFor()
        }
    }

    @Test
    fun `a process is its own tab's, so that a shell without a wrapper still matches`() {
        val self = ProcessHandle.current().pid()
        assertTrue(isDescendant(self, self))
    }

    @Test
    fun `a process number nobody holds matches nothing`() {
        // Above the system maximum, so it cannot be in use.
        assertFalse(isDescendant(processID = 9_999_999, shellProcessID = ProcessHandle.current().pid()))
    }

    @Test
    fun `the walk gives up rather than climbing forever`() {
        val child = ProcessBuilder("/bin/sleep", "30").start()
        try {
            assertFalse(isDescendant(child.pid(), shellProcessID = 1, maximumDepth = 1))
        } finally {
            child.destroyForcibly().waitFor()
        }
    }

    private fun waitForChild(handle: ProcessHandle): ProcessHandle {
        repeat(100) {
            handle.children().findFirst().orElse(null)?.let { return it }
            Thread.sleep(20)
        }
        error("the shell started no child")
    }
}
