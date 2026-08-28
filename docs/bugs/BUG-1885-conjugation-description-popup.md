## BUG-1885 · 动词变形说明弹窗样式异常且跨查询残留
- **报告**：2026-08-27（用户截图：点击「-ている」变形标签后，说明以半透明贴底层覆盖词典；不点 X 就继续残留到下一次查词）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.js` 的 `showDescription()` 把说明写入 `popup.html` 中位于 `#entries-container` 外的 `.overlay`；`renderPopup()` 每轮只重建结果容器，从未关闭该 overlay，因此旧说明不属于任何查询 generation，必然跨查询残留。`fushi/assets/popup/popup.css` 又把它定义成 `bottom: 0; width: 100%; background: var(--surface-container-high)` 的半透明 bottom sheet，与正常查词卡片表面不一致。
- **[x] ① 已修复** — 变形说明改为带变形标题、正常查词底色/边框/圆角/阴影的内嵌弹窗卡片；`renderPopup()` 和复用 WebView realm 前均显式关闭并清空说明及 hover tooltip，使说明生命周期绑定当前查询 generation。实现提交 `f1bea1e9de`。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` 走真实 `showDescription()` → `renderPopup()` 行为，断言标题/正文呈现、新查询关闭清空，并守住非贴底半透明层的 popup-card CSS；`fushi/test/dictionary/popup_conjugation_description_guard_test.dart` 将同一生命周期和视觉契约纳入 Flutter 全量测试扫描面。
- **备注**：popup.js / popup.html / popup.css 已同步两份浏览器扩展 vendor 镜像并重建 scoped `content.css`。JS 行为测试、镜像检查、bug strict gate、`flutter analyze --no-pub` 已通过；Flutter/Dart 定向测试在零用例阶段被 `pdfium_dart` 下载 `pdfium-win-x64.tgz` 的 Windows socket 121 超时阻断。Codex 内置本地浏览器也未发现可连接的 IAB backend，故未做渲染截图；Windows 真机原截图路径仍待复测最终观感。
