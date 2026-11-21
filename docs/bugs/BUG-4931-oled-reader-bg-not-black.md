## BUG-4931 · OLED 纯黑深色下阅读器底色不是黑色
- **报告**：2026-11-21（应用内反馈 gTKeeq9mXp：「OLED Dark Mode but Reader BG is Not Black」）
- **真实性**：✅ 真 bug。`fushi/lib/src/models/fushi_reader_palette.dart:153`（修复前）阅读器「跟随主题」纸色固定取 `neutral(dark ? 6 : 98)`、漫画底 `neutral(dark ? 4 : 95)`（:205），只看 `surfaceContainer` 锚点的色相，完全不看「纯黑深色背景」开关；而开关在 `theme_notifier.dart` 里已经把 app ColorScheme 的 `surface` 压到 tone 0（`applyFushiPureBlackSurfaceLadder`）。结果外壳真黑、书页仍是 ≈ rgb(15,20,23) 的深灰。缓存键也不含 `surface`，两种方案会互相命中。
- **[x] ① 已修复** — `_buildReaderPalette` 从同一个 ColorScheme 认出纯黑（`fushiReaderSchemeIsPureBlack`：深色且 `surface` tone ≈ 0），纯黑时页面底 / VN 底板 / 漫画底取 tone 0，正文、注音、高亮的对比度循环以黑底重算；缓存键加入 `surface`。不另传开关参数，小说 / 漫画 / VN / 自定义主题预览所有调用方自动一致。
- **[x] ② 已加自动化测试** — `fushi/test/models/reader_palette_pure_black_test.dart`（纯黑深色下 palette 与 `resolveReaderThemeColors` 皆为 #000 且对比度不变式成立；普通深色 / 亮色纸色不变）。
- **备注**：未在真机肉眼复测阅读器三种 view mode（纸色经同一 palette 下发 CSS，逻辑层已覆盖）。
