## BUG-1400 · AppPaths 解析穿真实 prefs 通道，fake async 相位一次调用钉死整个 isolate（互联下载登记测试 flaky）
- **报告**：2026-08-02（看板 TODO-2595，PR#693 施工方顺带发现；非其引入）
- **真实性**：✅ 真 bug（测试夹具缺口，非生产逻辑缺陷）——根因
  `hibiki/lib/src/storage/app_paths.dart:173`（`_configuredDataRootPath()` 里的
  `SharedPreferences.getInstance()`）+ `hibiki/lib/src/storage/app_paths.dart:311`
  （`_useLegacyFlatDocumentsRoot()` 里的 `_prefsOrNull()`），在
  `hibiki/test/pages/home_video_remote_download_register_test.dart` 缺
  `SharedPreferences.setMockInitialValues` 的环境下变成永久挂起。

### 现象
`test/pages/home_video_remote_download_register_test.dart` 第三个用例
「host 有外挂字幕时连带下载并解析成 cue 写入」同代码重复跑约 **20%** 概率红在
`expect(row, isNotNull)`（第 190 行）。本机实测**修前 5/22 红**（基线 2/10 + 带诊断 3/12）。
正常路径下载登记链 **75~90ms** 走完，失败路径 **30s 后仍停在 `running`** —— 是硬挂起，不是慢。

### 根因
分阶段埋点定位到挂在 `_registerDownloadedVideo` → `_downloadRemoteSubtitleForBook` →
`AppPaths.videoSubtitlesDirectory()` → `_resolveDocumentsRoot()` 的
`_configuredDataRootPath()` 里，即 `SharedPreferences.getInstance()`。

链条：

1. `AppPaths` 的**运行时静态便捷层**（`documentsSubdirectory()` 等）每次解析根都 await
   `SharedPreferences.getInstance()`（`_configuredDataRootPath()` 一次、
   `_useLegacyFlatDocumentsRoot()` 一次）。封面抽取、字幕落点、缩略图这些**页面级
   fire-and-forget 链**全从它派生，所以 widget 测试的 `pump()` 相位会大量调用它。
2. 该测试只 mock 了 `plugins.flutter.io/path_provider`，**没 mock prefs 通道**。于是
   `getInstance()` 穿到**真实**平台通道，应答只能由**真实事件循环**投递。
3. `testWidgets` 的 fake async 相位收不到真实事件循环的投递 ⇒ 这次解析永久挂起。
4. `SharedPreferences.getInstance()` 把首次调用的 `Completer` 存在**进程级静态字段**
   （`shared_preferences-2.2.3/lib/shared_preferences.dart:24` `static Completer? _completer`，
   且 `_completer` 在 await **之前**就赋值）。⇒ 后续**每个**调用者，包括别的用例、包括
   `runAsync` 里的，都 join 同一条死 future。
5. `home_video_page` 的 `_refresh()` → `_backfillCovers()` 是 fire-and-forget 链，会在
   fake async 相位发起解析。它是否抢在别人前面成为「首次调用者」取决于调度时序 ⇒ **flaky**。
   一旦它抢到，第三个用例 `runAsync` 里的下载登记链就卡死在派生字幕目录处，
   任务停在 `running`、`VideoBooks` 行永远写不出来。

`AppPaths.resolve()` 的注释（`app_paths.dart:87-91`）早已写明这条路径「会被静态便捷层高频
调用，其中就包括 widget 测试」，并据此把**文件系统探测**挪出了 `_resolveDocumentsRoot`；
但**平台通道往返**具有一模一样的「FakeAsync 里永不完成」性质，当时没一起收口。

**为什么是夹具坏而不是功能坏**：生产端没有 FakeAsync，`getInstance()` 正常完成并缓存，
断言本身也完全正确。纯生产侧改不动它——`_configuredDataRootPath()` 按定义就必须读一次
pref，而在没有 handler 的环境里这次读**无法完成**（记忆化也救不了：被钉死的正是**第一次**
调用）。同目录 20+ 个 `home_video_*` / `galgame_*` widget 测试早已按约定装了 prefs mock，
本文件漏了。

### 修复
- **[x] ① 已修复** — `hibiki/test/pages/home_video_remote_download_register_test.dart`
  的 `setUp` 补 `SharedPreferences.setMockInitialValues(<String, Object>{})`，与同目录
  20+ 个 widget 测试同约定。装上后应答由 mock handler 在**进程内**以 microtask 给出，
  FakeAsync 会调度 microtask ⇒ 解析在 fake async 相位内就走完，跨相位依赖被**结构性消除**
  （不是概率降低）。**没有**加延迟 / 重试 / `pumpAndSettle` / 放宽断言。
  提交：见下方提交哈希。
- **[x] ② 已加自动化测试** — 新增
  `hibiki/test/storage/app_paths_fakeasync_prefs_channel_test.dart`：钉住
  「fake async 相位内发起的 `AppPaths` 解析必须在同一相位内完成」+「前一个用例的解析不得
  毒化后续 `runAsync` 里的解析」两条不变量。

### 证据
- 确定性复现（不靠自然 flake）：两个 `testWidgets`，A 在 fake async 相位 fire-and-forget
  一次 `AppPaths.documentsSubdirectory()`，B 在 `runAsync` 里解析同一路径 ——
  **无 prefs mock：3/3 红**（B `TimeoutException ... after 5002ms`）；
  **有 prefs mock：3/3 绿**（A 在 `pump()` 内即解析完，B 耗时 **1ms**）。
- 原用例：**修前 5/22 红**（20 次基线 2 红 + 12 次带诊断 3 红），**修后 0/20 红**。
- 新守卫变异实测：注掉 `setMockInitialValues` → 两个用例全红；还原 → 全绿。

### 备注
同一隐患在 `hibiki/test/pages/` 下还有 **21 个**文件（mock 了 path_provider 但没 mock
prefs），例如 `home_video_remote_download_dedup_test.dart` /
`home_video_remote_interconnect_test.dart` / `reader_remote_*` / `collections_*` 系列。
它们目前未观察到红，但携带同一条永久钉死路径。本轮范围只收口 TODO-2595 这一条，
批量补齐留作后续（改法机械：`setUp` 补一行）。
