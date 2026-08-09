package mihon.core.common.extensions

import kotlinx.serialization.json.JsonObject

private val emptyJsonObject = JsonObject(emptyMap())

val JsonObject.Companion.EMPTY: JsonObject
    get() = emptyJsonObject
