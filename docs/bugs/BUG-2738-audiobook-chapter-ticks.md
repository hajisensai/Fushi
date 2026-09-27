## BUG-2738 · 阅读器有声书面板进度条章节刻度与进度不对齐
- **报告**：2026-09-27（用户：阅读器的有声书的播放进度条章节没对齐进度条）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_audiobook_panel.dart` 的全书进度条下方，章节刻度是另起的一条 `CustomPaint`，左右硬写 `EdgeInsets.symmetric(horizontal: 24)`；而 slider 轨道内缩是 `max(overlayWidth, thumbWidth) / 2`（Flutter `BaseSliderTrackShape.getPreferredRect`），本面板 `overlayRadius: 12` → 12px。刻度坐标系比轨道窄 24px、整体往中间压，离两端越远偏得越多，拇指走到章首时与刻度错开。
- **[x] ① 已修复** — `63c42c2f33c`：刻度改由 `ReaderAudiobookChapterTrackShape`（包默认 `RoundedRectSliderTrackShape`）画在 slider 自己的 trackRect 上，x 与非离散 slider 拇指中心同一公式 `trackRect.left + f * trackRect.width`（RTL 镜像），任何内缩变化下都对齐。同一提交顺带按用户要求把手机端有声书面板从底部抽屉改为与桌面同一条右侧侧栏（删 `readerAudiobookUsesSideSheet`）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audiobook_panel_test.dart`「章节刻度与拇指对齐」（fraction 0.1 / 0.5 / 0.9：paints 断言刻度线与拇指圆心同一 x，并钉住轨道内缩 12px）；路由守卫 `fushi/test/media/audiobook/reader_quick_settings_sheet_static_test.dart`（有声书面板不再走 `adaptiveModalSheet`）。
- **备注**：未真机复测。
