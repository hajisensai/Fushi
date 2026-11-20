## BUG-4907 · 在线书原子写失败后清理临时文件出错会顶掉原始异常
- **报告**：2026-11-20（路线图 #3722 c40「顺带」，第一波 c01 / c02 留下的遗留）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/novel/online/online_novel_chapter_loader.dart:177-179`（修前）：`SerialOnlineNovelChapterLoader.writeAtomically` 写临时文件或改名失败后，在 `on Object` 里 `await temp.delete()` 再 `rethrow`。删除本身失败（Windows 上文件被杀毒 / 索引占用、只读）时抛出的是删除的 `FileSystemException`，写入 / 改名的原始异常丢失，错误日志与阅读器提示都指向错误的原因。
- **[x] ① 已修复** — 清理包进自己的 `try`，清理失败只经 `engineLog` 留痕，随后 `rethrow` 原始异常。
- **[x] ② 已加自动化测试** — `fushi/test/media/novel/online_novel_chapter_loader_test.dart`「原子写：改名失败、清理临时文件也失败时，抛出的仍是改名的原始异常」：`IOOverrides` 注入改名与删除都抛的临时文件替身，断言抛出的是改名那一个对象（修前是 `delete boom`）。
- **备注**：残留的 `.part` 文件不影响阅读（阅读器只认 `chapter-<n>.xhtml`），下次就地重建解压树时被整体替换。
