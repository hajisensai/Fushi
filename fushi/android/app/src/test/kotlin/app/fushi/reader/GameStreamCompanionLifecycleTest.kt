package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Orderings of launches, registrations and closes the companion panel sees on
 * a real device (two external displays, a fast close → auto, a crashed panel,
 * the stream Activity going away).
 */
class GameStreamCompanionLifecycleTest {
    private val finished = mutableListOf<String>()
    private val attached = mutableListOf<Boolean>()
    private val lifecycle = GameStreamCompanionLifecycle(
        object : GameStreamCompanionLifecycle.Effects<String> {
            override fun finish(panel: String) {
                finished += panel
            }

            override fun attachedChanged(attached: Boolean) {
                this@GameStreamCompanionLifecycleTest.attached += attached
            }
        },
    )

    @Test
    fun aLaunchedPanelRegistersAndAttaches() {
        val token = lifecycle.show(2)
        assertTrue(lifecycle.register("A", token))
        assertEquals("A", lifecycle.panel())
        assertEquals(listOf(true), attached)
        assertEquals(GameStreamCompanionLifecycle.NO_TOKEN, lifecycle.show(2), "already there")
    }

    @Test
    fun theOldPanelsLateUnregisterDoesNotCloseItsReplacement() {
        lifecycle.register("A", lifecycle.show(2))
        val second = lifecycle.show(3)
        assertEquals(listOf("A"), finished, "the panel on the old display closes")
        // Old panel's onDestroy arrives before the new panel registers.
        assertFalse(lifecycle.gone("A"))
        assertTrue(lifecycle.register("B", second))
        assertEquals("B", lifecycle.panel())
        assertEquals(listOf("A"), finished, "B is not closed on arrival")
        assertEquals(listOf(true, false, true), attached)
    }

    @Test
    fun aPanelFromAnEarlierLaunchIsClosedWhenItRegisters() {
        val first = lifecycle.show(2)
        val second = lifecycle.show(3)
        assertFalse(lifecycle.register("A", first))
        assertTrue(lifecycle.register("B", second))
        assertEquals(listOf("A"), finished)
        assertEquals("B", lifecycle.panel())
    }

    @Test
    fun dismissWhileStartingClosesThePanelOnArrival() {
        val token = lifecycle.show(2)
        lifecycle.dismiss()
        assertFalse(lifecycle.register("A", token))
        assertEquals(listOf("A"), finished)
        assertTrue(attached.isEmpty())
    }

    @Test
    fun closeThenAutoAgainShowsANewPanel() {
        lifecycle.register("A", lifecycle.show(2))
        lifecycle.dismiss()
        val again = lifecycle.show(2)
        assertTrue(again != GameStreamCompanionLifecycle.NO_TOKEN)
        lifecycle.gone("A") // The dismissed panel's unregister.
        assertTrue(lifecycle.register("A2", again))
        assertEquals(listOf(true, false, true), attached)
    }

    @Test
    fun aCrashedPanelDetachesAndCanBeShownAgain() {
        lifecycle.register("A", lifecycle.show(2))
        assertTrue(lifecycle.gone("A"))
        assertNull(lifecycle.panel())
        assertEquals(listOf(true, false), attached)
        assertTrue(lifecycle.show(2) != GameStreamCompanionLifecycle.NO_TOKEN)
    }

    @Test
    fun aFailedLaunchCanBeRetried() {
        val token = lifecycle.show(2)
        lifecycle.launchFailed(token)
        assertTrue(lifecycle.show(2) != GameStreamCompanionLifecycle.NO_TOKEN)
    }

    @Test
    fun activityTeardownReportsThePanelGone() {
        lifecycle.register("A", lifecycle.show(2))
        lifecycle.dismiss()
        assertEquals(listOf("A"), finished)
        assertEquals(listOf(true, false), attached)
    }
}
