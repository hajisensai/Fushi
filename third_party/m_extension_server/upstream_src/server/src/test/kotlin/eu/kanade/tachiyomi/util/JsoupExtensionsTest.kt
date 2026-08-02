package eu.kanade.tachiyomi.util

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.nio.charset.Charset
import kotlin.test.Test
import kotlin.test.assertEquals

class JsoupExtensionsTest {
    @Test
    fun `decodes legacy EUC-KR HTML using the declared response charset`() {
        val html = "<html><body><p class=\"title\">한국어 제목</p></body></html>"
        val response =
            Response
                .Builder()
                .request(Request.Builder().url("https://example.test").build())
                .protocol(okhttp3.Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(
                    html
                        .toByteArray(Charset.forName("EUC-KR"))
                        .toResponseBody("text/html; charset=EUC-KR".toMediaType()),
                ).build()

        response.use {
            assertEquals("한국어 제목", response.asJsoup().selectFirst(".title")?.text())
        }
    }
}
