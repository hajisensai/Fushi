## BUG-4080 · 浅色跟随主题下阅读器查词选区高亮几乎看不出来
- **报告**：2026-11-04（应用内反馈 lIWk_4rGA4，Android，粉色系跟随主题、竖排）
- **真实性**：✅ 真 bug。查词高亮色由 `_buildReaderPalette`（`fushi/lib/src/models/fushi_reader_palette.dart`，修前 `:177-182`）派生：亮色取 primaryContainer tone 90 @0.75，纸色是 neutral tone 98（修前 `:154`）。tone 90 对 98 的明度差很小，合成后与纸色的对比度只有约 1.15:1；`_readableHighlight`（修前 `:240-255`）只设上限（合成后正文 ≥ 4.5:1，不够就降 α），没有「高亮与纸色至少差多少」的下限。当前句高亮（tertiaryContainer 90 @0.65）同一缺口。
- **[x] ① 已修复** — 新增可见性下限 `kFushiReaderHighlightMinVisibility`（1.3:1）与 `_visibleHighlight`：查词 / 当前句高亮从原 tone 起，合成后与纸色对比不够就往正文一侧挪 tone（亮色往深、暗色往浅，最多挪到 tone 40 / 60），每一档都经 `_readableHighlight` 保住正文 ≥ 4.5:1。默认青色等本来就够的种子色不变。提交见下。
- **[x] ② 已加自动化测试** — `fushi/test/models/reader_palette_highlight_visibility_test.dart`：粉 / 浅粉 / 黄 / 浅黄 / 青 / 紫 / 灰 × tonalSpot / vibrant / content / fidelity × 亮暗，断言查词与当前句高亮合成后与纸色 ≥ 1.3:1、正文在高亮上 ≥ 4.5:1。
- **备注**：`reader_content_styles.dart` 把选区色按纸色预合成成不透明色（BUG-125），页面铺带色渐变背景时高亮与实际背景的差会再小一点，本轮未处理。paginated / continuous / vn 三种视图模式的肉眼复测未做（本轮不做真机验证）。
