## BUG-4977 · 在线小说取章时 LNReader 状态读盘失败被误报成「插件没装」
- **报告**：2026-11-20（路线图 #3722 c40「顺带」，第一波 c01 / c02 留下的遗留）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/novel/online/lnreader_online_book.dart:534`（修前）：`LnReaderOnlineChapterLoader.loadChapter` 调的是 `manager.initialise()`。`LnReaderManager.initialise`（`lnreader_manager.dart:173-191`）按设计**不抛**：`state.json` 读不出来（占用 / 权限 / 根目录被占）时只把错误记进 `stateError`，`installed` 保持空占位。于是下面按插件 id 在空列表里找不到，抛 `LnReaderOnlinePluginMissing`，阅读器提示「插件没装」，真正的读盘错误被藏起来，用户会去重装插件而不是查磁盘。
- **[x] ① 已修复** — 改用 `manager.ensureReady()`：状态没读到就把那次读盘错误原样抛出（与所有写 `state.json` 的入口同一契约）。
- **[x] ② 已加自动化测试** — `fushi/test/media/novel/lnreader_online_book_test.dart`「插件状态读盘失败：报读盘错误本身，不误报「插件没装」」：管理器根目录位置被普通文件占着，断言取章抛 `FileSystemException` 且占位页保留（修前抛 `LnReaderOnlinePluginMissing`）。
- **备注**：无 UI 文案改动；阅读器侧的错误提示经 `describeOnlineSourceError` 归一。
