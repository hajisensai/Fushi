## BUG-1413 · 本地音频库 SQLITE_BUSY 被吞成与「真没这词」同形的 null
- **报告**：2026-08-02（用户：看板 TODO-2580，BUG-1365 备注里点名的残留边界）
- **真实性**：✅ 真 bug（用户可见失败形态真实存在，且**一条日志都不记**）。

  **与 BUG-1365 的关系**：同族，后者只修了「绑定期」那半。BUG-1365 把读端用
  `LocalAudioDb.waitForPendingIndexing` 确定性地排在**自家** in-flight 写端之后，
  消除了绑定期的读写无序。它没有、也修不了另一半——`local_audio_db.dart` 那个
  `catch → return null` 依然把 `SQLITE_BUSY` 压成与「库里真没这个词」**完全同形**
  的 `null`。BUG-1365 的备注原话：「跨 isolate 的『A isolate 建索引 / B isolate 查询』
  仍只有 `busy_timeout` 兜底……要根治需把在途登记提升到跨 isolate 共享」。

  **先摸清：那条跨 isolate 竞态今天不可达**（证据在下，故本条**不**去造跨 isolate
  在途登记——那是在解决一个不存在的问题）：

  - 桌面（Windows/macOS/Linux）**没有**第二个跑 `popupMain` 的 isolate。`popupMain`
    只被 Android 的 `PopupEngineHolder.kt:27/116` 在 `:popup` **独立进程**里当第二个
    FlutterEngine 入口拉起；桌面 runner 全都只有一个 engine
    （`hibiki/windows/runner/main.cpp:168`、`macos/Runner/MainFlutterWindow.swift:23`、
    `linux/runner/my_application.cc:58`）。桌面「弹窗词典」是主 isolate 里的一个 Dialog
    （`app_model.dart:4357-4378`），Windows 全局查词浮窗是原生 WebView2，桥消息也回主
    isolate 处理（`overlay_bridge_handlers.dart:62-66`）。
  - Android 那边确实有第二进程，但 `TtsChannel._isSupported == Platform.isAndroid`
    （`tts_channel.dart:44`）为真 → 两侧都走 native `TtsChannelHandler`，**Dart 的
    `LocalAudioDb.ensureIndexes` 根本不执行**。
  - 结论：「桌面跑 Dart 建索引」与「存在第二 isolate」两个条件从不同时成立，
    `_pendingIndexing`（`local_audio_db.dart:152`，isolate-local 静态）在桌面只有一份，
    BUG-1365 的防护在桌面**真的**成立。跨 isolate 拿不到完成信号是**结构事实**
    （静态字段不跨 isolate 共享，`TtsChannel.instance` 也是 isolate-local 单例），
    但今天没有代码路径能走到。

  **真正可达、且今天就在坑用户的是同一个「同形 null」，走的是另一条边**：

  1. `hibiki/lib/src/utils/misc/local_audio_db.dart:229`（修前）——`queryMeta` 的
     `catch (e, stack) { log; return null; }`：`SQLITE_BUSY` 与上面三处真·未命中的
     `null` 逐字节同形，调用方无从区分。`extractBlob` 同（`:288`）。
  2. `hibiki/lib/src/utils/misc/lookup_audio_playback.dart:51-53 / 60-62`（修前）——
     查词发音链对 `queryLocalAudio` 套 `.timeout(500ms)`，`on TimeoutException { return null; }`。
     **500ms 比只读连接自己的 `PRAGMA busy_timeout = 3000` 更短**，所以库一旦真被占用，
     永远是这里先到点：sqlite 的 `SqliteException` **压根没机会抛出来**，第 1 条的分类
     再准也打不中，而且这条路径**连一条日志都不记**（`ErrorLogService` 完全空白）。
     这是整条链上最静默的 fail-open 出口。
  3. `hibiki/lib/src/creator/enhancements/local_audio_enhancement.dart:150-152`（修前）——
     制卡链同款 `on TimeoutException { // Fall through }`，用户侧＝卡片音频字段空、零提示。
  4. 终点：`word_audio_resolver.dart:130-138` 的 `localAudio` 分支把 `null` 一视同仁当
     「这个库没有」跳过 → `popup.js:2439-2444` 只判 falsy → 弹「暂无发音」
     （i18n `popup_no_audio_available`）。用户无从知道其实是**数据库正忙**。

  可达窗口（桌面，同 isolate，与竞态无关）：`AppModel.initialise()` 在 `app_model.dart:2225`
  发起 `bindForNativeHandler()`，`tts_channel.dart:88` `unawaited(ensureIndexes)` 不阻塞
  init → `isInitialised` 随即置真、可以查词；而首次在大库上建索引「可达数秒」
  （BUG-1365 实测 3153ms）。**即 app 启动后头几秒的查词发音会静默落空**；设置页每次
  增删/开关本地音频库（`local_audio_manager.dart:166`）再触发一轮同样窗口。

  本地确定性实测（Windows，`flutter test`，不靠时间赛跑）：另一个 isolate 持
  `BEGIN EXCLUSIVE` 时，`LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう')`
  （库里**确实有**这个词）在 **3157ms** 后返回 `null`——与同一时刻查一个库里
  **确实没有**的词返回的 `null` 逐字节同形。这正是用户看到的「暂无发音」。

