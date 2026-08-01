package mextensionserver.controller

import android.app.Application
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.impl.MihonMetadataCache
import mextensionserver.model.DataBody
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

class SourceDataHandler {
    private val mapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response =
        try {
            val files = mutableMapOf<String, String>()
            session.parseBody(files)
            val request = mapper.readValue(files["postData"], SourceDataRequest::class.java)
            val preferences: MutableList<Map<String, Any>> = mutableListOf(
                mapOf(
                    "key" to "__mangatan_bridge_context__",
                    "sourceId" to request.sourceId,
                ),
            )
            val data = DataBody(
                data = request.data,
                method = "preferencesManga",
                preferences = preferences,
            )
            MExtensionServerLoader.invokeWithExtension(request.data) { loaded ->
                val source = MihonInvoker.selectSource(loaded.sources, data) as Source
                Injekt.get<Application>()
                    .getSharedPreferences("source_${source.id}", 0)
                    .edit()
                    .clear()
                    .commit()
                if (source is HttpSource) {
                    Injekt.get<NetworkHelper>().cookieJar.clear()
                }
                MihonMetadataCache.remove(source)
            }
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/json",
                """{"ok":true}""",
            )
        } catch (error: Throwable) {
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR,
                "application/json",
                mapper.writeValueAsString(mapOf("error" to (error.message ?: "Clear failed"))),
            )
        }

    private data class SourceDataRequest(val data: String, val sourceId: String)
}
