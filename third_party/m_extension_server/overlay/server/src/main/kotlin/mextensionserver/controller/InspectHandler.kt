package mextensionserver.controller

import com.android.apksig.ApkVerifier
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.MExtensionServerLoader
import java.io.File
import java.security.MessageDigest
import java.util.Base64

class InspectHandler {
    private val mapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        var apk: File? = null
        return try {
            val files = mutableMapOf<String, String>()
            session.parseBody(files)
            val request = mapper.readValue(files["postData"], InspectRequest::class.java)
            val bytes = Base64.getDecoder().decode(request.data)
            apk = kotlin.io.path.createTempFile("hibiki-inspect-", ".apk").toFile()
            apk.writeBytes(bytes)
            val verification = ApkVerifier.Builder(apk).build().verify()
            if (!verification.isVerified || verification.signerCertificates.isEmpty()) {
                throw IllegalArgumentException("APK signature verification failed")
            }
            val signer = MessageDigest.getInstance("SHA-256")
                .digest(verification.signerCertificates.last().encoded)
                .joinToString("") { byte -> "%02x".format(byte) }
            val result = MExtensionServerLoader.invokeWithExtension(request.data) { loaded ->
                val info = loaded.packageInfo
                val metadata = info.applicationInfo.metaData
                val versionName = info.versionName.orEmpty()
                val libVersion = metadata.getString("tachiyomix.extensionLib")
                    ?.toDoubleOrNull()
                    ?: versionName.substringBeforeLast('.').toDoubleOrNull()
                if (libVersion != 1.4 && libVersion != 1.6) {
                    throw IllegalArgumentException("Unsupported extension-lib version")
                }
                val classes = metadata.getString("tachiyomi.extension.class")
                    ?.split(";")
                    ?.map(String::trim)
                    .orEmpty()
                mapOf(
                    "packageName" to info.packageName,
                    "name" to (
                        metadata.getString("tachiyomix.name")
                            ?: info.applicationInfo.name
                            ?: info.packageName
                        ),
                    "versionCode" to info.versionCode,
                    "versionName" to versionName,
                    "libVersion" to if (libVersion == 1.4) "1.4" else "1.6",
                    "signerSha256" to signer,
                    "sourceClasses" to classes,
                )
            }
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/json",
                mapper.writeValueAsString(result),
            )
        } catch (error: Throwable) {
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.BAD_REQUEST,
                "application/json",
                mapper.writeValueAsString(mapOf("error" to (error.message ?: "Invalid APK"))),
            )
        } finally {
            apk?.delete()
        }
    }

    private data class InspectRequest(val data: String)
}
