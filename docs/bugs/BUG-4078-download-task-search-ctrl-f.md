## BUG-4078 · 浏览 › 下载任务页按 Ctrl+F 不聚焦任务搜索框
- **报告**：2026-11-04（用户：应用内反馈 zOC-x2RB4w，Windows）
- **真实性**：✅ 真 bug。任务搜索框是 `fushi/lib/src/media/downloads/download_task_browser.dart` 的 `FushiSearchBar(focusNode: _searchFocus)`，但没有任何快捷键接到它；Ctrl+F 绑在 `ShortcutAction.librarySearch`（`fushi/lib/src/shortcuts/shortcut_defaults.dart:161`），只经 `FushiHeaderSearchKeys`（`fushi/lib/src/utils/components/fushi_header_search.dart:212`）生效，而它只包在库页外壳外面，浏览页 / 下载面板都没包，Ctrl+F 无人处理。
- **[x] ① 已修复** — `fushi_header_search.dart` 把 librarySearch 判据抽成 `FushiHeaderSearchKeys.matchesLibrarySearch`，新增 `FushiSearchFocusKeys`（命中即聚焦给定 FocusNode 并全选已有查询，判据同一份）；`DownloadTaskBrowser.build` 外包 `FushiSearchFocusKeys(_searchFocus, _search)`，搜索框改 `clearThenUnfocus`（Esc 先清空再失焦）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/download_task_browser_test.dart`「Ctrl+F on a task card focuses the task search field」：焦点在任务卡上按 Ctrl+F，断言搜索框获得焦点且全选。
- **备注**：真机未复测（本轮不做）。
