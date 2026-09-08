package app.fushi.reader.mihon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ChallengeProxyLifecycleTest {
    @Test
    fun cancelDuringSetupWaitsForSetupAndCleanupBeforeReplying() {
        var clearCallback: (() -> Unit)? = null
        var replies = 0
        val lifecycle = ChallengeProxyLifecycle { done -> clearCallback = done }
        lifecycle.begin()
        lifecycle.close { replies++ }
        assertNull(clearCallback)
        assertEquals(0, replies)
        lifecycle.installed()
        assertNotNull(clearCallback)
        assertEquals(0, replies)
        clearCallback!!.invoke()
        assertEquals(1, replies)
        lifecycle.close { replies++ }
        clearCallback!!.invoke()
        assertEquals(1, replies)
    }

    @Test
    fun completedSetupAlsoRetainsTheLeaseUntilCleanupFinishes() {
        var clearCallback: (() -> Unit)? = null
        var replies = 0
        val lifecycle = ChallengeProxyLifecycle { done -> clearCallback = done }
        lifecycle.begin()
        lifecycle.installed()
        lifecycle.close { replies++ }
        assertEquals(0, replies)
        clearCallback!!.invoke()
        assertEquals(1, replies)
    }

    @Test
    fun unsupportedBeforeSetupDoesNotWaitForANonexistentMutation() {
        var clears = 0
        var replies = 0
        val lifecycle = ChallengeProxyLifecycle { clears++ }
        lifecycle.close { replies++ }
        assertEquals(0, clears)
        assertEquals(1, replies)
    }
}
