package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import mextensionserver.model.FiltersResponse
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class FilterResponseTest {
    private class Label {
        override fun toString(): String = "すべて"
    }

    @Test
    fun `bare invoker FilterList serializes option labels and typed nested states`() {
        val filters =
            FilterList(
                object : Filter.Select<Label>("並び順", arrayOf(Label())) {},
                object : Filter.Group<Filter<*>>(
                    "絞り込み",
                    listOf(object : Filter.TriState("完結", Filter.TriState.STATE_EXCLUDE) {}),
                ) {},
                object : Filter.Sort("更新", arrayOf("新着"), Filter.Sort.Selection(0, false)) {},
            )
        val mapper = jacksonObjectMapper()
        val json = mapper.readTree(mapper.writeValueAsString(filterResponseForBridge(filters)))
        assertTrue(json.isArray)
        assertEquals("select", json[0]["type"].asText())
        assertEquals("すべて", json[0]["values"][0].asText())
        assertEquals(0, json[0]["state"].asInt())
        assertEquals("group", json[1]["type"].asText())
        assertEquals("triState", json[1]["children"][0]["type"].asText())
        assertEquals(2, json[1]["children"][0]["state"].asInt())
        assertEquals("sort", json[2]["type"].asText())
        assertEquals(false, json[2]["state"]["ascending"].asBoolean())
    }

    @Test
    fun `legacy response keeps its envelope and unrelated results stay unchanged`() {
        val mapper = jacksonObjectMapper()
        val wrapped = FiltersResponse(FilterList(object : Filter.Select<Label>("並び順", arrayOf(Label())) {}))
        val json = mapper.readTree(mapper.writeValueAsString(filterResponseForBridge(wrapped)))
        assertEquals("すべて", json["filterList"][0]["values"][0].asText())
        val unrelated = mapOf("mangas" to emptyList<String>())
        assertSame(unrelated, filterResponseForBridge(unrelated))
    }
}
