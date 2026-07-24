## BUG-1041 · 查词浮窗卡片左侧圆角右侧直角
- **报告**：2026-07-22（用户，附截图：app 外查词浮窗（global-lookup 瞬态窗），白卡左上角圆角正常、右上角呈直角，右缘有一条全高暗色竖条）
- **真实性**：⏳ 待 Windows 真机复现取证（截图无法定论）。卡片 chrome 由 CSS 绘制：`hibiki/assets/popup/popup.css:1386` `html.global-lookup body`（1px 边框 + border-radius 10px，四角对称），Dart 侧 `lib/src/lookup/` 无圆角逻辑——CSS 本身不产生左右不对称。三个候选根因（按嫌疑排序）：
  1. **UA 默认 body margin 未重置**（popup.css 未见 `body{margin:0}`）+ 纵向滚动条出现时 WebView2 收缩内容盒：右缘 = body margin(8px) + 滚动条 gutter（透明 html 下露桌面成暗条），卡片右圆角被 gutter 视觉挤压/覆盖。
  2. 宿主 shell（native hwnd 的 `border-radius:10px;overflow:hidden` 裁剪，见 popup.css:71-82 注释）与 WebView2 子窗宽度错位，右侧留缝。
  3. WebView2 Fluent overlay 滚动条按 `color-scheme` 画出的不透明列压过卡片右缘。
- **[ ] ① 未修复** — 复现路径：Windows 真机触发 app 外全局查词（UIA 取句），观察窗口右缘；分别验证 body margin 重置（`html.global-lookup body { margin: 8px }` 显式化并配 `scrollbar-gutter: stable`）、宿主 shell 宽度、滚动条方案。修复涉及 popup.css 时注意**三镜像纪律**（app 内 popup / 扩展 content.css 重生成）。
- **[ ] ② 未加自动化测试** — 候选：popup.css 源码守卫（body margin 显式声明）；真机截图取证留 .codex-test。
- **备注**：巡检跟进轮建档（原编号 1014→1034 均被 develop 占用[1014=Windows 安装器桌面图标守卫、1034=字幕列表行高裁剪]，合并 PR#366 时改为实时下一空号 1041）；与 BUG-1010 一起排 Windows 真机复现批次。
