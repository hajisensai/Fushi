package mextensionserver.impl

import androidx.preference.Preference
import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import mextensionserver.model.JFilterList
import mextensionserver.model.JGroupFilter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MihonInvokerTest {
    @Test
    fun `converts children of grouped anime filters`() {
        val child = TestCheckBox()
        val originalFilters =
            AnimeFilterList(
                TestGroup(listOf(child)),
            )
        val requestedFilters =
            listOf(
                JFilterList(
                    name = "Group",
                    type = null,
                    stateString = null,
                    stateInt = null,
                    stateList =
                        listOf(
                            JGroupFilter(
                                name = "Child",
                                type = null,
                                stateBoolean = true,
                                stateInt = null,
                            ),
                        ),
                    stateSort = null,
                ),
            )

        convertAnimeFilterList(originalFilters, requestedFilters)

        assertTrue(child.state)
    }

    @Test
    fun `keeps normalized value saved by rejecting preference listener`() {
        val preference = TestPreference("https://old.example")
        preference.setOnPreferenceChangeListener { pref, newValue ->
            val normalized = (newValue as String).substringBefore("/path")
            pref.saveNewValue(normalized)
            false
        }

        MihonInvoker.applyPreferenceChange(
            preference,
            "https://new.example/path",
        )

        assertEquals("https://new.example", preference.currentValue)
    }

    @Test
    fun `persists value accepted by preference listener`() {
        val preference = TestPreference("old")
        var valueSeenByListener: Any? = null
        preference.setOnPreferenceChangeListener { pref, _ ->
            valueSeenByListener = pref.currentValue
            true
        }

        MihonInvoker.applyPreferenceChange(preference, "new")

        assertEquals("old", valueSeenByListener)
        assertEquals("new", preference.currentValue)
    }

    private fun convertAnimeFilterList(
        originalFilters: AnimeFilterList,
        requestedFilters: List<JFilterList>,
    ) {
        val method =
            MihonInvoker::class.java.getDeclaredMethod(
                "convertAnimeFilterList",
                AnimeFilterList::class.java,
                List::class.java,
            )
        method.isAccessible = true
        method.invoke(MihonInvoker, originalFilters, requestedFilters)
    }

    private class TestCheckBox : AnimeFilter.CheckBox("Child")

    private class TestGroup(
        children: List<TestCheckBox>,
    ) : AnimeFilter.Group<TestCheckBox>("Group", children)

    private class TestPreference(
        initialValue: Any,
    ) : Preference(null) {
        private var value: Any = initialValue

        override fun getCurrentValue(): Any = value

        override fun saveNewValue(value: Any) {
            this.value = value
        }
    }
}
