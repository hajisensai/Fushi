## BUG-603 · 网飞制卡失败报成功+诊断不回传
- **报告**：2026-07-07（用户：）
- **真实性**：✅ 真 bug。两条根因：
  - **① 假成功**：网飞沉浸制卡缺有效的 requireAudio 中止。`ImmersionMiningEngine.mine`
    （`hibiki/lib/src/mining/immersion_mining_engine.dart:137`）的无音频中止被 `&& req.hasRange`
    门控，而网飞 clip 恒 `clipStart==clipEnd==0`（`buildImmersionRequest`
    `hibiki/lib/src/mining/immersion_capture_channel.dart:78-91` 把两端都置 0）→ `hasRange=false`
    → 守卫永不触发；且旧 `requireAudio: audio != null` 是自毁的（音频恰好丢时反而关掉守卫）。
    结果：录制片段丢音轨、甚至封面+音频全无（空壳卡）仍落卡并回 `success`。
  - **② 诊断黑洞**：远端挖词 `mineImmersion`/`mineEntry`
    （`hibiki/lib/src/models/app_model.dart` 的 `_AppModelRemoteLookupService`）只 `return
    outcome.result.name`，把 `errorDetail`/`audioWarning`（`packages/hibiki_anki/lib/src/anki_models.dart:822-859`）
    全丢；YouTube 分支失败只 `debugPrint` 不写错误日志；`buildRemoteMineResponse`
    （`hibiki/lib/src/sync/hibiki_remote_api_handlers.dart:70-80`）只回 `{result}`。用户既看不到
    原因、错误日志里也查不到。
- **[x] ① 已修复** — commit（本轮，见文末哈希）：
  - `immersion_mining_engine.dart`：无音频中止改为「区间抽取路径(hasRange) 或 provided 字节路径
    (providedCoverBytes 非空且无 range) 且 requireAudio 且 audioPath==null」→ 覆盖网飞无 range 的
    provided-bytes 来源；新增**空壳卡兜底**（cover+audio 全无 → 中止）；带回 `abortReason`。
    in-app 视频「无 cue」路径（走 stillFallback、无 providedCoverBytes）不落任一分支，静帧卡行为不变。
  - `immersion_capture_channel.dart`：`buildImmersionRequest` 加 `required bool audioExpected`，
    `requireAudio: audioExpected`（取代自毁的 `audio != null`）。`app_model.dart` 网飞分支按
    `audioExpected = payload.clipBytes != null`（录制片段必有音轨）传入。
  - 诊断回传：`HibikiRemoteMiningService.mineEntry/mineImmersion` 返回类型改 `RemoteMineResult`
    （result+message+detail，`hibiki_remote_lookup_service.dart`）；`buildRemoteMineResponse` 响应体加
    `message`/`detail`（不改返回类型 Map，向后兼容）。`remoteMineResultFromOutcome` 复用
    `logMineFailure` 把失败写 `ErrorLogService` 并取本地化文案；`remoteMineError` 把引擎中止/解析失败
    写 `ErrorLogService`（不再只 debugPrint）。扩展 `content.js`（两镜像逐字节一致）`hibikiClassifyMineResp`
    读 `d.message||d.detail`，失败弹 `✗ 原因` toast、success+message（音频落空部分成功）弹 `⚠` 但仍算 done。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/mining/immersion_mining_engine_test.dart`：audio expected 但缺音频 → abort+abortReason；
    空壳卡（无 cover 无 audio）→ abort。
  - `hibiki/test/sync/remote_mine_response_diagnostics_test.dart`：`/api/mine` 响应体 error 回传
    message+detail、success+audioWarning 回传 message、纯成功不带诊断。
  - `hibiki/test/mining/remote_mine_result_logging_test.dart`：`remoteMineResultFromOutcome` /
    `remoteMineError` 失败写进 `ErrorLogService` + 回带 reason/detail；audioWarning/duplicate 语义。
  - `hibiki/test/mining/netflix_mine_diagnostics_guard_test.dart`：扩展 classify 读诊断 + 弹原因 toast +
    区分 audioWarning，两镜像逐字节一致。
- **备注**：TODO-1303。2A 截图卡 / 后台软解不可用（无 clipBytes）保持 `audioExpected=false`（截图卡本就
  无音频不算失败），仅空壳卡兜底覆盖；空壳/无音频改为失败并写错误日志 + 回传原因，终结「制卡失败报成功」。
