package app.fushi.reader.mihon

/**
 * 一次偏好桥请求要做的写入，按落地顺序拆好（纯 Kotlin，不碰 androidx，JVM 单测可测）。
 *
 * Fushi 把每个源的偏好存在自己的库里（Drift `manga_source_preferences`），每次请求都带上整份快照；
 * `setPreference*` 另在上下文条目里点名这次改的那一项（`changedPreferenceKey`）。
 *
 * - [snapshot]：快照里除「这次改的那一项」以外的值，必须在 `setupPreferenceScreen` **之前**写进源的
 *   SharedPreferences——偏好对象在挂进 screen 时读一次持久值，之后写进 store 的值它看不见，序列化
 *   出去就是旧值（反馈 Njruv6JSaL：Token 存进去了，回传的却是空串，Dart 再把空串写回库）。
 * - [changed]：这次改的那一项，交给偏好对象本身（change listener + 保存方法），与桌面 sidecar
 *   `MihonInvoker.applyPreferenceChange` 同一语义。
 */
internal data class MihonPreferencePlan(
    val snapshot: List<Pair<String, Any>>,
    val changed: Pair<String, Any>?,
) {
    companion object {
        const val CONTEXT_KEY = "__mangatan_bridge_context__"

        fun of(values: List<Map<String, Any?>>): MihonPreferencePlan {
            val context = values.firstOrNull { item -> item["key"] == CONTEXT_KEY }
            val changedKey = context?.get("changedPreferenceKey")?.toString()
            val snapshot = mutableListOf<Pair<String, Any>>()
            var changed: Pair<String, Any>? = null
            for (item in values) {
                val key = item["key"]?.toString().orEmpty()
                if (key.isEmpty() || key == CONTEXT_KEY) continue
                val value = valueOf(item) ?: continue
                if (key == changedKey) changed = key to value else snapshot += key to value
            }
            return MihonPreferencePlan(snapshot, changed)
        }

        /**
         * 一条桥条目携带的值，按源读回时的类型：列表项是 `entryValues[valueIndex]`（条目自带
         * entryValues，不必先建 screen）。取不到可用值时为 null。
         */
        fun valueOf(item: Map<String, Any?>): Any? {
            (item["checkBoxPreference"] as? Map<*, *>)?.let { return it["value"] as? Boolean }
            (item["switchPreferenceCompat"] as? Map<*, *>)?.let { return it["value"] as? Boolean }
            (item["editTextPreference"] as? Map<*, *>)?.let { return it["value"]?.toString() }
            (item["listPreference"] as? Map<*, *>)?.let { list ->
                val index = (list["valueIndex"] as? Number)?.toInt() ?: return null
                val entryValues = list["entryValues"] as? List<*> ?: return null
                return entryValues.getOrNull(index)?.toString()
            }
            (item["multiSelectListPreference"] as? Map<*, *>)?.let { multi ->
                return (multi["values"] as? List<*>)?.map { entry -> entry.toString() }?.toSet()
            }
            return null
        }
    }
}
