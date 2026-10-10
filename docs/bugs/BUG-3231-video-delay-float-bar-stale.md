## BUG-3231 · 视频调轴浮条开着时快捷键改延迟，读数不跟且 ± 以旧值覆盖
- **报告**：2026-10-10（PR #2028 审查遗留疑点）
- **真实性**：✅ 真 bug（代码路径确认）。`fushi/lib/src/media/video/video_subtitle_sync_row.dart:53` 的 `_delayMs` 是打开时取一次的本地镜像，只由本行内入口经 `_commitDelay` 更新；± 步进以镜像为基数。浮条（`video_fushi/layout.part.dart` `_buildSubtitleDelayBar`）开着时 z/x / Ctrl+Shift+←/→ 仍走页面 `_setDelayMs`（`video_fushi_page.dart:9488`），它只发 OSD（`_osdNotifier`，不重建页面），浮条读数停在旧值；再点 ± 以旧值 ±50 写穿，把快捷键的调整覆盖掉。
- **[x] ① 已修复** — `_VideoSubtitleSyncRowState` 挂上 `host.subtitlePositionListenable`（controller，`setDelayMs` 立即 notify）并在 `didUpdateWidget` 里经 `_syncDelayFromHost` 把镜像 / 读数 / 输入框拉回页面权威值；± 步进改为 `_stepDelay`，以 `host.delayMs()` 为基数。提交见 `fix(video): keep subtitle delay row in sync with shortcut changes`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_delay_float_bar_test.dart`「float bar follows delay changed outside the row (shortcuts)」（widget 测试：外部改值后读数跟随、± 以新值为基数）。
- **备注**：
