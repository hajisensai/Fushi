package mextensionserver.impl

import android.content.SharedPreferences
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest

/**
 * Writes the host's preference snapshot into a source's SharedPreferences.
 *
 * Fushi keeps every source preference in its own database (Drift
 * `manga_source_preferences`) and sends that snapshot with each bridge request;
 * the database is the host's source of truth, the JVM store is a cache that
 * the extension reads and may also write itself (normalising a value in a
 * change listener, refreshing a token, migrating a key).
 *
 * Upstream skipped every key the JVM store already contained, so once a value
 * was on disk no later snapshot could reach it: a restored backup, a different
 * data root that used to share the store, or any value the store held before
 * the host knew about it won permanently over the database.
 *
 * The rule here: a snapshot value is written whenever it differs from the
 * snapshot value last written for that key, recorded in a separate ledger
 * store. A database change therefore always reaches the extension, while a
 * value the extension wrote itself after the last database change survives
 * until the database changes again -- the same snapshot arriving with every
 * request must not undo it.
 *
 * The ledger records a SHA-256 digest of the typed value, never the value
 * itself: an editText preference is often a password or token, and the ledger
 * must not become a second plaintext copy of it. Comparison only needs
 * equality, which the digest preserves.
 */
internal class HostPreferenceSnapshot(
    private val preferences: SharedPreferences,
    private val ledger: SharedPreferences,
) {
    private val preferenceEditor = preferences.edit()
    private val ledgerEditor = ledger.edit()

    fun offer(
        key: String,
        value: Any,
    ) {
        val canonical = canonicalForm(value) ?: return
        val fingerprint = digest(canonical)
        val recorded = ledger.getString(key, null)
        if (recorded == fingerprint) return
        if (recorded == canonical) {
            // Ledger entry written before digests: same value, so nothing to
            // write to the store -- only replace the plaintext record.
            ledgerEditor.putString(key, fingerprint)
            return
        }
        when (value) {
            is Boolean -> preferenceEditor.putBoolean(key, value)
            is String -> preferenceEditor.putString(key, value)
            is Set<*> -> preferenceEditor.putStringSet(key, value.filterIsInstance<String>().toMutableSet())
        }
        ledgerEditor.putString(key, fingerprint)
    }

    /** Store first, ledger second: an interrupted write only causes a redundant rewrite next time. */
    fun commit() {
        preferenceEditor.commit()
        ledgerEditor.commit()
    }

    companion object {
        /** The ledger lives next to the source store and must be cleared with it. */
        fun ledgerName(sourceId: Long): String = "source_${sourceId}_fushi_host_snapshot"

        /**
         * The value one bridge preference entry carries, typed the way the
         * source reads it back; null when the entry has no usable value.
         */
        @Suppress("UNCHECKED_CAST")
        fun valueOf(preference: Map<String, Any?>): Any? =
            when {
                preference.containsKey("checkBoxPreference") ->
                    (preference["checkBoxPreference"] as? Map<*, *>)?.get("value") as? Boolean
                preference.containsKey("switchPreferenceCompat") ->
                    (preference["switchPreferenceCompat"] as? Map<*, *>)?.get("value") as? Boolean
                preference.containsKey("editTextPreference") ->
                    (preference["editTextPreference"] as? Map<*, *>)?.get("value") as? String
                preference.containsKey("listPreference") -> {
                    val list = preference["listPreference"] as? Map<*, *>
                    val valueIndex = (list?.get("valueIndex") as? Number)?.toInt()
                    val entryValues = list?.get("entryValues") as? List<String>
                    if (valueIndex != null && entryValues != null && valueIndex in entryValues.indices) {
                        entryValues[valueIndex]
                    } else {
                        null
                    }
                }
                preference.containsKey("multiSelectListPreference") ->
                    ((preference["multiSelectListPreference"] as? Map<*, *>)?.get("values") as? List<*>)
                        ?.filterIsInstance<String>()
                        ?.toSet()
                else -> null
            }

        /** What the ledger records for [value]: a digest, never the value itself. */
        internal fun fingerprint(value: Any): String? = canonicalForm(value)?.let(::digest)

        /**
         * Type-tagged canonical form of a snapshot value (also the pre-digest
         * ledger format, recognised once so old ledgers upgrade in place).
         */
        private fun canonicalForm(value: Any): String? =
            when (value) {
                is Boolean -> "b:$value"
                is String -> "s:$value"
                is Set<*> -> "m:" + JsonArray(value.filterIsInstance<String>().sorted().map(::JsonPrimitive))
                else -> null
            }

        private fun digest(canonical: String): String =
            "sha256:" +
                MessageDigest
                    .getInstance("SHA-256")
                    .digest(canonical.toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it) }
    }
}
