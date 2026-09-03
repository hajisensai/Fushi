## BUG-1952 · 一句台词分多次显示时工作台重复出现且字数重复统计（Zato）

- **报告**：2026-08-30（用户：一段台词分多次点击显示，工作台里第二句出现两次、字数被重复统计）
- **真实性**：✅ 真 bug。引擎（Zato）把同一句台词分多次吐出来，每次都是**整句的一个更长前缀/后缀**，而 `TexthookerService.appendLine` 每次都当新行追加。
- **[x] ① 已修复** — 判据是纯结构的**前缀/后缀关系**（`texthooker_line_fold.dart` 的 `isProgressiveTextUpdate`），**无时间窗、无重试、无吞异常**：同一 thread 相邻两行哪怕隔十分钟也照折，快慢结果一致。回吞沿 buffer 尾巴最多 8 条，合并结果复用**最早**那条的 id（这句话是从那一刻开始说的）。

  合入前修掉的四类问题（审查发现）：
  - **挂载层错了**（`texthooker_service.dart`）：折叠原本装在 `appendLine` 顶层，而该入口也服务 `websocket` 源（Textractor / mpv / 浏览器扩展，**5 平台都跑**），逃生开关却在 Windows-only 的 game 设置页里。收窄成 `source == TexthookerLineSource.engineHook` —— 这个来源门**同时就是平台门**（engineHook 行只由 Windows-only 的 `GalHookSessionController` 产出）。**不能**在服务层写 `Platform.isWindows`：本文件不 import `dart:io`，而 CI 真单测门跑在 Linux 上，那样写会让折叠的 17 条用例集体变成「折叠不发生」而全红。设置项自身补 `visible: (_) => Platform.isWindows`，与兄弟项 `game.ingame_lookup` 同门。
  - **被吞行的 lineId 在下游还是活键**：`_entries.removeLast()` 没有任何通知，而这些 id 在 `gal_hook_session_controller.dart` 里是 9 个 map/timer 的键（`_lineVoiceCache` / `_pendingResourceMatches` / `_loopbackFreezeTimers` / `_loopbackFreezeStartedAt` / `_lineTimestampCache` / `_lineTextEventIdCache` / `_loopbackCacheInFlight` / `_manualRecaptureLines` / `_lineVoiceSourcePtr`）。语音是**异步后到**的（收敛窗口最长几秒），而 Zato 两次点击之间远小于此 —— 晚到的 PCM 会写进死 id 被 `updateLineAudio` 静默丢弃，用户的手动裁决也随之失效。
    修法三层：① 服务层把被吞 id 作为**数据**交出去（`lastFoldedLineIds`，与既有的 `lastAppendedDelta` 同址同生命周期，不用回调 → 没有注册/注销与 observer 顺序问题）；② 会话层 `_redirectFoldedLines` 一次性迁完，语音取字节更长的那份、loopback 起点取最早的、身份缓存只删不搬（合并结果的值由调用方紧接着按本次事件写）；③ 已经在途的闭包（捕获的是折叠前的 `entry`）走 `_liveLineId` 重定向表，写入统一收进 `_cacheLineVoiceIfLonger` —— 折叠制造出**两条**都想写这一句的 settle 循环，各自的局部 `bestBytes` 互相看不见，「缓存单调变长」这条不变式只能在写入点守。
  - **折叠守卫漏 `sourceLabel`**：原判据只有 `source` + `textThreadKey`，而 WS 路径下后者恒 null、前者恒 `websocket`，能区分 Textractor / mpv / 浏览器扩展三个并发端点的**只有** `sourceLabel`（ws client 传的是 url）。漏了它就是把两个工具的输出折成一条。
  - **字数单位错**：增量原本在 `normalizeForFold` 的**去空白**坐标系里切，而 `countGalgameChars` 对拉丁文本按**词**计数、空白是唯一词边界 —— `"…a lovely way to put it"` 被焊成一个词，整段英文台词算成 1（Zato 本身就是英文样本）。新增 `rawPrefixCoverage` / `rawSuffixCoverage`：在归一化坐标系里**判**、在原文坐标系里**切**。
    连带：`GalgameLineCharCounter.countLine` 的状态模型是**整行**（`_lastText`/`_lastCount`），喂增量会把它污染成半句话、之后每次都是拿增量比增量，两次相邻增量恰好相同还会被静默吞成 0（在上游折叠之上再去重一次）。新增无状态的 `countDelta` 给引擎 hook 路径，`countLine` 留给 WS/剪贴板路径（那边没有上游折叠，去重只有这一份）。
    再连带：调用点原本 `if (countedText.isNotEmpty)` 才记活动，于是一段全靠重绘推进的长台词会让**活跃心跳整段停掉**（`shouldFlush` 节奏跟着断）。拆成 `_recordEngineDelta` / `_recordExternalLine` 两个入口后，空增量也照常记时间戳 —— 行到达本身就是「人在读」的信号。
- **[x] ② 已加自动化测试** — `fushi/test/sync/texthooker_progressive_fold_test.dart`（纯函数 + service 行为）与 `fushi/test/mining/` 的会话侧用例。
- **备注**：判据对**后缀**方向的假阳性是已知残余风险：A 说 `"Goodbye."`、B 说 `"I never got to say Goodbye."` 会被折成一条。`kMinFoldableLength = 4` 挡住了「はい」这类短行，但对拉丁语系近乎无效（`"Okay."` = 5）。折叠限定到 engineHook 之后影响面收窄到 galgame 单一场景，且开关默认可关。未做真机复测。
