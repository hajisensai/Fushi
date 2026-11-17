## BUG-4787 · 截屏识字：查词窗打开后又截了一次屏，Android 定格帧文件被清掉，这张卡静默不带图
- **报告**：2026-11-17（用户：PR #3609 合入后的遗留缺陷复核——「制卡前若又截了一次屏，上一帧文件被删，这张卡静默不带图」）
- **真实性**：✅ 真 bug（代码路径确认，未在真机上复现时间窗）。根因：
  - 原生每次定格都调 `fushi/android/app/src/main/java/app/fushi/reader/ScreenOcrOptions.java:77` `writeCardFrame`，写新帧前把 `screen_ocr_card/` 里除新帧外的旧帧全删（`:84-89`，防缓存目录无限增长，这一步本身是对的）。
  - Dart 侧 `fushi/lib/src/floating_ball/screen_ocr_card_image.dart:66`（修前行号）`ScreenOcrCardImage.readBytes` 每次都重新读盘、读不到就返回 null；高级制卡分区只在分区闭包里缓存字节，`writeScreenOcrCardImage` 又调一次 `readBytes` 重新读盘。查词窗从收到来源到用户点「+」/ 高级制卡「确认」之间只要又截一次屏（保持截屏会话时连续截屏），卡图就静默丢掉。
- **[x] ① 已修复** — 根因修在来源对象上：`ScreenOcrCardImage.readBytes`（`fushi/lib/src/floating_ball/screen_ocr_card_image.dart:78`）第一次读成功就把字节留在实例里，并发读取共用同一次读盘；读失败（原生还没把 `.part` rename 到位 / 已被清）不记住，下次再读。高级制卡分区与出卡图共用这一份。`PopupDictionaryPage` 收到来源就预读（`fushi/lib/src/pages/implementations/popup_dictionary_page.dart:193` `_preloadCardImage`，`initState` 与 `didUpdateWidget` 换来源时调），一键「+」路径的时间窗也压到收到来源那一刻。原生照旧删旧帧，缓存目录不增长。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/screen_ocr_card_image_test.dart`「定格帧读过一次后被下一次截屏清掉：字节留在来源里，照样出卡图」「第一次读时文件还没写完（不存在）：不记住失败，写好后再读拿得到」；`fushi/test/pages/popup_dictionary_screen_ocr_card_image_test.dart`「查词窗一收到卡图来源就先读进内存；常驻热页换了来源再读新的」（真 `PopupDictionaryPage`）。
- **备注**：真机（Android 连续截屏后在旧查词窗制卡）未复测，按任务约定不做真机验证。
