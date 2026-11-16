package app.fushi.reader

import app.fushi.reader.OpenWithUriPolicy.ProviderFacts
import app.fushi.reader.OpenWithUriPolicy.Verdict
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** BUG-4752：「用其他应用打开 / 分享」不能替发起方读它无权读的 content:// URI。 */
class OpenWithUriPolicyTest {
    private val own = "app.fushi.reader"
    private val ankiPerm = "com.ichi2.anki.permission.READ_WRITE_DATABASE"
    private val storagePerm = "android.permission.READ_EXTERNAL_STORAGE"
    private val manageDocuments = "android.permission.MANAGE_DOCUMENTS"

    /** Fushi 持有的非 normal 权限（Anki 与存储）；INTERNET 是 normal，不算特权。 */
    private val held = OpenWithUriPolicy.PrivilegedPermissionCheck { it == ankiPerm || it == storagePerm }

    private fun decide(
        authority: String?,
        provider: ProviderFacts?,
        persisted: Boolean = false,
    ): Verdict = OpenWithUriPolicy.decide(
        own, OpenWithUriPolicy.bareAuthority(authority), provider, persisted, held,
    )

    @Test
    fun fileManagerFileProviderReliesOnGrantAndIsAllowed() {
        val fileProvider = ProviderFacts("com.tencent.mobileqq", false, null, null)
        assertEquals(Verdict.ALLOW, decide("com.tencent.mobileqq.fileprovider", fileProvider))
    }

    @Test
    fun safDocumentsProviderGuardedByManageDocumentsIsAllowed() {
        val docs = ProviderFacts("com.android.externalstorage", true, manageDocuments, null)
        assertEquals(Verdict.ALLOW, decide("com.android.externalstorage.documents", docs))
        val downloads = ProviderFacts("com.android.providers.downloads", true, manageDocuments, null)
        assertEquals(Verdict.ALLOW, decide("com.android.providers.downloads.documents", downloads))
    }

    @Test
    fun mediaStoreIsAllowedEvenIfGuardedByStoragePermissionFushiHolds() {
        val media = ProviderFacts("com.android.providers.media.module", true, storagePerm, null)
        assertEquals(Verdict.ALLOW, decide("media", media))
        assertEquals(Verdict.ALLOW, decide("0@media", media))
    }

    @Test
    fun downloadManagerPathPermissionsFushiLacksOrAreNormalAreAllowed() {
        // /all_downloads 要 ACCESS_ALL_DOWNLOADS（signature，Fushi 没有）：只能靠 grant 读。
        val allDownloads = ProviderFacts(
            "com.android.providers.downloads", true, null,
            listOf("android.permission.ACCESS_ALL_DOWNLOADS"),
        )
        assertEquals(Verdict.ALLOW, decide("downloads", allDownloads))
        // /my_downloads 只要 INTERNET（normal，人人可声明）：不构成特权。
        val myDownloads = ProviderFacts(
            "com.android.providers.downloads", true, null, listOf("android.permission.INTERNET"),
        )
        assertEquals(Verdict.ALLOW, decide("downloads", myDownloads))
    }

    @Test
    fun exportedProviderWithoutReadPermissionIsAllowed() {
        val open = ProviderFacts("com.example.reader", true, null, null)
        assertEquals(Verdict.ALLOW, decide("com.example.reader.books", open))
    }

    @Test
    fun unresolvableProviderIsAllowed() {
        assertEquals(Verdict.ALLOW, decide("com.invisible.provider", null))
    }

    @Test
    fun ankiDatabaseGuardedByPermissionFushiHoldsIsRefused() {
        val anki = ProviderFacts("com.ichi2.anki", true, ankiPerm, null)
        assertEquals(Verdict.REJECT_SELF_PRIVILEGED_PERMISSION, decide("com.ichi2.anki.flashcards", anki))
        // 带用户号前缀绕不过去。
        assertEquals(Verdict.REJECT_SELF_PRIVILEGED_PERMISSION, decide("0@com.ichi2.anki.flashcards", anki))
    }

    @Test
    fun pathPermissionFushiHoldsIsRefused() {
        val guardedPath = ProviderFacts("com.example.vault", true, null, listOf(storagePerm))
        assertEquals(Verdict.REJECT_SELF_PRIVILEGED_PERMISSION, decide("com.example.vault", guardedPath))
    }

    @Test
    fun ownProviderIsRefusedIncludingUserPrefixedAuthority() {
        val mine = ProviderFacts(own, false, null, null)
        assertEquals(Verdict.REJECT_OWN_PROVIDER, decide("app.fushi.reader.provider", mine))
        assertEquals(Verdict.REJECT_OWN_PROVIDER, decide("0@app.fushi.reader.provider", mine))
    }

    @Test
    fun uriUnderFushisOwnPersistedGrantIsRefused() {
        val docs = ProviderFacts("com.android.externalstorage", true, manageDocuments, null)
        assertEquals(
            Verdict.REJECT_SELF_PERSISTED_GRANT,
            decide("com.android.externalstorage.documents", docs, persisted = true),
        )
    }

    @Test
    fun malformedAuthorityIsRefused() {
        val any = ProviderFacts("x", false, null, null)
        assertEquals(Verdict.REJECT_BAD_AUTHORITY, decide(null, any))
        assertEquals(Verdict.REJECT_BAD_AUTHORITY, decide("", any))
        assertEquals(Verdict.REJECT_BAD_AUTHORITY, decide("abc@com.ichi2.anki.flashcards", any))
        assertEquals(Verdict.REJECT_BAD_AUTHORITY, decide("@media", any))
    }

    @Test
    fun bareAuthorityStripsNumericUserPrefixOnly() {
        assertEquals("media", OpenWithUriPolicy.bareAuthority("10@media"))
        assertEquals("com.x.fileprovider", OpenWithUriPolicy.bareAuthority("com.x.fileprovider"))
        assertNull(OpenWithUriPolicy.bareAuthority("u0@media"))
        assertNull(OpenWithUriPolicy.bareAuthority("10@"))
    }

    @Test
    fun grantCoversExactAndChildPathsOnly() {
        val tree = "content://com.android.externalstorage.documents/tree/primary%3ABooks"
        assertTrue(OpenWithUriPolicy.grantCovers(tree, tree))
        assertTrue(OpenWithUriPolicy.grantCovers(tree, "$tree/document/primary%3ABooks%2Fa.epub"))
        assertFalse(OpenWithUriPolicy.grantCovers(tree, "${tree}2/document/x"))
        assertFalse(
            OpenWithUriPolicy.grantCovers(
                tree, "content://com.android.externalstorage.documents/document/primary%3ABooks%2Fa.epub",
            ),
        )
    }
}
