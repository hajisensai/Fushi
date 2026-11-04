package app.fushi.reader.widgets

import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame

/**
 * The time-dependent parts of the shared widget snapshot (`srs.timeline`, `rollover`) are resolved
 * natively at render time without recomputing anything: these pin the selection rules (same as the
 * Apple widgets' `resolved(at:)`).
 */
class WidgetSnapshotTimeTest {
    private val snapshot = JSONObject(
        """
        {
          "day": "2026-10-23",
          "today": {"time": "40m", "streak": 3},
          "streak": {"current": 3},
          "srs": {"due": 5, "timeline": [
            {"at": 1000, "due": 5}, {"at": 2000, "due": 7}, {"at": 3000, "due": 12}
          ]},
          "rollover": {
            "at": 5000, "day": "2026-10-24",
            "today": {"time": "0m", "streak": 3}, "streak": {"current": 3},
            "heatmap": {"levels": [0]}
          }
        }
        """.trimIndent(),
    )

    @Test
    fun dueFollowsTheTimelineStepAtRenderTime() {
        val srs = snapshot.getJSONObject("srs")
        assertEquals(5, WidgetStore.srsDueAt(srs, 999))
        assertEquals(5, WidgetStore.srsDueAt(srs, 1500))
        assertEquals(7, WidgetStore.srsDueAt(srs, 2000))
        assertEquals(12, WidgetStore.srsDueAt(srs, 99_999))
    }

    @Test
    fun noTimelineFallsBackToDue() {
        assertEquals(4, WidgetStore.srsDueAt(JSONObject("""{"due": 4}"""), 10))
        assertEquals(0, WidgetStore.srsDueAt(null, 10))
    }

    @Test
    fun rolloverIsAppliedOnlyAfterItsBoundary() {
        assertSame(snapshot, WidgetStore.resolveRollover(snapshot, 4999))
        val next = WidgetStore.resolveRollover(snapshot, 5000)
        assertEquals("2026-10-24", next.getString("day"))
        assertEquals("0m", next.getJSONObject("today").getString("time"))
        assertFalse(next.has("rollover"))
        // The source snapshot is left untouched (it is re-read on every render).
        assertEquals("2026-10-23", snapshot.getString("day"))
    }
}
