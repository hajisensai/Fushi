package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Orderings of launches, registrations, closes and host start / stop the
 * second-screen panel sees on a real device (two external displays, a fast
 * close → auto, a crashed panel, the game stream taking over the companion,
 * the host Activity going to the background or away).
 */
class SecondScreenLifecycleTest {
    private val finished = mutableListOf<String>()
    private val attached = mutableListOf<Boolean>()

    /** Launches as "display:mode#token". */
    private val launches = mutableListOf<String>()
    private var launchWorks = true
    private var lastToken = SecondScreenLifecycle.NO_TOKEN

    private val lifecycle = SecondScreenLifecycle(
        object : SecondScreenLifecycle.Effects<String> {
            override fun launch(display: Int, mode: String, token: Int): Boolean {
                launches += "$display:$mode#$token"
                lastToken = token
                return launchWorks
            }

            override fun finish(panel: String) {
                finished += panel
            }

            override fun attachedChanged(attached: Boolean) {
                this@SecondScreenLifecycleTest.attached += attached
            }
        },
        true,
    )

    /** Shows on [display] in [mode] and returns the token it launched with. */
    private fun show(display: Int, mode: String = COMPANION): Int {
        assertTrue(lifecycle.show(display, mode))
        return lastToken
    }

    @Test
    fun aLaunchedPanelRegistersAndAttaches() {
        val token = show(2)
        assertTrue(lifecycle.register("A", token))
        assertEquals("A", lifecycle.panel())
        assertEquals(listOf(true), attached)
        assertTrue(lifecycle.show(2, COMPANION))
        assertEquals(1, launches.size, "already there: no second launch")
    }

    @Test
    fun theOldPanelsLateUnregisterDoesNotCloseItsReplacement() {
        lifecycle.register("A", show(2))
        val second = show(3)
        assertEquals(listOf("A"), finished, "the panel on the old display closes")
        // Old panel's onDestroy arrives before the new panel registers.
        assertFalse(lifecycle.gone("A"))
        assertTrue(lifecycle.register("B", second))
        assertEquals("B", lifecycle.panel())
        assertEquals(listOf("A"), finished, "B is not closed on arrival")
        assertEquals(listOf(true, false, true), attached)
    }

    @Test
    fun anotherModeOnTheSameDisplayReplacesThePanel() {
        lifecycle.register("companion", show(2, COMPANION))
        val stream = show(2, GAME_STREAM)
        assertEquals(listOf("companion"), finished)
        assertEquals(GAME_STREAM, lifecycle.mode())
        assertTrue(lifecycle.register("stream", stream))
        assertEquals(listOf("2:companion#1", "2:gameStream#2"), launches)
        assertEquals(listOf(true, false, true), attached)
    }

    @Test
    fun aPanelFromAnEarlierLaunchIsClosedWhenItRegisters() {
        val first = show(2)
        val second = show(3)
        assertFalse(lifecycle.register("A", first))
        assertTrue(lifecycle.register("B", second))
        assertEquals(listOf("A"), finished)
        assertEquals("B", lifecycle.panel())
    }

    @Test
    fun dismissWhileStartingClosesThePanelOnArrival() {
        val token = show(2)
        lifecycle.dismiss()
        assertFalse(lifecycle.register("A", token))
        assertEquals(listOf("A"), finished)
        assertTrue(attached.isEmpty())
    }

    @Test
    fun closeThenShowAgainLaunchesANewPanel() {
        lifecycle.register("A", show(2))
        lifecycle.dismiss()
        val again = show(2)
        assertEquals(2, launches.size)
        lifecycle.gone("A") // The dismissed panel's unregister.
        assertTrue(lifecycle.register("A2", again))
        assertEquals(listOf(true, false, true), attached)
    }

    @Test
    fun aCrashedPanelDetachesAndCanBeShownAgain() {
        lifecycle.register("A", show(2))
        assertTrue(lifecycle.gone("A"))
        assertNull(lifecycle.panel())
        assertNull(lifecycle.mode(), "nothing wanted until the app asks again")
        assertEquals(listOf(true, false), attached)
        show(2)
        assertEquals(2, launches.size)
    }

    @Test
    fun aFailedLaunchWantsNothingAndCanBeRetried() {
        launchWorks = false
        assertFalse(lifecycle.show(2, COMPANION))
        assertNull(lifecycle.mode())
        launchWorks = true
        assertTrue(lifecycle.show(2, COMPANION))
        assertEquals(2, launches.size)
    }

    @Test
    fun activityTeardownReportsThePanelGone() {
        lifecycle.register("A", show(2))
        lifecycle.dismiss()
        assertEquals(listOf("A"), finished)
        assertEquals(listOf(true, false), attached)
    }

    @Test
    fun hostStopClosesThePanelAndHostStartBringsItBack() {
        lifecycle.register("A", show(2, GAME_STREAM))
        lifecycle.hostStopped()
        assertEquals(listOf("A"), finished)
        assertEquals(listOf(true, false), attached)
        assertEquals(GAME_STREAM, lifecycle.mode(), "still wanted")
        // A client re-placing while stopped launches nothing.
        assertTrue(lifecycle.show(2, GAME_STREAM))
        assertEquals(1, launches.size)
        lifecycle.hostStarted()
        assertEquals(listOf("2:gameStream#1", "2:gameStream#2"), launches)
        assertTrue(lifecycle.register("A2", lastToken))
        assertEquals(listOf(true, false, true), attached)
    }

    @Test
    fun aPanelStillStartingWhenTheHostStopsIsClosedOnArrival() {
        val token = show(2)
        lifecycle.hostStopped()
        assertFalse(lifecycle.register("A", token))
        assertEquals(listOf("A"), finished)
        lifecycle.hostStarted()
        assertTrue(lifecycle.register("A2", lastToken))
    }

    @Test
    fun showWhileTheHostIsStoppedWaitsForStart() {
        lifecycle.hostStopped()
        assertTrue(lifecycle.show(2, COMPANION))
        assertTrue(launches.isEmpty())
        lifecycle.hostStarted()
        assertEquals(listOf("2:companion#1"), launches)
    }

    @Test
    fun aRelaunchOnStartThatFailsWantsNothing() {
        lifecycle.register("A", show(2))
        lifecycle.hostStopped()
        launchWorks = false
        lifecycle.hostStarted()
        assertNull(lifecycle.mode())
        assertEquals(listOf(true, false), attached)
    }

    @Test
    fun dismissedWhileStoppedStaysClosedOnStart() {
        lifecycle.register("A", show(2))
        lifecycle.hostStopped()
        lifecycle.dismiss()
        lifecycle.hostStarted()
        assertEquals(1, launches.size)
    }

    @Test
    fun removingTheWantedDisplayClosesThePanel() {
        lifecycle.register("A", show(2))
        lifecycle.displayRemoved(3)
        assertEquals("A", lifecycle.panel(), "another display went away")
        lifecycle.displayRemoved(2)
        assertNull(lifecycle.panel())
        assertNull(lifecycle.mode())
        assertEquals(listOf("A"), finished)
        assertEquals(listOf(true, false), attached)
    }

    private companion object {
        const val COMPANION = "companion"
        const val GAME_STREAM = "gameStream"
    }
}
