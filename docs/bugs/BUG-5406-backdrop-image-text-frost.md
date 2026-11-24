## BUG-5406 · backdrop-image-text-frost
- **报告**：2026-11-24（用户：「自定义了背景，然后文字后面没有描边或者说毛玻璃，导致看不清」；拍板「统一处理、毛玻璃底」）
- **真实性**：✅ 真 bug。背景层选「自定义图片」时 `FushiPageBackdrop`（`fushi/lib/src/utils/adaptive/fushi_page_backdrop.dart:131`）把页底换成透明，文字直接压在图上；只有设置页侧栏与分组标题（`settings_home_page.dart:723`、`settings_shared.dart:_Md3SegmentedTitle`）按 `FushiPageBackdrop.imageOf` 垫了底，其余公共组件——分区标题 `FushiSectionTitle`、空状态 `FushiPlaceholderMessage`、书架书名、页头大字底板 `FushiMastheadPanel`（未滚动 p = 0 时不画）——都没有。
- **[x] ① 已修复** — 新增全应用统一的 `FushiBackdropFrost` / `FushiBackdropFrostPlate`（`fushi/lib/src/utils/components/fushi_backdrop_frost.dart`）：只在 `imageOf` 为真且非墨水屏时画，页面底色 55% + sigma 14 的 `BackdropFilter.grouped`，降低透明度 / 增强对比度下退成 90% 实底；底板外扩、只画不占位（`StackFit.passthrough`），切换预设版面不动。接入分区标题（标题与行尾各一枚）、空状态（MD3 / Apple）、书架书名、设置分组标题（替换原同色胶囊）；页头底板在图片背景下进度下限 0.6，未滚动也常驻毛玻璃。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_backdrop_frost_test.dart`（只在图片背景画、版面不动、空状态与页头底板接上）；`settings_wallpaper_title_pill_test.dart` 改为认统一底板。
- **备注**：页面里手写、直接压在页底上的零散 `Text`（不走上述公共组件的）未逐页包，后续发现按页包一层 `FushiBackdropFrost`。
