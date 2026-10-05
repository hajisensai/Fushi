package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * BUG-2967: which AnkiDroid channel methods may run on the Android main thread.
 * Everything that queries AnkiDroid's ContentProvider has to go to the background
 * executor, because the query can cold-start the AnkiDroid process and would freeze
 * the whole UI (Flutter raster + WebViews share the main thread under Hybrid
 * Composition).
 */
class AnkiChannelHandlerThreadingTest {
    @Test
    fun activityAndInProcessMethodsStayOnMain() {
        for (m in listOf(
            "requestAnkidroidPermissions",
            "hasAnkidroidPermission",
            "openAnkiPermissionSettings",
            "openNote",
        )) {
            assertTrue(AnkiChannelHandler.runsOnMainThread(m), m)
        }
    }

    @Test
    fun providerQueriesRunOffMain() {
        for (m in listOf(
            "checkForDuplicates",
            "findNotesByContent",
            "findNotesBySourceId",
            "addNote",
            "notesInfo",
            "updateNoteFields",
            "getDecks",
            "getModelList",
            "getFieldList",
            "createNoteType",
            "readNoteType",
            "updateNoteTypeStyling",
            "updateNoteTypeTemplates",
            "createDeck",
            "addFileToMedia",
            "someFutureMethod",
        )) {
            assertFalse(AnkiChannelHandler.runsOnMainThread(m), m)
        }
    }
}
