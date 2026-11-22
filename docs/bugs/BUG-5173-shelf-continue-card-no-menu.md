## BUG-5173 · 书架「继续阅读」卡右键 / 长按没有任何菜单
- **报告**：2026-11-21（用户：应用内反馈 jhUN7a4f0j）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi_history_page.dart:2393`（`_buildContinueReadingHero` 里的 `entryOf`）构造 `FushiContinueEntry` 时没传 `onLongPress`；组件里 `onLongPress: entry.onLongPress, onSecondaryTap: entry.onLongPress`（`fushi_continue_card_row.dart:547-548`、`fushi_continue_blocks.dart:274-275`）拿到 null，长按 / 右键都没反应。同页书架网格书卡接的是 `_showEpubItemMenu`，视频 / 游戏库的继续卡也都传了 `onLongPress`，只有书架继续卡漏接。
- **[x] ① 已修复** — `entryOf` 补 `onLongPress`：经 `_companionPressed` 打开与网格书卡**同一个** `_showEpubItemMenu(item)`（菜单里不放「继续阅读」，#3803 口径不变）；伴屏高亮主卡用固定 id `reader-shelf-continue-hero`，并列卡用书卡 id `reader-shelf-book-<id>`，都能解析回这本书。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_shelf_continue_card_menu_test.dart`：挂真书架 + 两本读到一半的书，右键主卡 / 右键并列卡 / 长按主卡都弹出书条目菜单（「详情」项）且不开书；删掉 `onLongPress` 时三条全红。
- **备注**：首页 dashboard 的「继续」卡（`home_dashboard_page.dart` 的 `_continueMainEntry` / `_continueSideEntry`）同样没传 `onLongPress`。那里条目横跨书 / 视频 / 游戏 / 远端 / 有声书服务器，各自的菜单是各库页的私有方法，要跨页暴露菜单入口并决定远端 / 服务器条目给什么菜单，范围明显更大，本次未做，留待单独处理。
