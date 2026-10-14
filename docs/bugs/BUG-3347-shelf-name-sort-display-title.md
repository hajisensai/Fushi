## BUG-3347 · 书架/漫画库按名称排序与显示名不一致、全角数字不按数值排
- **报告**：2026-10-14（用户：漫画库「按名称排序但是没完全按名称排序。你看那个1，2，3，4。排序不对」，附截图：志乃と恋 ×3 → 志乃と恋3 → 志乃と恋 → 志乃と恋 2 → 志乃と恋 4）
- **真实性**：✅ 真 bug，两个根因叠加（用本机库副本核实书名与 override_title 偏好）：
  1. `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart` `_shelfGroupSortKey` 的 `titleOf` 读 DB 原始列 `epub.title` / `srt.title`，卡片却显示 `getDisplayTitleFromMediaItem`（改名覆盖 ?? 原名）。用户把「志乃と恋 [3574f94a]」改名成「志乃と恋」、「志乃と恋 3 [998c5526]」改成「志乃と恋 3」，按原名比 `'3'(0x33) < '['(0x5B)`，于是改名后的「志乃と恋」排到「志乃と恋 3」之后。
  2. `packages/fushi_engine/lib/media/collections/shelf_sort.dart` `naturalCompare` 只认半角数字：「志乃と恋 ２」「志乃と恋 ４」是全角（U+FF12/FF14），按码元比排在半角「3」之后。注释把它写成「诚实边界」，但日文书名全角 / 半角数字混用是常态。
- **[x] ① 已修复** — `titleOf` 改走 `displayTitleForBook`（EPUB 用 item 通道，SRT 用 bookKey / srtUid 通道，与卡片同源）；分组键改为排序前一次算好再排（原来比较器里每次比较都重算聚合键）。`naturalCompare` 比较前把全角 ASCII（U+FF01–FF5E）与全角空格折成半角，数字段识别与数值比较都走折叠后的码元。
- **[x] ② 已加自动化测试** — `fushi/test/media/shelf_sort_test.dart`：「全角数字与半角数字同一把数值尺（用户漫画库实际书名）」+ 源码守卫「书架排序键的名称取卡片显示名」。
- **备注**：汉字数字（一二三）仍按码元序；不同作品之间的汉字按码点排（无读音数据），这是已知边界。
