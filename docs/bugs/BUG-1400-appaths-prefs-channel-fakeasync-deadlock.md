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
本轮范围只收口 TODO-2595 这一条，批量补齐留作后续。
**该后续已由下面的 TODO-2610 完成，且没有按「逐文件补 setUp」做。**

> ⚠️ **本节原先写的「同一隐患在 `hibiki/test/pages/` 下还有 21 个文件」是高估的，TODO-2610
> 复核后证伪**：那 21 个是按「mock 了 path_provider 但没 mock prefs」数出来的，而
> **「mock 了 path_provider」并不等于「触达 AppPaths」**。例如 `collections_*` 系列 mock
> path_provider 的真实原因是 `AppModel` 构造惰性触碰 `DefaultCacheManager` →
> `getApplicationSupportDirectory`，与 `AppPaths` 无关。准确数字见下节。

### 后续收口（TODO-2610，2026-08-02）

**结论：不逐文件补 `setUp`，改成套件级默认。**

上面「备注」里数出来的那 21 个文件，既**数错了**（判据用的是「mock 了 path_provider」，
不是「触达 `AppPaths`」，见下面的复核）、又是**一份会过期的快照**——两头都不是问题的边界。
真实触发面是
「所有会在 `pump()` 相位触达 `AppPaths` 解析的 widget 测试」——而 `AppPaths` 的静态便捷层
被封面 / 字幕 / 缩略图 / 着色器列举等页面级 fire-and-forget 链广泛派生，所以这是一个随页面
测试增长而增长的**开放集合**。逐文件补 `setUp` 有两个致命属性：

1. **永远慢一个文件**：枚举只能追认已经踩过的坑，第 22 个新页面测试天生落在名单外；
2. **默认沉默**：fire-and-forget 链被钉死通常**不报错**（没人 await 它），只有当某个用例
   恰好 await 到派生路径、或 `.timeout()` 留下的真实 Timer 撞上「A Timer is still pending」
   时才炸。所以「目前没红」完全不能推出「不受影响」。

因此修法收敛到**唯一宿主**：`hibiki/test/flutter_test_config.dart`（`flutter test` 对
`test/` 下每个文件自动加载的套件级 harness）在 `testExecutable` 里调一次
`installInMemorySharedPreferences()`，把 `SharedPreferences` 的**平台实现**换成进程内存储。
特殊情况直接不存在，不需要任何文件知道 BUG-1400 存在。

**为什么这是行为等价的**：`SharedPreferences.setMockInitialValues` 走的是
`SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore`
（`shared_preferences-2.2.3/lib/shared_preferences.dart:283-285`），**完全不经平台通道**，
并顺手把静态 `_completer` 复位。对 `AppPaths` 而言，空存储读出的 `getString(...) == null`
与原先「通道不可用 → `catch` → `null`」逐字节同结论——默认根与扁平/嵌套布局判定都不变。
仓库里也没有任何测试依赖「prefs 通道不可用」这一事实（已全仓核对）。

**为什么装一次而不是每用例 `setUp`**：装在 `testExecutable` 里严格早于任何 `setUpAll` /
`setUp` / 用例体，绝不会覆盖测试自己播下的种子值（已核对：全仓 33 个自装 mock 的文件，
安装点分别在 `setUp` / `setUpAll` / 用例体 / helper 里，没有一个在 `main()` 声明期播种，
所以不存在被反向覆盖的情况）。需要按用例隔离 prefs 的文件继续在自己的 `setUp` 里调
`setMockInitialValues`，那会晚于本次安装、正常生效。存量 33 处一律保留不动。

**守卫改成正向规则**：`hibiki/test/storage/app_paths_fakeasync_prefs_channel_test.dart`
原来只有两条行为断言 + 一个**自带的局部 `setUp`**，于是它只能证明「装了 mock 就好」，
对第 22 个漏网文件零覆盖。现在：

- **删掉它自己的局部 `setUp`** —— 两条行为用例因此直接验的就是套件级 harness，任何人把
  harness 拆掉，这里立刻红；
- 新增第三条**源码规则**：扫 `test/flutter_test_config.dart`，要求 `testExecutable` 体内
  真的调了 `installInMemorySharedPreferences()`、且该函数体内真的调了
  `setMockInitialValues(`。用 `helpers/source_guard.dart` 的 `methodBody` +
  `containsCodeLine` 做结构窗口与注释掩码（禁止裸 `contains`）。

**变异实测**（全部经 `hibiki/tool/flutter_test_failures.dart` 判定，只认 verdict 行 + 退出码）：