- **[x] ① 已修复** —— 把「没有答案」从一个**值**改成一个**类型**，与远端音源既有的
  `RemoteLookupUnreachableError` 同一套分工（「不可达/没答上」抛异常、「可达但确实
  没有」返回 null），不新造第二种概念：

  - `hibiki/lib/src/utils/misc/local_audio_db.dart`：新增 `LocalAudioUnavailableError`
    + `LocalAudioUnavailableReason{busy,timedOut}`；`queryMeta` / `extractBlob` 改
    `on SqliteException` 分类，`SQLITE_BUSY(5)`/`SQLITE_LOCKED(6)` 抛可区分类型。
    其余 sqlite 错误（缺表/损坏/无权限）是**稳定**故障、且导入期已被
    `isUsableAudioSource` 拦，保持既有 log + null 不动。
  - `hibiki/lib/src/utils/misc/tts_channel.dart`：`queryLocalAudio` / `extractLocalAudio`
    的 catch-all 前加 `on LocalAudioUnavailableError { rethrow; }`，让它穿透
    `Isolate.run` 边界（自定义异常可原样跨 `Isolate.run` 回传，已实测）。
  - `hibiki/lib/src/utils/misc/lookup_audio_playback.dart`：500ms 预算提为共享常量
    `kLocalAudioQueryBudget`；两处 `on TimeoutException` 不再 `return null`，改抛
    `LocalAudioUnavailableError(timedOut)`。**预算值本身不动**（保持既有手感）——
    改的是「预算耗尽」的含义：它是「没查出来」，不是「查出来没有」。
  - `hibiki/lib/src/utils/misc/word_audio_resolver.dart`：`_resolveLocal` / `_resolveLocalAt`
    接住该类型 → 记一条**用户可见**的错误日志（设置 → 诊断 → 错误日志，
    `settings_schema_system.dart:254-264`）后继续下一音源。刻意**不**做重试、
    **不**计入远端那套失败冷却：本地库忙是瞬态（建索引完就好），冷却会把一个
    马上就能用的库额外禁用 45s，把小问题放大成「这段时间该库全哑」。
  - `hibiki/lib/src/creator/enhancements/local_audio_enhancement.dart`：制卡链同样接住
    并记日志，行为仍是落远端/TTS 兜底（不崩制卡）。

  **没有加延迟、重试、sleep，也没有调大 `busy_timeout`**——调大超时是典型假修复：
  它只让撞上的概率变小，同形 null 一点没变（守卫测试钉死两条查询路径的
  `busy_timeout = 3000` 不得被调大）。

- **[x] ② 已加自动化测试** —— `hibiki/test/utils/misc/local_audio_busy_vs_miss_test.dart`（9 例）：
  - 行为级**确定性**复现：另一个 isolate 持 `BEGIN EXCLUSIVE` 造 BUSY（非时间赛跑），
    断言 `queryMeta` / `extractBlob` 撞锁抛 `busy`、而「库里真没这个词」仍是 `null`，
    放锁后立刻恢复；另一例断言该类型能穿透 `TtsChannel.queryLocalAudio` 的 `Isolate.run`。
  - `WordAudioResolver` 三例：没答上 → 记错误日志 + 继续下一源；真·未命中 → **不**污染
    错误日志；blob 提取阶段没答上同样分开处置。
  - 源码守卫：两处 `on TimeoutException` 必须抛 unavailable 且不得 `return null`；
    预算是共享常量且制卡链同用；`busy_timeout = 3000` 恰好两处不得被调大。

  变异实测（4 次，每次只改语义关键的一小处、均能编译）：① `_isBusy` 的 5/6 改 55/66
  → 3 条行为用例红、源码守卫仍绿（证明行为守卫不与字符串守卫重复）；② 删 `TtsChannel`
  的 `rethrow` → 只有「穿透 Isolate.run」红；③ 把 resolver 的日志调用短路 → 只有
  「记用户可见错误日志」+「blob 提取阶段」两例红；④ 把 `on TimeoutException` 改回
  `return null` → 只有对应源码守卫红。四次均反向替换还原，`git status --short` 干净。

- **备注**：仍未收口的同形出口（**知情留下**，非本条范围）：`queryMeta` / `extractBlob`
  对**非** BUSY 的 sqlite 错误（缺表/损坏）仍是 log + null；`popup.js:2439` 只判 falsy，
  要给用户区分文案（如「音频库忙，稍后重试」）需三份 popup.js 镜像 + 三处 bridge handler
  契约 + 17 语言 i18n 一起升级，代价远大于本条。跨 isolate 在途登记**刻意未做**——
  桌面无第二 isolate、Android 不走 Dart 路径（见上），今天不可达；一旦将来真在桌面引入
  第二个调 `queryLocalAudio` 的 isolate，它的 `TtsChannel._desktopDbConfigs` 会是空列表
  （恒返回 null）且 `_pendingIndexing` 各自一份，届时要一并处理。
