## BUG-881 · 捕获工作台查词 WebView 重建后空白卡死
- **报告**：2026-07-20（用户：）
- **真实性**：✅ 真 bug。冷查词期间 `Stack` 同时包含加载占位和隐藏的弹窗层；结果就绪后占位被移除，未带 key 的两个顶层 `Positioned` 按槽位更新，导致旧槽位里的 Windows WebView 平台视图被销毁，只留下空白弹窗外壳（`hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart:572`、`hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart:269`）。
- **[x] ① 已修复** — `parkedPopupLayer` 接收并透传 key，调用处用 `ObjectKey(entry)` 固定整层身份；加载占位消失时 Flutter 搬移既有元素，不再拆建 WebView 原生表面。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/dictionary_page_mixin_warm_slot_test.dart` 覆盖冷查词占位移除前后：断言弹窗层 `Element` 与 WebView `State` 均保持同一实例；修复前红、修复后绿。
- **备注**：Windows Debug 实机重新附着运行中的 9-nine（PID 44132），点击“ 大丈夫 ”后词典正文正常显示并驻留 12 秒。`wgc_capture.log` 同期记录 `create-bridge → set-size → frame-first-success`，未再出现复现时约 6 秒后的 `cpv-dtor`。本提交另通过 4 个相关测试文件（16 tests）及目标文件 `dart analyze`。
