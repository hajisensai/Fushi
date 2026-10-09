## BUG-3096 · 安卓展开词典先闪一下蓝光
- **报告**：2026-10-09（用户 PDF 第 5 页第 10 条：安卓设备展开词典时会先闪一下蓝光再展开）
- **真实性**：✅ 真 bug（按代码与引擎行为判定，未在真机录屏复核）。根因：Android 的 Chromium WebView 给可点元素按下时画默认 tap highlight（半透明蓝色块），词典卡标题行 `<summary class="dict-label">` 是可点元素，而 `fushi/assets/popup/popup.css` 只给个别按钮设了 `-webkit-tap-highlight-color: transparent`，`summary` / 链接没设。与展开动画无关。
- **[x] ① 已修复** — popup.css 在 `html` 上设 `-webkit-tap-highlight-color: transparent`（可继承，全文档生效；扩展生成器重根到容器，不外溢宿主页）。展开动画（`::details-content` 高度 spring）按用户确认另行移除，改为即时展开，两者独立。提交见 PR `pr/dict-popup-style`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_style_1009_guard_test.dart`（根上透明 tap highlight；无 `::details-content` / `interpolate-size`）。
- **备注**：Android 真机未复测。
