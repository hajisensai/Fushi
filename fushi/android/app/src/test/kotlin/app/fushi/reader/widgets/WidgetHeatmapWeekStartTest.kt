package app.fushi.reader.widgets

import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The month heatmap rows are weeks that start on the user's week start (`stats_week_start`,
 * snapshot `month.weekStart`); today's column follows from `firstWeekday` + the 35 cells.
 */
class WidgetHeatmapWeekStartTest {
    private fun month(firstWeekday: Int?, weekStart: Int?): JSONObject {
        val o = JSONObject()
        o.put("minutes", org.json.JSONArray(List(35) { 0 }))
        if (firstWeekday != null) o.put("firstWeekday", firstWeekday)
        if (weekStart != null) o.put("weekStart", weekStart)
        return o
    }

    @Test
    fun todayColumnFollowsTheWeekStart() {
        // 35 cells from a Saturday (6): today = Friday (5).
        assertEquals(4, WidgetStore.heatmapTodayColumn(month(6, 1))) // Monday weeks: Fri = 5th
        assertEquals(5, WidgetStore.heatmapTodayColumn(month(6, 7))) // Sunday weeks: Fri = 6th
        assertEquals(6, WidgetStore.heatmapTodayColumn(month(6, 6))) // Saturday weeks: Fri = last
        // No weekStart (older snapshot) = Monday.
        assertEquals(4, WidgetStore.heatmapTodayColumn(month(6, null)))
    }

    @Test
    fun snapshotsWithoutFirstWeekdayKeepTheOldGrid() {
        assertEquals(6, WidgetStore.heatmapTodayColumn(month(null, null)))
        assertEquals(6, WidgetStore.heatmapTodayColumn(null))
    }
}
