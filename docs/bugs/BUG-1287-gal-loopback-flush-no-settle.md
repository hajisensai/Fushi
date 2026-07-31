## BUG-1287 · galgame 查词/制卡时语音只到句子前半段：loopback 提前收束后不再补全
- **报告**：2026-07-31（用户：我查一个词，它在句子的中后段，然后语音只到前半段就中断了）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart` 的
  `_flushLoopbackFreeze`（修复前：`timer.cancel()` 之后不再补排任何回取）
- **[x] ① 已修复** — `hibiki/lib/src/mining/gal_hook_session_controller.dart`

  Loopback 抓音是「台词到达后等 `loopbackFreezeDelay`（默认 4s）再回取整句」（BUG-1101）。
  用户在台词播到中后段才查词/制卡时，`captureAudioBytes` → `_captureAudioBytesNow` 会调
  `_flushLoopbackFreeze` 提前收束：它 `timer.cancel()` 把完整窗口的定时器**永久取消**，
  只按 `elapsedMs + preRoll` 回取——用户 1.5s 时查词就只有 1.5s，写进 `_lineVoiceCache`
  后**再没有任何补全机制**。也就是把「用户现在就要声音」实现成了「就此永久定格」，那半
  句话被钉死。引擎 PCM 那条路早有重取补全（`_settleLineUtterance`，BUG-1109），Loopback
  缺了对称的一半。

  修法：收束之后按**原到期时刻**补排一次补全（新增 `_scheduleLoopbackSettle`）——立刻给
  出能用的，窗口真正到点后再取一次完整 `delay + preRoll`，拿到更长的才覆盖。补全定时器
  仍装在 `_loopbackFreezeTimers` 里，因此会话结束 / 禁止降级（`_cancelLoopbackFreezes`）、
  用户补录与选轨都能像取消普通冻结一样取消它，不需要第二套生命周期。

  两处边界：
  - `_cacheLoopbackForLine` 新增 `onlyIfLonger`——补全取空或取短都保持已冻结结果不动，
    **且不标 missing**：一次失败的加取不该毁掉一份已经能用的音频。
  - `_flushAllLoopbackFreezes`（音源即将被换走时调用）传 `settle: false`——补全靠的正是
    这个 Loopback 源再多录一会儿，调用方下一步就是把它换掉，排了也只会被音源检查挡掉。

- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_attach_pchooks_loopback_settle_test.dart`

  - 「提前收束后仍按原窗口补全」：断言首次回取窗口 < `delay + preRoll`（确实只拿到前半
    段），随后出现一次完整窗口回取，且写回的 `audioDurationMs` 严格长于收束那一段。
  - 「补全取空时保留已冻结的短切片」：让补全那一次（按 **backMs 值**精确定位，不用调用
    序号——`captureAudioBytes` 内部还会为别的用途取音频）返回 null，断言时长原封不动。

  变异实测已做：摘掉 `_scheduleLoopbackSettle` 调用 → 核心测试如期变红
  （`does not contain <1400>`）。

- **备注**：断言刻意落在**最终状态**而非「收束瞬间」——`captureAudioBytes` 内部还有资源
  等待，返回时补全可能早已跑完，按时机读会拿到补全后的值（这一点在首版测试里真实踩到）。
  另：该测试不断言 `audioStatus`，因为测试装置里 `captureAudioBytes` 注定产不出字节，
  它自己的失败路径会把行标成 missing，与补全无关；真正的证据是时长。
