## BUG-3255 · 浏览器扩展字幕偏移绝对值小于5ms时显示-0
- **报告**：2026-10-10（PR #2036 审查遗留疑点）
- **真实性**：✅ 真 bug。`formatOffsetSeconds` 先把毫秒舍入到 0.01s，`n !== 0` 但 |n| < 5ms 时 `sec` 舍入成 0 / -0，随后 `sec > 0 ? '+' : '-'` 落到负号分支，输出 `-0`（`tools/browser-extension/player-controls.js:140` 播放器菜单、`tools/browser-extension/side-panel.js:1093` 侧边栏，两份同形）。
- **[x] ① 已修复** — 两处在舍入后 `sec === 0`（含 -0）时返回 `'0'`；`fushi/assets/browser_extension/` 镜像经 `dart tool/sync_browser_extension.dart` 同步（`--check` 无漂移）。提交 fix(extension): show 0 instead of -0 for sub-5ms subtitle offsets
- **[x] ② 已加自动化测试** — `tools/browser-extension/player-controls.test.js`「parseOffsetSeconds / formatOffsetSeconds」加 ±1 / ±4 / -4.9ms 断言 `'0'`；`side-panel-offset-input.test.js` 交叉比对补同组样本（`node --test *.test.js` 908/908）。
- **备注**：
