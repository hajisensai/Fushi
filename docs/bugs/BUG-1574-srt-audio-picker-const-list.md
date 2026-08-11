## BUG-1574 · 书架「重新定位 SRT 音频」取消选择器崩溃：pickRealFilePaths 返回不可变常量空列表，调用方 sort 抛 UnsupportedError
- **报告**：2026-08-12（用户：真机日志）
- **真实性**：✅ 真 bug。用户手机日志：

  ```
  {Unsupported operation: Cannot modify an unmodifiable list}
  #0  UnmodifiableListMixin.sort (dart:_internal/list.dart:147)
  #1  _ReaderHistoryBooks._pickSrtAudioFiles (books.part.dart:1047)
  #2  _ReaderHistoryBooks._relocateSrtBookAudio (books.part.dart:371)
  #3  _ReaderHistoryBooks._srtExtraActions.<anonymous closure> (books.part.dart:235)
  ```

  根因不在书架，在统一文件拾取入口：
  `fushi/lib/src/media/import/real_path_directory_picker.dart:172`（`if (!context.mounted) return const <String>[];`）
  与 `fushi/lib/src/media/import/real_path_directory_picker.dart:220`
  （`_fallbackPickFiles` 的 `result?.files...toList() ?? const <String>[]`，**用户点「取消」时 `result == null` 走的就是这条**）。

  Dart 的编译期常量列表是 `UnmodifiableListMixin`，其 `sort` / `add` **无条件抛
  `UnsupportedError`，空列表照抛**（不是「非空才抛」）。而四个调用点全部「先就地 sort、
  再判空」，所以四个入口一起踩，只是书架这条被用户先撞上：

  | 调用点 | 行 |
  |---|---|
  | `fushi/lib/src/media/audiobook/audiobook_import_dialog.dart` | ~486 |
  | `fushi/lib/src/media/audiobook/book_import_dialog.dart` | ~607 |
  | `fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart` | ~1894（`..sort(...)` 级联） |
  | `fushi/lib/src/pages/implementations/reader_history/books.part.dart` | ~1047（用户踩的这条） |

  前两处紧跟着就是 `if (paths.isNotEmpty)`，说明作者本就预期「空」是正常返回值，
  只是 sort 排在判空之前 —— 修在四个调用点各加一次判空是补症状，源头一处修才对。
- **[x] ① 已修复** — 在源头让 `pickRealFilePaths` / `_fallbackPickFiles` 的**每条**返回路径都是可增长集合
  （`return <String>[]` / `?? <String>[]`），并把同一条不变式扩到 `_normalizeExtensions` 的空集合返回，
  文件里零 const 集合字面量、零特例；同时在 `pickRealFilePaths` 的文档注释里写明
  「调用方会就地 sort，所以必须返回可增长列表，别为了省一次分配改回去」。
  四个调用点一行未动。提交：（本轮由集成方统一提交）
- **[x] ② 已加自动化测试** — `fushi/test/media/import/real_path_picker_growable_test.dart`，两条腿：
  ① **行为测试**（`FilePicker.platform` 注入假实现）真的走一遍「用户取消 / context 已 unmount /
  正常选到文件」三条路径，对返回值就地 `sort` + `add`；
  ② **源码守卫**（用共享 `maskComments` 等长掩码 + 锚点哨兵）钉住该文件不得出现任何
  const 集合字面量，兜住将来新加的返回分支。
  变异实测：把两处改回常量空列表 → 行为测试 2 红、守卫 1 红；反向替换还原 → 全绿。
- **备注**：`_normalizeExtensions` 原本返回 `const <String>{}`，今天没有消费方 mutate 它，
  不是本次崩溃的成因；一并改成可增长是为了让「本文件不向外交出不可变集合」成为**无特例**的
  单一规则（守卫也因此不需要维护「哪些 const 是安全的」白名单）。
