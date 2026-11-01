## BUG-3950 · 扩展「查字幕」/ 外挂字幕装上后刷新网页即消失
- **报告**：2026-11-01（用户：反馈 HlBC5BcpED，Windows，截图为 niconico `watch/so…` 页）
- **真实性**：✅ 真 bug。`tools/browser-extension/subtitle-panel.js` `applyExternalSubtitle`（原 :1079–1080）只把外挂轨写进页面内存 `window.fushiEpisodeCues`；Side Panel「查字幕」下载、本地选文件、拖放三条入口都落到这里（`fushiSubtitleSidePanelInstallTrack`）。页面刷新 → content script 重建、store 归空，没有任何持久化，只能重新搜索下载。
- **[x] ① 已修复** — 外挂轨按视频身份（`videoKey()`，niconico 即 `www.nicovideo.jp/watch/so…`）存进 `chrome.storage.local`：账本 `externalSubtitleIndex`（LRU：≤40 条、总 ≤4 MB、单条 ≤1.5 MB，超了从最旧淘汰，`subtitle-adapters.js` `fushiPlanExternalSubtitleSave`）+ 每轨一条正文键 `externalSubtitle:<videoKey>|<label>`；偏移随轨记账。`refreshHeadless` 首次见到某视频身份时 `restoreExternalTracks` 装回 store、切为当前轨并恢复偏移；正文缺失的账本条目自愈剔除。两镜像同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/external-subtitle.test.js` 末 4 条（真加载 subtitle-panel.js + 有状态 storage 桩模拟刷新；LRU 纯函数）；去掉 `refreshHeadless` 里的恢复调用 2 条变红（已变异实测）。
- **备注**：未在真浏览器 niconico 页复验，只有 node 行为测试。
