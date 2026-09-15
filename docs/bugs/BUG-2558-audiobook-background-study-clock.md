## BUG-2558 · 后台播放有声书时统计不计时（媒体中心后台听书全程无统计写入方）
- **报告**：2026-09-16（用户：hajisensai）
- **真实性**：✅ 真 bug，两条互不相干的路径各漏一段
  - **路径 A（书还开着，app 切后台 / 桌面失焦）**：`reader_fushi_page.dart:3095`
    `didChangeAppLifecycleState` 在 `paused` / `inactive` 无条件置
    `_studyClockLifecycleStopped = true` 并停表（:3130），而判据
    `studyClockMayRun`（`reader_fushi_page.dart:477` 原实现）里没有任何音频项——
    音频经 `AudiobookSession` 继续播、cue 继续推进、媒体通知继续刷，只有统计停了。
    锁屏听一小时，统计是 0。
  - **路径 B（退出书籍页后台续播）**：阅读器那只 `StudyClock` 随 reader 页 `dispose`
    一起 `detach()`（`reader_fushi_page.dart:2875`），而 `AudiobookSession` 是进程级
    常驻、开着 `audiobook_background_play` 时音频照播——**这一段根本没有任何统计写入
    方**（`docs/plans/2026-09-06-read-unit-ledger.md:103` 早已记为已知缺口）。
  - 旁证：全仓唯一把「有声书在播」接进统计的地方是 `audiobook.part.dart:687`
    `if (controller.isPlaying) _studyClock?.touch()`，那只喂空闲门（BUG-2212），
    不参与起停表判定。
  - **前置缺口（iOS）**：`ios/Runner/Info.plist` 缺 `UIBackgroundModes: audio`，
    iOS 在 app 进后台那一刻挂起进程，有声书直接断声——路径 A/B 在 iOS 上都不成立，
    audio_service 装的 Now Playing / 远程控制也形同虚设。
- **[x] ① 已修复** — `4700e22ab2`
  - 判据加第四个输入 `audiobookPlaying`（`reader_fushi_page.dart:470`）：**后台分支
    改为「有声书真在出声才计时」**。`manualPause` 仍一票否决；后台分支有意**不看**
    `modalDepth`（屏幕已关 / 窗口已切走时面板一样不可见，「用户在操作面板不是在读」
    的语义不成立，而「从有声书面板点播放再锁屏」是最常见的听书路径）；前台完全不看
    播放态，BUG-2208 原样保留。
  - BUG-2209 防的「后台挂起 / 熄屏 / 睡眠墙钟被一次性计入」**依然成立**：豁免要的是
    「正在出声」这条具体证据，不是「后台」这个状态本身。没在播就照旧停表。
  - 播放态翻转（媒体中心暂停键 / 耳机键 / 播完 / 拔耳机）经
    `_noteAudiobookPlayingForStudyClock`（`navigation.part.dart`）立刻 sync 运行态——
    **暂停之后不会再有 cue 推进来叫醒页面**，不 sync 的话时钟会一直空转到下一次前台
    事件，整段静音被计成阅读。
  - 路径 B：`AudiobookSession` 自带一只后台听书 `StudyClock`，判据
    `!hasReaderAttached && _book != null && 真在播`，与阅读器那只**互斥**（两只同时跑
    = 同一段时间记两遍）。翻转点三处全接：控制器 notify（含 just_audio
    `playingStream`）、`attachReader`、`detachReader`。统计身份走
    `SessionBookInfo.studyMediaKey`（launcher 两条分支都填**调用方传进来的 bookKey**）
    ——SRT 书源的 `bookKey` 是 `srt_books.uid`，直接用会让同一本书在统计中心裂成两条。
    只记时长不记字数（后台没有正文视口，`ReadUnitLedger` 的「翻走即计」无从谈起，
    与视频域只计时不计字同律）。`_stopInternal` 在清空 `_book` **之前**结算；
    `dispose` 走零 IO 的 `detach()`（在同步 dispose 里发 `stop()` 就是无人 await 的
    事务，会与随后的 `db.close()` 互等）。
  - iOS 补 `UIBackgroundModes: audio`（只声明 audio 一项）。
- **[x] ② 已加自动化测试** — `4700e22ab2`
  - `fushi/test/reader/reader_study_clock_policy_test.dart`：判据纯函数 5 条新用例
    （后台+在播可跑 / 后台停播即停 / 后台不看 modalDepth / 手动暂停仍一票否决 /
    前台不看播放态）。
  - `fushi/test/media/audiobook/audiobook_session_test.dart`：后台听书时钟 6 条**行为**
    用例（互斥交接 / 暂停即停表再播即续表 / 没在播不起表 / 停会话结算 / 库不可用不建
    时钟且不影响播放 / 统计身份回退）。
  - `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart`：8 条接线守卫
    （判据现读控制器不读镜像、翻转点三处全接、结算早于清空 `_book`、dispose 走
    detach、统计身份不用 SRT uid、launcher 两分支都填）。
  - `fushi/test/ios/info_plist_media_permission_guard_test.dart`：「lib/ 装了
    `AudioService.init` → plist 必须声明 `UIBackgroundModes: audio`」，与该文件既有
    几条同形（目录枚举型）。
  - 变异实测（四处，逐条确认真红且非零测试执行）：删 `!hasReaderAttached` → 行为+守卫
    各红；删控制器 notify 上的 sync → 3 红；后台分支改回 `return false` → 2 红；
    plist 的 `audio` 改成 `voip` → 1 红。
- **备注**：
  - **不在本次范围**：Windows / Linux 没有系统媒体中心（SMTC / MPRIS 只存在于设计
    文档，`generated_plugin_registrant` 里没有任何 audio 插件）。这两端「后台播放」
    本身可用（进程不挂起，音频照播），本次的统计行为在五端一致生效；缺的是窗外的
    系统播放卡片 / 媒体键，那是独立的原生插件工程。
  - Android 后台驻留隐式依赖 `show_media_notification` 开着
    （`audiobook_session.dart` 的 `_syncMediaNotification` 早退 → playbackState 永不
    下发 → 前台服务不启动），且 `AudioServiceConfig` 未显式配
    `androidStopForegroundOnPause`。两者都是既有形态，本次未动。
