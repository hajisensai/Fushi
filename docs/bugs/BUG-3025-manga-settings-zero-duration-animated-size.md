## BUG-3025 · 漫画阅读设置面板减弱动效下切换作用域断言 RenderAnimatedSize
- **报告**：2026-10-06（agent：修 PR #1984 漫画阅读页测试时排查 RenderAnimatedSize 断言，沿同源线索 BUG-3022 发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/reader/manga_reader_settings_sheet.dart` 作用域条（`manga_reader_scope` 右侧「重置」槽）的 `AnimatedSize` 时长取 `fushiMotionDuration(context, FushiMotion.medium)`，系统「减弱动态效果」/ 墨水屏下归零；切换「本作 / 全局」时子尺寸变化，零时长 `RenderAnimatedSize` 在自身 performLayout 里同步跳到终点并 `markNeedsLayout`，debug 下断言「A RenderAnimatedSize was mutated in its own performLayout implementation」（Flutter 3.47.6 实测复现）。与 BUG-3022（OCR 设置页）同一机制；PR #1984 CI 上那条同名报错来自下载任务面板（`unified_download_jobs_panel_test.dart`），不是本处。
- **[x] ① 已修复** — 同文件私有 `_MotionSize`：时长为零直接给最终几何，否则仍是 `AnimatedSize`（提交 `fix(manga-reader): skip zero-duration AnimatedSize in settings scope bar (BUG-3025)`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reader_settings_reduce_motion_test.dart`（`disableAnimations: true` 下来回切作用域，断言无异常且重置按钮随作用域显隐）。
- **备注**：未改 `lib/src/widgets/**` 共享组件；其它用 `fushiMotionDuration` 驱动 `AnimatedSize` 的位置（如 `lib/src/media/downloads/download_task_card.dart`）可能同源，未在本条处理。
