## BUG-184 · 安卓视频进度条贴屏幕最底(移动控制条丢失底部留白margin)
- **报告**：2026-06-11（用户：安卓端视频的进度条在最下面，而不是正常的位置）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` 的 `_mobileControlsTheme`（直接 `new MaterialVideoControlsThemeData(...)` 时未传 `seekBarMargin` / `bottomButtonBarMargin`）。
  - media_kit `MaterialVideoControlsThemeData` **构造器**默认 `seekBarMargin = EdgeInsets.zero`、`bottomButtonBarMargin = EdgeInsets.only(left:16,right:8)`（无 bottom）；与库导出常量 `kDefaultMaterialVideoControlsThemeData` 那套含 `bottom: 42` 的留白**不同**（见 pub `media_kit_video-2.0.1/.../controls/material.dart:81-93` 默认值 vs `:343-349` 构造器默认值）。
  - 移动控制条布局里 seekBar 与 bottomButtonBar 是 `Stack(alignment: bottomCenter)` 兄弟（material.dart:1025-1061），各自靠自己的 margin 从屏幕底缘抬起。本页主题没传这两个 margin → seekBar 落在 `bottom: 0` 紧贴屏幕物理最底，在 Android（edge-to-edge + 手势/导航栏）上看起来「进度条在最下面」，非控制条惯例的「按钮条同一基线、抬离底部」。
  - 视频打开走 `immersiveSticky`（`app_model.dart:2210`）隐藏导航栏，但即便隐栏，`bottom:0` 仍让进度条贴屏幕物理底缘。
- **[x] ① 已修复** — `_mobileControlsTheme` 显式设置 `seekBarMargin` / `bottomButtonBarMargin`，底部留白 = `_videoBottomChromeBaseline`(24) + `_videoBottomSystemInset()`（读 `MediaQuery.viewPadding.bottom` 的系统导航栏/手势栏 inset）。进度条与底部按钮条同一底部基线、抬离屏幕最底；唤回手势条时随 inset 上移避开。只动移动主题，桌面 `_desktopControlsTheme` 不变。提交：<填提交哈希>。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_mobile_controls_margin_test.dart`（源码扫描守卫：断言移动主题显式设 seekBarMargin/bottomButtonBarMargin + bottom 取 `bottomChromeInset`(基线+系统inset) + helper 读 `viewPadding.bottom` + 基线常量非零）。真实 MaterialVideoControls 渲染依赖 host 平台分流 + VideoController，widget 测试难稳定复现移动控制条几何，故用静态守卫。
- **备注**：真机/真模拟器复测「Android 视频进度条回到正常位置（按钮条上方、不贴屏幕最底）」待用户设备验证（CLAUDE.md 播放/布局类验证纪律）。与 BUG-180（TODO-089 字幕默认位置遮挡进度条）不同层：那个改字幕条位置，本条改进度条/按钮条自身的底部留白。
