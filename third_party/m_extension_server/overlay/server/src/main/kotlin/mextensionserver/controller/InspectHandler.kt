package mextensionserver.controller

import com.android.apksig.ApkVerifier
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import fi.iki.elonen.NanoHTTPD
import mextensionserver.util.PackageTools
import java.io.File
import java.security.MessageDigest
import java.util.Base64

/**
 * Reads an APK's identity **without ever running a byte of its code.**
 *
 * `/inspect` is what the Hibiki host calls *before* it shows the "third-party
 * extensions execute code with Hibiki permissions" trust dialog, so anything
 * this route executes has already happened by the time the user is asked — a
 * "cancel" would arrive too late. It therefore stays on a strictly declarative
 * path:
 *
 *  - `ApkVerifier` proves the APK is internally consistent and yields the
 *    signer certificate. That is an integrity check, **not** a trust check —
 *    anyone can self-sign — which is why the signer fingerprint is handed back
 *    to the host to be matched against the store key and the trusted-signer
 *    table.
 *  - `PackageTools.getPackageInfo` parses the zip entries and the binary
 *    AndroidManifest with apk-parser plus JAXP. It builds no class loader,
 *    resolves no class and constructs nothing.
 *
 * It deliberately does **not** go through `MExtensionServerLoader`. That path
 * runs `dex2jar`, then `Class.forName` + `newInstance` on the extension main
 * class (static initialiser + constructor) and `SourceFactory.createSources()`
 * — arbitrary code with Hibiki's permissions — and it parks the resulting
 * instance in a cache with no eviction policy, so a rejected extension would
 * keep its objects, and any threads its constructor started, alive for the rest
 * of the sidecar's life. None of that ever bought anything here: every field
 * below comes from `packageInfo`, and `loaded.sources` was never read.
 *
 * Loading is the job of `/dalvik`, which the host only reaches after the user
 * has accepted the trust dialog or has explicitly asked to preview the
 * extension.
 */
class InspectHandler {
    private val mapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        var apk: File? = null
        return try {
            val files = mutableMapOf<String, String>()
            session.parseBody(files)
            val request = mapper.readValue(files["postData"], InspectRequest::class.java)
            val bytes = Base64.getDecoder().decode(request.data)
            val apkFile = kotlin.io.path.createTempFile("hibiki-inspect-", ".apk").toFile()
            apk = apkFile
            apkFile.writeBytes(bytes)
            val verification = ApkVerifier.Builder(apkFile).build().verify()
            if (!verification.isVerified || verification.signerCertificates.isEmpty()) {
                throw IllegalArgumentException("APK signature verification failed")
            }
            val signer = MessageDigest.getInstance("SHA-256")
                .digest(verification.signerCertificates.last().encoded)
                .joinToString("") { byte -> "%02x".format(byte) }
            val result = inspect(apkFile, signer)
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

    /** Metadata-only projection of [apkFile]; executes nothing from the APK. */
    private fun inspect(
        apkFile: File,
        signerSha256: String,
    ): Map<String, Any> {
        val info = PackageTools.getPackageInfo(apkFile.absolutePath)
        val metadata = info.applicationInfo.metaData
        val versionName: String = info.versionName.orEmpty()
        val libVersion: Double? = metadata.getString("tachiyomix.extensionLib")
            ?.toDoubleOrNull()
            ?: versionName.substringBeforeLast('.').toDoubleOrNull()
        if (libVersion != 1.4 && libVersion != 1.6) {
            throw IllegalArgumentException("Unsupported extension-lib version")
        }
        val classes: List<String> = metadata.getString("tachiyomi.extension.class")
            ?.split(";")
            ?.map(String::trim)
            .orEmpty()
        return mapOf(
            "packageName" to info.packageName,
            "name" to (
                metadata.getString("tachiyomix.name")
                    ?: info.applicationInfo.name
                    ?: info.packageName
                ),
            "versionCode" to info.versionCode,
            "versionName" to versionName,
            "libVersion" to if (libVersion == 1.4) "1.4" else "1.6",
            "signerSha256" to signerSha256,
            "sourceClasses" to classes,
        )
    }

    private data class InspectRequest(val data: String)
}
