## BUG-4474 · 冷启动白屏：十条查词历史（几 MB JSON）每次都在 UI 线程同步解析，挡住首帧
- **报告**：2026-11-12（用户：「现在启动速度很慢，给我优化到无感知开屏」「安卓也慢有的人去到10秒，我的设备起码一秒白屏」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/models/dictionary_repository.dart:183`（修复前）：`loadFromDb()` 在启动的仓库并行装载里读整张 `dictionary_history`，逐行 `DictionarySearchResult.fromJson` 同步反序列化。历史每条是一整份查词结果（实测单条 0.26–1.5 MB JSON，十条共 7.9 MB），这一步在 UI isolate 上占 370–566 ms（Windows 桌面 Release，6 轮），而首页首帧根本不需要它；`AppModel.initialise()`（`fushi/lib/src/models/app_model.dart:4587`，修复前）等它，首帧又等 `initialise()`。给启动各阶段加了分段计时才定位到（改前 `repositories-load` 一段独占 Dart 侧启动的四成）。
- **[x] ① 已修复** — `loadFromDb(deferHistory: true)`：词典元数据装完就返回；历史在 `startDeferredHistoryLoad()` 放行后才读库（数据库 isolate 按序执行查询，几 MB 的整表读会让排在后面的启动查询白等 34–160 ms），在后台 isolate 里反序列化（`decodeDictionaryHistoryResults`），落定后通知重画。装载期间改历史的操作（查词入历史 / 删一条 / 改滚动位置）排到装载完成之后按原顺序执行，清空历史 / dispose 用既有的清除代次让在途装载作废；首页历史区装载期间留白而不是先闪「还没查过词」，导航预览等装载落定再取数。实测同机同数据 `repositories-load` 370–566 ms → 4–14 ms。同一 PR 里另把三端启动分段计时（进程创建 → 首页，写进诊断日志 `Startup.timeline`）接上，并把启动里几处彼此独立的小 IO 改成并发。
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_history_deferred_load_test.dart`（真 drift 内存库走真实写穿路径：未放行不读库、放行后落定并回调一次、装载中查词 / 重查 / 删除 / 清空 / dispose / 重载各自的次序与落库结果、坏行跳过、空历史、解码逐条对位）；`fushi/test/startup/startup_timeline_test.dart`（分段计时的拼接与原生段解析）。
- **备注**：
  - 这条只解决「历史解析挡首帧」。Windows 冷启动另外两块大头不在本条：引擎每次启动重编全部着色器管线约 1.3 s（另一个 PR 的引擎补丁做磁盘缓存），以及首帧压住时改窗口尺寸白等 100 ms 缩放同步超时（同在那个引擎补丁包）。
  - 安卓真机（小米平板 nabu）基线：点图标到首个内容约 1.2 s，没有单一大头，查词历史在该设备上只有约 64 ms；带分段计时的包上机后再定继续压哪几段。iOS 无法本地实测，合并后看 TestFlight 包诊断日志里的 `Startup.timeline`。
  - 未做：词典多的用户首帧前要装完全部词典（`FushiDicts.loadPendingAsync()`），怀疑是「10 秒」用户的原因，需要先拿到这类用户的 `Startup.timeline` 再动。
