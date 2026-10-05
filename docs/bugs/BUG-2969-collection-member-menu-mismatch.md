## BUG-2969 · 合集详情页成员右键菜单与书架不一致且没有标签
- **报告**：2026-10-05（用户：「合集内没得选标签而且合集内右键跟外面不一样」）
- **真实性**：✅ 真 bug。合集详情页成员卡被 `IgnorePointer` 包住，指针右键 / 触摸长按松手由网格接管，走的是详情页自绘的 `_showMemberMenu`（`fushi/lib/src/pages/implementations/media_collection_grid_detail_page.dart:247`），只有「打开 / 移出合集」两项；书架书卡的菜单（`MediaItemDialogPage` + `_epubExtraActions`：标签 / 标记读完 / 重置进度 / 重命名 / 删除…）只有键盘手柄长按 A 才到得了。于是鼠标 / 触屏用户在合集内既选不了标签，右键也和外面对不上。
- **[x] ① 已修复（b01a89347b5）** — 详情页新增 `onShowMemberMenu` 注入点，网格右键 / 长按交给调用方；书架传入 `_showCollectionMemberMenu`，按成员身份分派到与书架卡**同一个**菜单函数（`_showEpubItemMenu`（从 `_buildEpubBookCard` 抽出）/ `_showSrtBookDialog` / `_showRemoteBookDialog` / `_showRemoteSrtDialog`），只多一条共享的「移出合集」（`_removeFromCollectionActions`，远端占位卡也补上）。游戏库等未注入的调用方仍走原精简菜单。
- **[x] ② 已加自动化测试（b01a89347b5；页面级回归另见 3565b1fe665 的 `fushi/test/pages/reader_shelf_collection_cards_test.dart`）** — `fushi/test/pages/collection_member_menu_parity_test.dart`（详情页长按 / 右键交给共享菜单、不再弹精简菜单、注入的移出仍真删成员；书架源码守卫：成员菜单与书卡复用同一组菜单函数、菜单含「标签」）。
- **备注**：—
