## BUG-3145 · 浏览器扩展导入本地字幕后不显示，要拨一下 Fushi 字幕开关
- **报告**：2026-10-09（用户群：「导入本地字幕后没反应，要切到 Fushi 再切回来才导进去」）
- **真实性**：✅ 真 bug（扩展侧一条确定的路径；与 BUG-3146 的 app 无应答可能同时存在）。覆盖层受字幕能力总门 `netflixSubtitlePanel`（缺省 **关**）门控：总门关时 `tools/browser-extension/subtitle-panel.js:326` 的 `tick()` 直接返回，一个字都不画。只有拖放入口会先开门；从 Chrome 自己的侧边栏入口、「查字幕」装轨走的 `applyExternalSubtitle`（`subtitle-panel.js:1011` 只调 `showPanel()`）不开门，于是只看到「已加载 N 条」而画面上什么都没有。同时「Fushi 字幕」开关只读 `subtitleOverlayEnabled`（缺省开）就显示「开」（`vendor/action-popup.js:143`、`player-controls.js` 同口径）——明明一个字都不出却显示开；用户把它拨关再拨开时 `overlayToggleWrite` 顺带写开总门，字幕才「导进去」。真机复现：改前经侧边栏消息装轨后覆盖层不存在、`netflixSubtitlePanel` 未写。
- **[x] ① 已修复** — `applyExternalSubtitle` 装轨即开总门（同拖放入口，用户意图明确）；`fushiOverlayToggleState`（工具栏菜单）与播放器菜单 / 按钮的「开」改为「覆盖层开且总门开」，不再显示一个拨了也不出字的假「开」，从「关」翻开时连总门一起写。真机复测：装轨后下一拍出字，`netflixSubtitlePanel` 已写 true。提交见 PR。
- **[x] ② 已加自动化测试** — `tools/browser-extension/external-subtitle.test.js` ⑥（总门关时经侧边栏装轨即出字；删掉开门即红）、`action-popup.test.js` / `popup-overlay-toggle.test.js` / `player-controls.test.js` 的 BUG-3145 用例。
- **备注**：「切到 Fushi 再切回来」若指切到 Fushi app 窗口，那是 BUG-3146 的 app 不应答路径（解析字幕请求此前没有上限，会一直挂到 app 恢复应答），见那条。
