## BUG-5227 · 应用外查词卡「调整句子音频」的裁剪偏移是页面全局，并发的普通制卡也带上裁剪
- **报告**：2026-11-22（2026-11-22 合并审查 HBK-AUDIT-211，PR #4137）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.js:3349`（develop@283a920286）：面板确认的起止偏移写进页面全局 `__fushiPendingMineOverrides`，`popup.js:3784-3792` 在回点「+」的整个 await 期间（查重 → 取单词音频 → mineEntry 桥）都不清；而 `buildMinePayload` 对**每一次**组包都读这份全局。裁剪那笔卡卡在取音上时，用户点另一个词条的普通「+」，那张卡也带上 `miningOverrides`，宿主按偏移裁了它的句子音频。JS 替身测试复现：两份 mineEntry payload 都带偏移。
- **[x] ① 已修复** — 覆盖项改为请求参数：面板调 `fushiPopupMineEntryByIndex(idx, overrides)`，它把覆盖项作为第二参数交给「+」的 onclick（DOM 派发的真点击第二参数恒为 undefined），onclick 沿 mineEntry / updateEntry / minedCardAction / runInPageMinedCardAction / queueOverwrite 显式传到 `buildMinePayload(..., miningOverrides)`；页面全局与 `__fushiApplyPendingMineOverrides` 删除。浏览器扩展两份 vendor 镜像同步。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` `testCrossAppAudioTrimOffsetStaysWithItsOwnRequest`：真面板 Shift+← 调起点、确认制卡，取音挂起期间点另一个词条的「+」，断言只有裁剪卡带 `{audioStartDeltaMs:-500}`、之后同词条普通「+」也不带；修前红（`a plain + on another entry must not inherit the trim offset`）。另加源码断言不再出现该全局。
- **备注**：
