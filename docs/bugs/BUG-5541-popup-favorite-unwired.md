## BUG-5541 · Android 应用外查词卡（:popup）点 ☆ 收藏没反应

- **报告**：2026-11-27（用户：应用内反馈 z26A3IZcKZ；cG0XybpnkA 同报）
- **真实性**：✅ 真 bug（从未接线，非回归）。根因
  `fushi/lib/src/pages/implementations/popup_dictionary_page.dart:1195`（构造 `DictionaryPopupLayer`
  只传了制卡 / 覆写 / 查重回调，没传 `onFavoriteEntry` / `onFavoriteCheck`）→
  `dictionary_popup_webview.dart` 的 `favoriteEntry` / `favoriteCheck` 桥见回调为 null 直接回 false：
  星标不变色、不写库、没有 toast。Android 截屏识字 / 悬浮字幕 / 系统划词都经 :popup 引擎的这一页；
  桌面覆盖窗走 `overlay_bridge_handlers.dart`，不受影响。
- **[x] ① 已修复** — 每层接上 `DictionaryPageMixin.onFavoriteEntry` / `onFavoriteCheck`（与 app 内
  弹窗同一实现，来源按本页 `dictionarySourceType`，与本窗的制卡统计同一口径）。收藏写 Drift 主库
  FavoriteWords，:popup 已以可写方式开着主库（只读的是复习库，见 BUG-5542），不需要转交主进程。原句与
  制卡 `{sentence}` 同源：基础层补外部入口那一行（`_withSourceSentence`），嵌套层是被点处那一句。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dictionary_source_line_test.dart`
  「z26A3IZcKZ: the external popup wires the star …」：真页面 + 内存主库，断言基础层收藏回调非空、
  收藏落 FavoriteWords（含原句为整行）、`favoriteCheck` 为真、再点取消收藏。
- **备注**：主进程里已打开的收藏夹页不会实时看到 :popup 的写入（Drift 查询流只感知本进程写），
  重进页面即见；与 :popup 写的查词 / 制卡统计同一现状。
