## BUG-2723 · 插图册顶栏在手机竖屏挤爆：计数被压成 0 宽、英文等长文案整行溢出
- **报告**：2026-09-27（用户：iOS 插画侧顶部显示不全，优化 UI 并让全平台受益）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_gallery_page.dart` 的 `_buildHeader` 把标题、「已解锁 n / N」计数、过滤分段按钮、定位、关闭五样放在同一个 `Row`，且标题不可收缩。系统 inset 早已由 `SafeArea` 让开，问题在宽度：widget 测试在 iPhone 竖屏尺寸（顶部安全区 59pt）实测，英文在 375 / 390 / 430pt 都抛 `RenderFlex overflowed`、计数宽度为 0；中文 390pt 计数只剩约 65pt 被截断，320pt 溢出。节头行里的「当前阅读位置」徽标同样不可收缩，窄屏 + 长章名时溢出。
- **[x] ① 已修复** — `0858ef3918c`。标题与计数上下叠放；顶栏宽度 < 600（Material compact 宽度档）时过滤分段按钮另起一行，宽窗保持单行；`_PositionBadge` 文字可省略、在节头 / 标记条里包 `Flexible`。桌面窄窗、安卓手机同样受益。
- **[x] ② 已加自动化测试** — `0858ef3918c`，`fushi/test/reader/reader_gallery_header_bug2723_test.dart`：en / zh-CN × 320 / 375 / 390 / 430pt（带 59pt 顶部安全区）无异常、计数宽度 > 0、关闭按钮在安全区之下且不出屏、过滤按钮在第二行；800pt 宽窗过滤按钮与标题同一行。
- **备注**：未在 iOS 真机 / 模拟器上目测，依据是按 iPhone 尺寸的 widget 布局测试。
