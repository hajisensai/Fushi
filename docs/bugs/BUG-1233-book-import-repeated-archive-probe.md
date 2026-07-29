## BUG-1233 · 书籍导入重复整包判定 EPUB 载体
- **报告**：2026-07-29（用户：TODO-2189）
- **真实性**：✅ 真 bug。PR #523 分家后，普通 `.epub` 会先在
  `hibiki/lib/src/media/audiobook/book_import_dialog.dart:224` 的漫画误投闸门执行
  `MangaModule.isImageArchive`，仅 EPUB 路径又会在
  `hibiki/lib/src/media/audiobook/book_import_dialog.dart:977` 最终分派时重复执行；
  memo 前 exact head `22e7c1858` 的真实 EPUB widget 复现为期望 1、实际 2。
- **[x] ① 已修复** — `c88df258a`：`ImportCarrierResolver.resolve` 按真实路径复用
  载体判定，`BookImportDialog` 的误投闸门与最终分派共享同一 resolver；换路径自动
  重算。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/import/book_import_dialog_real_carrier_memo_test.dart` pump 真
  `BookImportDialog`，用真实 EPUB+匹配 SRT、真实 Import 动作与真
  `MangaModule.isImageArchive` 外层计数，断言对齐落库、同路径一次、换路径重算；
  同时区分漫画专用入口无确认与书籍误投一次确认。
- **备注**：旧 head 失败与缓存早退变异日志：
  `.codex-test/todo-2189/pr523-pre-memo/old-head-failure.log`、
  `.codex-test/todo-2189/mutation-cache-bypass/mutation-failure.log`。Android 物理机
  未在本线程验证，不能据此宣称真机通过。
