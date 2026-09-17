package app.fushi.reader

import android.view.MotionEvent
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pure-logic contract of the trigger → L2 / R2 bridge: which motion axis carries
 * a trigger on a given controller layout, and the press / release hysteresis.
 * The Android-typed shell ([GamepadTriggerKeySynthesizer.onGenericMotionEvent])
 * only samples depths and hands them to [GamepadTriggerKeySynthesizer.DeviceTriggers.step].
 */
class GamepadTriggerKeySynthesizerTest {
    /** A controller exposing exactly [axes], with the given range minimum per axis. */
    private fun layout(vararg axes: Pair<Int, Float>): GamepadTriggerKeySynthesizer.AxisRanges {
        val ranges = axes.toMap()
        return object : GamepadTriggerKeySynthesizer.AxisRanges {
            override fun hasAxis(axis: Int): Boolean = ranges.containsKey(axis)
            override fun minOf(axis: Int): Float = ranges.getValue(axis)
        }
    }

    private val left = GamepadTriggerKeySynthesizer.SIDE_LEFT
    private val right = GamepadTriggerKeySynthesizer.SIDE_RIGHT

    @Test
    fun xboxLayoutsUseTheTriggerAxes() {
        // Every Xbox layout shipped in AOSP (02fd / 02e0 / 0b12 / 028e / 02ea) maps
        // the triggers to LTRIGGER / RTRIGGER and the right stick to Z / RZ.
        val xbox = layout(
            MotionEvent.AXIS_LTRIGGER to 0f,
            MotionEvent.AXIS_RTRIGGER to 0f,
            MotionEvent.AXIS_Z to -1f,
            MotionEvent.AXIS_RZ to -1f,
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_LTRIGGER),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(xbox, left),
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_RTRIGGER),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(xbox, right),
        )
    }

    @Test
    fun brakeGasAliasIsSampledToo() {
        // Android's input docs: read LTRIGGER *or* BRAKE, RTRIGGER *or* GAS. A
        // layout exposing both gets both sampled (deepest pull wins downstream).
        val both = layout(
            MotionEvent.AXIS_LTRIGGER to 0f,
            MotionEvent.AXIS_BRAKE to 0f,
            MotionEvent.AXIS_GAS to 0f,
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_BRAKE),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(both, left),
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_GAS),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(both, right),
        )
    }

    @Test
    fun unipolarZIsATriggerButCentredZIsTheRightStick() {
        // Wired Xbox pad without its vendor layout: kernel ABS_Z / ABS_RZ come
        // through Generic.kl as AXIS_Z / AXIS_RZ with a 0..1 range.
        val genericWired = layout(
            MotionEvent.AXIS_Z to 0f,
            MotionEvent.AXIS_RZ to 0f,
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_Z),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(genericWired, left),
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_RZ),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(genericWired, right),
        )
        // A centred Z / RZ (-1..1) is the right stick under Android's standard
        // mapping — never read it as a trigger, or pushing the stick right would
        // "press" RT.
        val rightStickOnZ = layout(
            MotionEvent.AXIS_Z to -1f,
            MotionEvent.AXIS_RZ to -1f,
        )
        assertContentEquals(
            intArrayOf(),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(rightStickOnZ, left),
        )
        assertContentEquals(
            intArrayOf(),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(rightStickOnZ, right),
        )
    }

    @Test
    fun legacyZIsIgnoredWhenARealTriggerAxisExists() {
        val mixed = layout(
            MotionEvent.AXIS_LTRIGGER to 0f,
            MotionEvent.AXIS_Z to 0f,
        )
        assertContentEquals(
            intArrayOf(MotionEvent.AXIS_LTRIGGER),
            GamepadTriggerKeySynthesizer.resolveTriggerAxes(mixed, left),
        )
    }

    @Test
    fun edgeHasHysteresis() {
        val press = GamepadTriggerKeySynthesizer.PRESS_DEPTH
        val release = GamepadTriggerKeySynthesizer.RELEASE_DEPTH
        assertTrue(release < press, "release point must sit below the press point")
        // Not pressed: only crossing the press point is an edge.
        assertEquals(0, GamepadTriggerKeySynthesizer.edge(false, 0f))
        assertEquals(0, GamepadTriggerKeySynthesizer.edge(false, press - 0.01f))
        assertEquals(1, GamepadTriggerKeySynthesizer.edge(false, press))
        assertEquals(1, GamepadTriggerKeySynthesizer.edge(false, 1f))
        // Pressed: hovering between the two points is NOT a release.
        assertEquals(0, GamepadTriggerKeySynthesizer.edge(true, press - 0.01f))
        assertEquals(0, GamepadTriggerKeySynthesizer.edge(true, release + 0.01f))
        assertEquals(-1, GamepadTriggerKeySynthesizer.edge(true, release))
        assertEquals(-1, GamepadTriggerKeySynthesizer.edge(true, 0f))
    }

    @Test
    fun pullHoldReleaseEmitsExactlyOneDownAndOneUpPerSide() {
        val triggers = GamepadTriggerKeySynthesizer.DeviceTriggers(
            layout(MotionEvent.AXIS_LTRIGGER to 0f, MotionEvent.AXIS_RTRIGGER to 0f),
        )
        val nan = Float.NaN
        // Ramp LT up: nothing until the press point, one DOWN, then silence while held.
        assertContentEquals(intArrayOf(0, 0), triggers.step(floatArrayOf(0.1f, 0f), 10L))
        assertContentEquals(intArrayOf(0, 0), triggers.step(floatArrayOf(0.4f, 0f), 11L))
        assertContentEquals(intArrayOf(1, 0), triggers.step(floatArrayOf(0.6f, 0f), 12L))
        assertEquals(12L, triggers.downTime[left])
        assertContentEquals(intArrayOf(0, 0), triggers.step(floatArrayOf(1.0f, 0f), 13L))
        assertContentEquals(intArrayOf(0, 0), triggers.step(floatArrayOf(0.7f, 0f), 14L))
        // Dip into the hysteresis band: still held.
        assertContentEquals(intArrayOf(0, 0), triggers.step(floatArrayOf(0.35f, 0f), 15L))
        assertTrue(triggers.pressed[left])
        // Below the release point: one UP.
        assertContentEquals(intArrayOf(-1, 0), triggers.step(floatArrayOf(0.1f, 0f), 16L))
        assertFalse(triggers.pressed[left])
        // Both sides are independent; RT pressed in the same frame LT is idle.
        assertContentEquals(intArrayOf(0, 1), triggers.step(floatArrayOf(0f, 0.9f), 17L))
        assertContentEquals(intArrayOf(0, -1), triggers.step(floatArrayOf(0f, 0f), 18L))
        // A side without a trigger axis (NaN depth) never changes state.
        assertContentEquals(intArrayOf(0, 0), triggers.step(floatArrayOf(nan, nan), 19L))
    }

    @Test
    fun sideWithoutAnyTriggerAxisStaysSilent() {
        val leftOnly = GamepadTriggerKeySynthesizer.DeviceTriggers(
            layout(MotionEvent.AXIS_LTRIGGER to 0f),
        )
        assertContentEquals(intArrayOf(), leftOnly.axes[right])
        assertContentEquals(intArrayOf(1, 0), leftOnly.step(floatArrayOf(1f, Float.NaN), 1L))
        assertFalse(leftOnly.pressed[right])
    }
}
