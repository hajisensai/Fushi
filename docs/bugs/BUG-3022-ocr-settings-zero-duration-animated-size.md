## BUG-3022 · 漫画 OCR 设置在减弱动态效果下 AnimatedSize 零时长断言
- **报告**：2026-10-06（PR #1984 CI：`fushi/test/media/manga/manga_ocr_settings_section_ui_test.dart` 9 条红）
- **真实性**：✅ 真 bug。M3E wave 1 在 `fushi/lib/src/media/manga/manga_ocr_settings_section.dart` 的模型区折叠（`_buildPanelModelArea` 外层）、模型卡（`manga_ocr_model_card`）、外部服务探测结果三处包了 `AnimatedSize`，时长取 `fushiMotion` / `fushiMotionDuration`，在「减弱动态效果」/ 墨水屏下归零。Flutter 3.47.6 `RenderAnimatedSize._restartAnimation` 在零时长下 `forward(from: 0)` 同步跳到 1.0，监听器在自身 `performLayout` 内 `markNeedsLayout`，debug 下断言「A RenderAnimatedSize was mutated in its own performLayout」；子尺寸每变一次（下载进度、引擎切换、探测结果出现）就炸一次。release 下断言关闭、最终几何恰好正确，所以只在 debug / 测试可见。
- **[x] ① 已修复** — `e5359558a0a`：私有 `_MotionSize` 在时长为零时直接给最终几何，否则才用 `AnimatedSize`。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_ocr_settings_section_ui_test.dart` 宿主统一开 `disableAnimations`，原 9 条（下载进度 / 引擎切换 / 探测结果 / 删除门控 / BUG-1780）即覆盖零时长路径，修复后 30/30 绿。
- **备注**：仓库其他文件仍有 `AnimatedSize(duration: motion...duration)` 同型写法（如 `asr_models_settings_section.dart`、`download_task_card.dart`），超出本任务范围未改；若要收口应在共享组件层提供零时长安全的 AnimatedSize。
