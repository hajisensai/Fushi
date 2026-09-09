## BUG-2395 · 移动端底部导航栏过高未贴近底部
- **报告**：2026-09-10（用户：「移动端底部栏有点高，调正常，贴近底部」）
- **真实性**：✅ 真 bug（视觉/布局），根因
  `fushi/lib/src/utils/adaptive/adaptive_navigation.dart:133-148`（修前）：
  自绘 Material 底栏是 `Material > SafeArea(top: false) > SizedBox(height: 80) > Row`，
  这里的 **80 是内容区固定高**，外层 `SafeArea` 再把系统底部 inset **叠加**上去：
  - MD3 标称的 navigation bar 容器就是 80dp（含底部留白），这里等于在 80 之外又加了一份
    手势条高度 → Pixel 7 类设备（inset 24dp）实测总高 **104dp**。
  - tile 内在高只有 52dp（指示药丸 32 + 间距 4 + labelSmall 一行 16，
    `adaptive_navigation.dart:270-300`），在 80dp 里垂直居中 → 上下各空 14dp；
    叠上 24dp 手势区后，**标签底边离屏幕底 38dp**，视觉上整条栏「浮」在底部上方
    而不是贴住底部。
  - 数字来自 widget 探针（`MediaQueryData(size: 411.4x914.3, dpr 2.625,
    viewPadding.bottom: 24)`）：`bar.height=104`、`bar.bottom - label.bottom=38`、
    `icon.top - bar.top=18`。
  另注：底栏高度是裸字面量，而同文件的侧栏宽度有单一真相源常量
  `kAdaptiveNavRailWidth`（`:304`）——本次顺带补上对称的高度常量。
- **[x] ① 已修复** — 本提交 `fushi/lib/src/utils/adaptive/adaptive_navigation.dart`：
  - 内容区高度 80 → `kAdaptiveNavBarContentHeight = 64`（tile 52 + 上下各
    `kAdaptiveNavBarContentPadding = 6`），系统 inset 仍由 `SafeArea` 单独让出，
    于是总高 = 64 + inset（inset 24 时 **88dp**，比原来矮 16dp），
    标签底边离屏幕底 = 6 + inset = **30dp**（原 38dp），内容真正贴住手势区上沿。
  - 固定 `SizedBox` 换成 `ConstrainedBox(minHeight:)` + 内边距 + `IntrinsicHeight`：
    内容比 64 高时（大字号）底栏**自然长高**而不是 RenderFlex 溢出——旧实现靠 80 的
    富余空间掩盖，压到 64 后必须显式处理。`IntrinsicHeight` 是这里的必需项而非装饰：
    每个 tile 里有 `Center`（`adaptive_navigation.dart:_NavFocusCell`），松约束下它会
    吃满可用高度——只把 `SizedBox` 换成 `ConstrainedBox` 会让底栏**撑满整屏**
    （实测 914dp），旧的 tight 高度恰好掩盖了这个依赖。
  - 同时按 stock `NavigationBar` 的做法把文字缩放 clamp 到 1.3
    （`MediaQuery.withClampedTextScaling`），避免系统超大字号把底栏顶到半屏高。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/adaptive_nav_bar_height_test.dart`（本提交）：
  无 inset 时 bar 高 = 64；inset 24 时 bar 高 = 88 且标签底边到 bar 底边 = 6 + 24；
  textScale 2.0 时 bar 按内容长高、`takeException()` 为 null（不溢出）。
  三条在修前实现上均红（旧实现分别是 80 / 104 / 38）。
- **验证**（判绿只认退出码）：
  - **Android 模拟器实测**（Pixel 7 规格 AVD：1080x2400 @420dpi、Android 15 手势导航，
    debug APK `--target-platform android-x64`）：装修前 APK 走原始路径（跳过引导 → 首页）
    截屏，改完重建再截，同位置裁剪并排对比 —— 整条栏下移约 17dp，标签与手势条之间的
    空白肉眼可见地收紧。修前/修后截图与对比图见本机 job tmp（不入库）。
  - widget 探针（同一 MediaQuery 参数）修前 `bar.height=104 / gap=38`，
    修后 `88 / 30`，与设计值一致。
  - `flutter test test/widgets/material_nav_focus_test.dart test/pages/adaptive_nav_rail_overflow_test.dart
    test/pages/home_mobile_nav_traversal_guard_test.dart test/pages/video_experimental_markers_guard_test.dart
    test/focus` → 99 例全绿，exit=0（底栏逐项焦点、Enter 激活、label 可 tap、rail 不溢出、
    mobile layout 源码守卫都没被这次改动碰坏）。
  - `flutter analyze`（fushi，含 test / integration_test）→ No issues found。
- **备注**：底栏唯一生产调用点是 `home_page.dart:1383` 的 `_buildMobileLayout()`，
  只在 compact（真实宽 < 600dp）布局启用，桌面侧栏（`adaptiveNavRail`）不受影响；
  iOS/Cupertino 分支走 stock `CupertinoTabBar`，也不在改动面内。
