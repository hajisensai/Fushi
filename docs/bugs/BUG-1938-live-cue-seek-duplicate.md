## BUG-1938 · 实时采集轨在来回跳转后同一句重复入轨
- **报告**：2026-08-29（用户：截图，实时采集轨里 12:49 同一句连着两行）
- **真实性**：✅ 真 bug。根因 `tools/browser-extension/content.js:669` `fushiLiveCueStart`
  ——live cue 的 `startMs` 记的是**这句在 DOM 里被我们看到的时刻**。上一次经过若是 seek 落在
  句子中段，它就比真实句首晚一两秒；下一次正常播放从句首采到同一句，两个起点差出
  `fushiSortedCueInsert` 的「同文本且句首相差 <750ms」窄窗（且新起点更早，正好从窗口前沿漏
  出去），于是同一句入轨两条。用整段区间对照的那份判据当时只在 `allowReplay`（seek 后第一份
  快照）里跑，正常播放到达该句时够不着。
- **[x] ① 已修复** — `content.js:683-694`：判据统一成「文本相关 + 落进已有那条的时间窗」，
  向后容差 750ms（采样抖动）、向前 3s（seek 落点偏移）；`allowReplay` 参数随之消失。唯一例外
  是同一次采样里刚定格的上一条（`state.justEndedCue`，每次采样开头清空）——DOM 在同一时刻把
  `abcdef` 更正/缩短成 `abc` 是**新句**，不是历史重复。
- **[x] ② 已加自动化测试** — `tools/browser-extension/universal-subtitle-providers.test.js`
  「seek 落在句中先采到这句，回跳后从句首经过不得再插一条同句」；变异实测：把向前容差改回
  750ms、或删掉 justEndedCue 跳过，各自都让用例变红。
- **备注**：起点仍是「被看到的时刻」，seek 落句中那条的时间戳会偏后一点——只消除了重复，
  没有回写更准的句首。