| 变异 | 结果 |
|---|---|
| 基线（harness 在位） | `PASSED - 3 tests ran` |
| 只删守卫自己的旧局部 `setUp`，保留 harness | `PASSED - 2 tests ran`（证明真是 harness 在兜底，不是局部 mock） |
| 再删 harness 里的 `installInMemorySharedPreferences()` | `FAILED` —— 两条行为用例**全红** |
| 把 `installInMemorySharedPreferences()` 改成**注释**（断言字面量塞进注释） | `FAILED` —— 3 红，源码规则未被注释骗绿 |
| 保留调用但把 `installInMemorySharedPreferences` **函数体掏空**（`setMockInitialValues` 塞进注释） | `FAILED` —— 3 红，命中「没有真的换掉」那条 reason |

#### 复核出来的真实受影响面（证伪了「21 个」）

`hibiki/test/pages/` 实为 **479** 个 `.dart`，其中含 `testWidgets` 的 **173** 个、纯 `test()`
的 **306** 个。逐链路复核（lib 侧解析入口 → 反向追调用者 → 回到 test 读代码）后，**拿得出
硬证据**判定「pump 相位真的会走到 `AppPaths` 解析层」且**未装 prefs mock** 的只有 **4 个**：

| 文件（`hibiki/test/pages/`） | 链路 |
|---|---|
| `home_video_remote_download_dedup_test.dart` | 挂载期 fire-and-forget |
| `shelf_video_selection_back_intercept_test.dart` | 挂载期 fire-and-forget |
| `home_video_remote_interconnect_test.dart` | 远端下载收尾 → 再触封面回填 |
| `home_video_interconnect_manager_test.dart` | 远端下载收尾 → 再触封面回填 |

两条链：
- **链 A**（挂载期）：`HomeVideoPage.initState` → `home_video_page.dart:310`
  `_maybeBackfillCovers()` → `:541 extractVideoCover(...)` →
  `video_cover_extractor.dart:205 AppPaths.videoCoversDirectory()` → `_resolveDocumentsRoot`
  → `_configuredDataRootPath`（`app_paths.dart:173`）→ `SharedPreferences.getInstance()`。
  同一帧还有 `initState:312 unawaited(_maybeAutoScrape())` → `home_video_page.dart:1845`
  `VideoStorage.coversDir()`（`videoAutoScrape` 默认 true）。
- **链 B**（远端下载）：`home_video_page.dart:1485 _registerDownloadedVideo` →
  `_downloadRemoteSubtitleForBook` → `:1605 AppPaths.videoSubtitlesDirectory()`；
  收尾的 `:1461 _refresh()` 又会再触发链 A。

已装 `setMockInitialValues` 因而天然免疫的有 **22 个**（其中 10 个 `home_video_*` +
`home_dashboard_page_test.dart` 经复核确实走链 A/A'，那些 mock 不是白装的）。

排掉的大类及判据：
- **306 个无 `testWidgets` 的文件**：没有 FakeAsync widget 相位，其中 199 个是读 lib 源码
  做正则断言的静态守卫，不 pump 树、不建 `AppModel`；
- **整批 reader / 书架测试**：`EpubStorage.bookDirExists` / `deleteBookDir`
  （`epub_storage.dart:63-77`）只对传入的绝对 `extractDir` 做 `Directory` 操作，**不碰
  `AppPaths`**；真正走 `AppPaths.documentsRootDirectory()` 的 `baseDirectory` /
  `bookDirectory` / `bookPath` 只在**导入**路径被调，而 `test/pages/` 下没有任何文件驱动真实
  导入；
- **远端封面渲染链**：走 `AppPaths.tempRootDirectory` 分支，`_resolveTempRoot`
  （`app_paths.dart:363`）**完全不读 prefs**。

**但「只有 4 个」恰恰不是逐文件补 setUp 的理由，而是反对它的理由**：这 4 个是**当下快照**。
复核同时发现了一个**尚未被任何测试踩到的开放入口**——`video_hibiki_page.dart:2829`
`resolveEnabledShaderPaths(...)` 在 `mpvConfig.highQuality`（默认 **true**）下无条件执行 →
`video_shader_manager.dart:26 AppPaths.mpvShadersDirectory()`。只要将来有人 pump 一个真实
可播放本地视频的 `VideoHibikiPage`，第 5 个受害者立刻出现，而名单里不会有它。
`media_collection_detail_page.dart:517`、`jimaku_batch_dialog.dart:350` 同理（只是当前没有
测试点到那个用户动作）。lib 侧共 **25 个文件**直接调 `AppPaths.`（62 处调用点），再加
`VideoStorage` 等间接层的 14 个消费方——这就是「开放集合」的实体证据。

**本轮 `hibiki/test/pages/` 下改动文件数：0**。逐文件补 `setUp` 只能覆盖上面那 4 个已知的，
对第 5 个零覆盖；而在另外 17 个「其实不受影响」的文件里补 `setUp`，只会留下无意义的噪音，
让后来人误以为那些位置各自有过独立问题。套件级修法之后，四者与未来的第 N 个一并免疫。
