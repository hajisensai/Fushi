## BUG-4908 · 第二块屏上查词不会暂停漫画朗读 / 漫画有声
- **报告**：2026-11-20（用户：要求根本性修复 PR #3751 里遗留的「副屏查词不暂停漫画朗读」）
- **真实性**：✅ 真 bug。副屏开着时主屏点 OCR 字的查词显示在副屏（`routeCompanionLookup`），不走页内弹窗；副屏查词的开 / 关由 `CompanionContextRegistry.lookupOpened/lookupClosed` 分发给当前上下文的 `onLookupOpened/onLookupClosed`，小说 / 视频都接了，漫画没接。
  - 根因：`fushi/lib/src/media/manga/reader/manga_companion_hook.dart:175`（旧）`MangaCompanionReader` 接口只有 `countLookup`，`:366`（旧）`claim` 只传 `onLookupCounted`，副屏查词事件到不了漫画页。
- **[x] ① 已修复** — `MangaCompanionReader` 加 `lookupOpened` / `lookupClosed({resume})`，`MangaCompanionHook.claim` 把它们交给副屏上下文（与小说同一条路径）。页面实现转给朗读接线；`MangaLookupPause` 改为按来源（页内弹窗 / 副屏）记录还开着的查词，全部关掉才放手，副屏带着开着的查词走了（resume=false）只放手不起播。
- **[x] ② 已增加自动化测试** — `fushi/test/second_screen/manga_companion_hook_test.dart`（真实 `CompanionContextRegistry`：认领后每个副屏查词都送到页面、关闭带 resume 标志）；`fushi/test/media/manga/reader/manga_lookup_pause_test.dart`「第二块屏」组（两边同时开着先关一边不恢复、与先后无关；副屏走了不起播）。
- **验证**：5 份定向测试（播放驱动 / 查词暂停 / 播放卡 / 现场合成控制器 / 副屏钩子）全部执行通过，exit 0；全量 analyze 见提交。
- **备注**：真机双屏未复测。
