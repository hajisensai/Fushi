## BUG-1895 · 查词弹窗静息加号比相邻操作图标矮
- **报告**：2026-08-27（用户截图：查词弹窗的 `+` 比同排发音、收藏、调整图标矮；补充反馈鼠标悬停时仍是普通箭头）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.js:3022` 创建制卡按钮时只写了 `className: 'mine-button'`，漏挂同排按钮共用的 `inline-action-button`，因此没有继承 `popup.css:384` 的 `inline-flex` 居中与 `cursor: pointer`；`popup.css:444` 又只把文本 `+` 从 18px 补到 24px，实际 WebView 截图里可见轮廓仍比相邻 18px SVG 矮一截。
- **[x] ① 已修复** — 制卡按钮补挂 `inline-action-button`，复用同排按钮的居中、悬停反馈与小手光标；静息 `+` 的文本字号补偿调整为 30px，使其可见轮廓与 18px SVG 图标齐平。已同步 app 弹窗与两份浏览器扩展 vendor 镜像，并重新生成 scoped `content.css`。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-mine-button-visual.test.js` 在可执行的 Node 层锁定源 CSS/JS；`fushi/test/dictionary/popup_mine_button_visual_guard_test.dart` 再对三份 CSS/JS 镜像锁定静息 `+` 为 30px，并断言制卡按钮必须使用 `inline-action-button mine-button`，防止居中与 pointer 光标再次丢失。
- **备注**：浏览器扩展 242 条 Node 测试（含本 bug 两条）、CSS 生成器检查、扩展镜像检查已通过。Flutter 聚焦/全量测试在零用例阶段被 `pdfium_dart` 下载 `pdfium-win-x64.tgz` 的 Windows socket 121 超时阻断，不能算通过；Codex 内置浏览器未发现可连接的 IAB backend，原始 WebView/Windows 鼠标悬停仍待设备复测。
