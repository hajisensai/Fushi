## BUG-1109 · galgame 制卡音频尾部被截断：引擎 PCM 首取即冻结 + 资源 dump 写完前就转码

- **报告**：2026-07-26（用户：「gal 的音频，感觉剩一些没放完就断了」）
- **真实性**：✅ 真 bug（两条独立的「读得太早」）
  - ① 引擎 PCM：`hibiki/lib/src/mining/gal_hook_session_controller.dart:2517`（文本轮询里
    `_scheduleLineAudioAttach`）→ `_attachLineAudio` 立刻 `grabUtterance(line.timestampMs)`。
    文本轮询间隔 80ms（同文件构造参数 `textPollInterval`），而 native 的拼接窗口是**前向**的
    `[ts-200, ts+6000]`（`hibiki/windows/runner/voice_hook_reader.cpp:511`）——台词到达那一刻
    窗口的前向部分**还是空的**，只能拼到这句语音当时已提交给混音器的开头。结果冻进
    `_lineVoiceCache` 后先到先得（制卡只读缓存，`gal_hook_session_controller.dart:1705`），
    这句语音**永远**停在被截断的版本，隔多久制卡都一样。
    整段一次性提交给 XAudio2 的引擎看不出问题；分块流式提交的引擎必然缺尾巴——这就是
    「有时候好、有时候断」的来源。
  - ② 资源原件：`hibiki/lib/src/mining/galgame_audio_source.dart` 的 `grabPairedVoiceBytes` /
    `pairedVoiceFilePathForResourceId` 只要 dump 目录里文件**存在**就转码 / 试听，没有等
    hook 写完。OGG 是分页容器，截断的文件照样解出前半段，所以表现为「有音频但少一截」
    而不是报错。
  - 对照：Loopback 那条链的同类缺陷已由 BUG-1101 用「前向延迟冻结」修过；本条是把同一
    纪律补到剩下两条链上。BUG-1101 的注释里「引擎 PCM 路径早就用的是前向窗口」只对了一半
    ——窗口是前向的，但**调用时刻**不是，已在本次改动中更正。

- **[x] ① 已修复（`implemented_unverified`）** — 提交 `HEAD`（分支
  `worktree-pr434-fixes`，原实现在 `worktree-gal-audio-truncation`）
  - PCM 链：新增 `_settleLineUtterance`（`gal_hook_session_controller.dart`）。台词到达后按
    `utteranceSettleInterval`（默认 250ms）重取，每轮把**更长**的结果写回 `_lineVoiceCache`
    ——制卡随时取到当前最完整的一段，不需要额外的收束通道。终止于两者之一：`_canSettleLine`
    不再成立／到 `utteranceSettleMax`（默认 6s，与 native `ts+6000` 窗口对齐）。等待全程在
    串行音频队列**之外**，只有单次 grab 入队（与 `_scheduleLoopbackFreeze` 同纪律，不堵后续
    台词和制卡）。
  - `_canSettleLine` 是收敛的**唯一**存活判据，且必须在**每个** await 之后复查（审查修复）：
    会话/行归属、音源仍是这个 engine、`_lastTextSeq <= line.seq`（下一句到达）、
    `_recapturingLineId == null`（补录窗口期内 `_manualRecaptureLines` 还没写，
    `_isUserAdjudicated` 兜不住）、非用户裁决、`_resourceIdForLine == null` 且不在
    `_pendingResourceMatches` 里（`_promoteLateResourceAudio` /
    `_refreshPendingResourceMatches` 升格成 `game_resource` 后，原件永远优先，收敛不得把
    backend 改回 `engine_pcm`）。
  - 收敛刻意**没有**「连续 N 轮没变长就算播完」：缓存单调变长，句中一个超过 N 轮的停顿
    （换气、演出停顿）就会把收敛骗停在半句上；多跑到上限的代价只是几次 grab。
  - 资源链：新增 `awaitStableVoiceDumpFile`（`galgame_audio_source.dart`），转码
    （`grabPairedVoiceBytes`）与试听（新增 `settledPairedVoiceFilePathForResourceId`，
    `exportLineAudioPreview` 改用之）前先等文件**静默** `quietPeriod`（默认 240ms）。
    判据刻意不是「连续两次采样一致」——hook 分块写，块间间隙很容易长过一个采样间隔，
    两次相同只证明「这一瞬间没在写」，照样放行半个文件（这条是写测试时暴露出来的，
    第一版实现就栽在这里）。到 `timeout`（默认 1.5s）仍在增长则 fail-open 用当前内容。
    另有 `staleAge`（默认 2s）短路：mtime 已经老过它的原件（翻回旧台词试听、同一句重复
    播放）直接放行，不必每次都白付一个静默期。阈值刻意远大于 `quietPeriod` —— Windows 上
    正在被写的文件按路径 stat 可能读到偏旧的 mtime，阈值太小会把「正在写」误判成
    「早写完」，把这道门短路成空操作。
  - **残留限制**：资源链的真正根治要 hook 侧写 `.part` 再原子 rename，代码在独立仓
    `hajisensai/hibiki-hook`，本仓消费端够不着；静默期是消费端能做到的最强判据。
    清理条件：hibiki-hook 落地原子 rename 后，这道门可以退化成「文件存在即可读」。

- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_utterance_settle_test.dart`（8 条）
  - 引擎 PCM 按增长收敛取整句：桩引擎逐次返回更长 PCM（50ms → 200ms → 500ms），断言
    首取确实只有 50ms（= 修复前落进卡里的内容），收敛后行时长与 `exportLineAudioPreview`
    都变成 500ms。
  - 下一句台词到达即收手：同一批两句，断言旧句只保留首取（`callsFor(ts) == 1`），
    不继续往前向窗口里拼下一句。
  - 下一句在收敛 `await delay` **期间**到达（审查修复的负向对照）：桩引擎把第二句推迟到
    旧句第一个 delay 的中间才交出，断言 `callsFor(旧句) == 1` 且旧句时长仍是 50ms。判据只
    放在 delay 之前时这条是红的（`Actual: <2>`，旧句被拼成 1000ms）。
  - 行被升格成 `game_resource` 后收敛立刻收手：断言 backend 保持 `game_resource`、
    grab 计数不再增长。守卫缺失时是红的（`Actual: 'engine_pcm'`）。
  - 补录窗口开着时收敛收手：`startLineRecapture` 后断言状态仍是 `pending` /
    `system_loopback` / `manual_recapture_recording`。守卫缺失时是红的
    （`Actual: TexthookerLineAudioStatus.matched`）。
  - `awaitStableVoiceDumpFile` 三条：分块写入时必须等到写完（这条在第一版「两次相同」
    实现下是红的）／到上限仍在写则 fail-open 不挂死／文件不存在立即返回。
  - 另把既有守卫 `engine PCM is frozen on line arrival and reused for that line`
    （`gal_hook_session_controller_test.dart`）显式关掉收敛（`utteranceSettleMax: Duration.zero`），
    让它继续只守「首取即冻结 + 制卡复用缓存」那半条契约，不随机器快慢抖动。

- **验证状态：`implemented_unverified`** —— 只有上述单测（含三条负向对照实测红→绿），
  **没有**真机验收、**没有**离线 replay，也没有跑过任何真实引擎。不得宣称「已修好」。
  升级为已验证的门：用**分块流式提交**语音的引擎跑原始路径「台词 → 制卡 → 卡里音频听完整句」，
  并确认下一句到达时旧句音频里没有混进下一句；资源链再确认边写边试听不再听到半句。
