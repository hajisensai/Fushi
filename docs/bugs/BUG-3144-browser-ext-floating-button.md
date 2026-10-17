## BUG-3144 · 浏览器扩展悬浮按钮在非 YouTube 站点乱飞
- **报告**：2026-10-09（用户群：「悬浮小图标只在 YouTube 上位置正常，在其他网站（如 anichan.to）会乱飞」；开发者确认要修）
- **真实性**：✅ 真 bug。通用悬浮按钮（`tools/browser-extension/player-controls.js:264` `videoEl()`）同样取文档里第一个 `<video>`，挂错元素时要么贴到页头预告片旁、要么因为那个元素太小被尺寸门挡掉整个不出现；位置是 fixed 视口坐标（`player-controls.js:380`），只在 resize（`:872`）、悬停与每秒轮询时重摆——页面一滚动按钮就停在原处，离开视频「飞」；body / 容器带 transform 时 fixed 坐标系不是视口，整体偏移。真机复现（同 BUG-3143 测试页）：改前按钮根本不出现（第一个 `<video>` 是 160×90 预告片，被尺寸门挡掉）。
- **[x] ① 已修复** — `player-controls.js` 的 `videoEl` 改用 `video-target.js` 的 `fushiMainVideo()`；按钮与菜单的 left/top 按父级包含块（`fushiFixedOrigin`）折算；滚动（capture，含内部滚动容器）与 resize 按帧合并重摆；`fullscreenchange` 两帧后再摆一次。真机复测：按钮贴正片右上角 (1117,152)，页面下滚 160px 后跟到 (1117,-8)。提交见 PR。
- **[x] ② 已加自动化测试** — `tools/browser-extension/player-controls.test.js`「悬浮按钮：贴正片右上角（不是第一个 <video>），坐标按父级包含块折算」；`video-target.test.js`。
- **备注**：anichan.to 本站没在本机打开验证（盗版站点，未访问）；如果它的播放器在跨源 iframe 里，扩展的 content script 目前只注入顶层页面（manifest 没有 `all_frames`），那种站点的浮层仍然不可用，属于另一件事。
