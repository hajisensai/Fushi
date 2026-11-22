## BUG-5229 · 「调整句子音频」试听在解码期间换范围再试听会同时响两段，停止只停后一段
- **报告**：2026-11-22（2026-11-22 合并审查 HBK-AUDIT-212，PR #4137）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.js:3438`（develop@283a920286）：`createCrossAppAudioPlayer.play()` 先 `await` 解码（与 resume），解码完才把 BufferSource 记进 `source` / `playing`。解码期间 `isPlaying()` 为 false，换范围的 `setRange` 不停它，再点试听又进一次 `play()`；两次 await 同一个解码 promise，回来后各自 `start()`，两段一起响，`stop()` 只够得着后登记的那个。JS 替身测试复现：两次 start，区间 [1.0,2.0] 与 [1.0,2.5] 秒。
- **[x] ① 已修复** — 试听请求在第一次 await 之前领号登记（`requestId` / `pendingId`），`stop()`（含换范围、关面板）让号作废；解码 / resume / `<audio>.play()` 回来时号已不是当前请求就放弃，不建 BufferSource、不报「在播」。新增 `isActive()`（在响或在等解码），`setRange` 用它停掉等待中的试听。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` `testCrossAppAudioPreviewSupersedesPendingDecode`：替身 AudioContext 延迟解码，覆盖 ①解码中换范围再试听只 start 一次且是新范围、停止停的就是它；②解码中只换范围不出声；③解码中关面板不出声。修前红（`a preview superseded while decoding must never start its own BufferSource`）。
- **备注**：
