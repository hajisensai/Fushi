## BUG-2036 · 目录枚举守卫跟随 .plugin_symlinks 自指链，worktree 全量测试必崩两条
- **报告**：2026-09-02（发现于 BUG-2030 的合入前全量跑，非用户报告）
- **真实性**：✅ 真 bug。`fushi/test/tools/epub_chapter_parse_entry_guard_test.dart:46` 的 `_scannedDartFiles()` 以 `<String>['lib', '../packages']` 为根跑 `dir.listSync(recursive: true)`——**默认 `followLinks: true`**。而 `packages/flutter_inappwebview_windows/example/windows/flutter/ephemeral/.plugin_symlinks/flutter_inappwebview_windows` 是 `flutter pub get`（`tool/bootstrap.ps1` 会在该 example 下跑一次）生成的、**指回包自身**的符号链接：
  ```
  .plugin_symlinks/flutter_inappwebview_windows -> <repo>/packages/flutter_inappwebview_windows/
  ```
  跟随它就是无限自指递归，路径一路拼到 Windows 长度上限后抛 `PathNotFoundException: Directory listing failed, path = '../packages\flutter_inappwebview_windows\example\...\.plugin_symlinks\...\.plugin_symlinks\*'`。枚举当场崩，函数里那些「只留 `../packages/<pkg>/lib/`」的过滤**根本轮不到执行**（过滤在枚举之后）。
  - 影响面：**每个跑过 bootstrap 的 worktree**，全量测试固定红这 2 条（`扫描规模哨兵` + `章节 XHTML 的 DOM 解析只有一个入口`），直接挡住 CLAUDE.md 要求的「合入 develop 前本地全量绿」这道门。实测：21990 项里只有这 2 条失败，且是 IO 异常不是断言失败。
  - 为什么别的目录枚举守卫没踩：它们多数只扫 app 自己的 `lib/`；本条是少数把 `../packages` 也纳入根的。
- **[x] ① 已修复** — `listSync(recursive: true, followLinks: false)`。不跟随不会漏任何真实源文件（各包 `lib/` 下没有靠符号链接才能到达的 `.dart`），本地 3 项守卫（含「扫描规模哨兵」）全绿，证明枚举仍覆盖到 app 与内部包的 `lib/`。提交见本轮 commit。
- **[x] ② 已加自动化测试** — 守卫自身就是被修的测试；它带的「扫描规模哨兵」用例正是回归判据：跟随符号链接会当场抛异常、不跟随且扫不到东西也会红。
- **备注**：与 BUG-2030 同一轮发现但**互不相关**（一个是视频页控制条语义，一个是测试枚举跟随符号链接）；顺手修掉是因为它挡住了那次改动的合入前全量门。另一族 flaky（下载租约续期测试的墙钟断言）见 BUG-2035，那条未修。
