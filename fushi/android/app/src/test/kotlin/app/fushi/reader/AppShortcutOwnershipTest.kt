package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BUG-4326：长按图标菜单同步只能处置自己发布过的固定快捷方式，自定义应用图标
 * （IconSwitchHelper 的 hibiki_custom_icon）等其它模块的 pinned 项一律不碰。
 */
class AppShortcutOwnershipTest {
    private val offered = setOf("lookup", "books")
    private val moduleDisabled = setOf("manga", "video")

    private fun classify(id: String?): AppShortcutOwnership.PinnedAction =
        AppShortcutOwnership.classifyPinned(id, offered, moduleDisabled)

    @Test
    fun customIconShortcutIsNeverDisabled() {
        assertEquals(
            AppShortcutOwnership.PinnedAction.KEEP,
            classify(IconSwitchHelper.CUSTOM_ICON_SHORTCUT_ID),
        )
        assertEquals(AppShortcutOwnership.PinnedAction.KEEP, classify("hibiki_custom_icon"))
    }

    @Test
    fun unknownForeignIdIsKept() {
        assertEquals(AppShortcutOwnership.PinnedAction.KEEP, classify("some_other_module"))
        assertEquals(AppShortcutOwnership.PinnedAction.KEEP, classify(null))
    }

    @Test
    fun offeredShortcutsAreKept() {
        assertEquals(AppShortcutOwnership.PinnedAction.KEEP, classify("lookup"))
        assertEquals(AppShortcutOwnership.PinnedAction.KEEP, classify("books"))
    }

    @Test
    fun moduleDisabledShortcutsUseModuleOffMessage() {
        assertEquals(AppShortcutOwnership.PinnedAction.DISABLE_MODULE_OFF, classify("manga"))
        assertEquals(AppShortcutOwnership.PinnedAction.DISABLE_MODULE_OFF, classify("video"))
    }

    @Test
    fun retiredAppShortcutsAreStillDisabled() {
        assertEquals(AppShortcutOwnership.PinnedAction.DISABLE_RETIRED, classify("games"))
        assertEquals(AppShortcutOwnership.PinnedAction.DISABLE_RETIRED, classify("settings"))
    }

    @Test
    fun customIconIdIsNotARetiredAppShortcut() {
        assertTrue(IconSwitchHelper.CUSTOM_ICON_SHORTCUT_ID !in AppShortcutOwnership.RETIRED_IDS)
    }
}
