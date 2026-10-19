package mextensionserver.impl

import android.content.SharedPreferences
import xyz.nulldev.androidcompat.io.sharedprefs.JavaSharedPreferences
import xyz.nulldev.ts.config.CONFIG_PREFIX
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.deleteRecursively
import kotlin.io.path.exists
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HostPreferenceSnapshotTest {
    private lateinit var root: Path
    private var previousRoot: String? = null

    @BeforeTest
    fun isolateRoot() {
        root = Files.createTempDirectory("host-preference-snapshot")
        previousRoot = System.getProperty(ROOT_PROPERTY)
        System.setProperty(ROOT_PROPERTY, root.toString())
    }

    @OptIn(kotlin.io.path.ExperimentalPathApi::class)
    @AfterTest
    fun restoreRoot() {
        previousRoot?.let { System.setProperty(ROOT_PROPERTY, it) } ?: System.clearProperty(ROOT_PROPERTY)
        root.deleteRecursively()
    }

    @Test
    fun `fresh store receives every snapshot value`() {
        apply(
            edit("Address", "http://127.0.0.1:25600"),
            check("Show read", true),
            list("Sort", valueIndex = 1, entryValues = listOf("a", "b")),
            multi("Libraries", listOf("2", "1")),
        )
        val store = store()
        assertEquals("http://127.0.0.1:25600", store.getString("Address", null))
        assertTrue(store.getBoolean("Show read", false))
        assertEquals("b", store.getString("Sort", null))
        assertEquals(setOf("1", "2"), store.getStringSet("Libraries", null))
        assertTrue(root.resolve("settings").resolve("source_$SOURCE_ID.xml").exists())
    }

    @Test
    fun `snapshot overrides a value the store held before the host knew it`() {
        // A store shared with another data root (or left from an older Fushi)
        // already carries the key. Upstream skipped every existing key, so the
        // database could never reach it.
        store().edit().putString("Address", "http://stale.example").commit()

        apply(edit("Address", "http://127.0.0.1:25600"))

        assertEquals("http://127.0.0.1:25600", store().getString("Address", null))
    }

    @Test
    fun `source write survives the same snapshot arriving again`() {
        apply(edit("Address", "http://127.0.0.1:25600"))
        // The extension normalises / refreshes the value itself.
        store().edit().putString("Address", "http://127.0.0.1:25600/").commit()

        apply(edit("Address", "http://127.0.0.1:25600"))

        assertEquals("http://127.0.0.1:25600/", store().getString("Address", null))
    }

    @Test
    fun `changed database value overrides the source write`() {
        apply(multi("Libraries", listOf("1")))
        store().edit().putStringSet("Libraries", mutableSetOf("1", "9")).commit()

        apply(multi("Libraries", listOf("1")))
        assertEquals(setOf("1", "9"), store().getStringSet("Libraries", null))

        apply(multi("Libraries", listOf("2")))
        assertEquals(setOf("2"), store().getStringSet("Libraries", null))
    }

    @Test
    fun `ledger never stores the value in plaintext`() {
        apply(
            edit("Password", "hunter2-secret"),
            multi("Tokens", listOf("tok-secret-a")),
        )
        val ledger = ledger()
        val recorded = ledger.all.values.map { it.toString() }
        assertEquals(2, recorded.size)
        recorded.forEach { entry ->
            assertFalse(entry.contains("hunter2-secret"), entry)
            assertFalse(entry.contains("tok-secret-a"), entry)
            assertTrue(entry.matches(Regex("sha256:[0-9a-f]{64}")), entry)
        }
        assertEquals(HostPreferenceSnapshot.fingerprint("hunter2-secret"), ledger.getString("Password", null))
        // Equality is all the comparison needs: distinct types / values stay distinct.
        assertFalse(HostPreferenceSnapshot.fingerprint("true") == HostPreferenceSnapshot.fingerprint(true))
        assertFalse(HostPreferenceSnapshot.fingerprint("a") == HostPreferenceSnapshot.fingerprint("b"))
    }

    @Test
    fun `plaintext ledger entry from before digests upgrades without overriding a source write`() {
        // Ledger written by the previous build (plaintext record) plus a value
        // the extension normalised itself afterwards.
        store().edit().putString("Password", "pw-normalised").commit()
        ledger().edit().putString("Password", "s:pw").commit()

        apply(edit("Password", "pw"))

        assertEquals("pw-normalised", store().getString("Password", null))
        assertEquals(HostPreferenceSnapshot.fingerprint("pw"), ledger().getString("Password", null))
    }

    @Test
    fun `entries without a usable value are ignored`() {
        assertNull(HostPreferenceSnapshot.valueOf(mapOf("key" to "x")))
        assertNull(HostPreferenceSnapshot.valueOf(list("Sort", valueIndex = 5, entryValues = listOf("a"))))
        apply(mapOf("key" to "x"), list("Sort", valueIndex = 5, entryValues = listOf("a")))
        assertFalse(store().contains("x"))
        assertFalse(store().contains("Sort"))
    }

    private fun store(): SharedPreferences = JavaSharedPreferences("source_$SOURCE_ID")

    private fun ledger(): SharedPreferences = JavaSharedPreferences(HostPreferenceSnapshot.ledgerName(SOURCE_ID))

    private fun apply(vararg entries: Map<String, Any?>) {
        val snapshot =
            HostPreferenceSnapshot(
                preferences = store(),
                ledger = ledger(),
            )
        entries.forEach { entry ->
            val value = HostPreferenceSnapshot.valueOf(entry) ?: return@forEach
            snapshot.offer(entry["key"] as String, value)
        }
        snapshot.commit()
    }

    private fun edit(
        key: String,
        value: String,
    ) = mapOf("key" to key, "editTextPreference" to mapOf("value" to value))

    private fun check(
        key: String,
        value: Boolean,
    ) = mapOf("key" to key, "checkBoxPreference" to mapOf("value" to value))

    private fun list(
        key: String,
        valueIndex: Int,
        entryValues: List<String>,
    ) = mapOf("key" to key, "listPreference" to mapOf("valueIndex" to valueIndex, "entryValues" to entryValues))

    private fun multi(
        key: String,
        values: List<String>,
    ) = mapOf("key" to key, "multiSelectListPreference" to mapOf("values" to values))

    private companion object {
        const val SOURCE_ID = 4242L
        const val ROOT_PROPERTY = "$CONFIG_PREFIX.server.rootDir"
    }
}
