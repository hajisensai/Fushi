package app.fushi.reader.mihon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** 反馈 Njruv6JSaL：偏好桥请求的写入拆分（快照 vs 这次改的那一项）。 */
class MihonPreferencePlanTest {
    private fun context(changed: String?): Map<String, Any?> = buildMap {
        put("key", MihonPreferencePlan.CONTEXT_KEY)
        put("sourceId", "42")
        if (changed != null) put("changedPreferenceKey", changed)
    }

    private val provider: Map<String, Any?> = mapOf(
        "key" to "debrid_provider",
        "listPreference" to mapOf(
            "title" to "Debrid Provider",
            "valueIndex" to 2,
            "entries" to listOf("None", "RealDebrid", "TorBox"),
            "entryValues" to listOf("none", "realdebrid", "torbox"),
        ),
    )

    private fun token(value: String): Map<String, Any?> = mapOf(
        "key" to "token",
        "editTextPreference" to mapOf("title" to "Token", "value" to value),
    )

    @Test
    fun setPreferenceSplitsChangedKeyFromSnapshot() {
        val plan = MihonPreferencePlan.of(listOf(context("token"), provider, token("abc")))
        assertEquals(listOf<Pair<String, Any>>("debrid_provider" to "torbox"), plan.snapshot)
        assertEquals("token" to "abc", plan.changed)
    }

    @Test
    fun plainRequestWritesWholeSnapshotAndChangesNothing() {
        val plan = MihonPreferencePlan.of(listOf(context(null), provider, token("abc")))
        assertEquals(
            listOf<Pair<String, Any>>("debrid_provider" to "torbox", "token" to "abc"),
            plan.snapshot,
        )
        assertNull(plan.changed)
    }

    @Test
    fun valuesKeepTheTypesTheSourceReadsBack() {
        assertEquals(true, MihonPreferencePlan.valueOf(mapOf("checkBoxPreference" to mapOf("value" to true))))
        assertEquals(false, MihonPreferencePlan.valueOf(mapOf("switchPreferenceCompat" to mapOf("value" to false))))
        assertEquals("", MihonPreferencePlan.valueOf(token("")))
        assertEquals(
            setOf("a", "b"),
            MihonPreferencePlan.valueOf(mapOf("multiSelectListPreference" to mapOf("values" to listOf("a", "b")))),
        )
        // 越界 / 缺 entryValues 的列表项没有可用值，不写（不猜第 0 项）。
        assertNull(
            MihonPreferencePlan.valueOf(
                mapOf("listPreference" to mapOf("valueIndex" to 5, "entryValues" to listOf("x"))),
            ),
        )
        assertNull(MihonPreferencePlan.valueOf(mapOf("unsupportedPreference" to mapOf("title" to "?"))))
    }
}
