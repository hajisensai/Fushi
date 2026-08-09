import 'package:flutter/material.dart';

/// 播放器 chrome 的固定亮色前景体系 + 浮层表面 alpha 两档（UI 巡检 PR-4）。
///
/// **播放器表面是固定深色 OSD 体系，不随 colorScheme**：media_kit 控制条压在
/// fork 内固定深色 scrim 上（third_party/media_kit_video `material_desktop.dart`
/// 的 0x61000000 / `material.dart` 的 0x66000000），chrome 前景（顶栏标题、底栏
/// 时间、进度条、按钮、侧浮条图标、章节刻度）若跟随主题的 `cs.primary` /
/// `cs.onSurface`，浅色 / eink 主题下取到的是深色前景 → 压在深色 scrim 上
/// 黑压黑不可读。故前景收敛到本文件的固定亮色，深色主题下取值与旧实现一致
/// （深色主题的 `cs.primary` 本就是亮 tone），视觉不变。
///
/// 注意边界：带**自有表面**的 chrome（侧边锁按钮的 surface 圆底、各 push-aside
/// 侧栏、popover 面板）仍按主题 surface/onSurface 自配对——它们不裸压 scrim，
/// 对比度由自身表面保证，不属于本体系。

/// chrome 中性前景（标题 / 时间文本 / 章节刻度）：固定近白。
const Color videoChromeNeutralForeground = Colors.white;

/// chrome 强调色（按钮 / 进度条 / 滑块）：恒取「亮 tone」的 primary。
///
/// 深色主题的 [ColorScheme.primary] 即亮 tone（MD3 fromSeed tone 80）；浅色主题
/// 取同一 seed 的 [ColorScheme.inversePrimary]（同为 tone 80）——两个主题下是
/// 同一支亮色，深色主题视觉与旧实现（cs.primary）完全一致。eink 浅色方案的
/// inversePrimary 为纯白（见 buildEinkColorScheme），在深色 scrim 上仍可读。
Color videoChromeAccentColor(ColorScheme cs) =>
    cs.brightness == Brightness.dark ? cs.primary : cs.inversePrimary;

/// 视频浮层表面 alpha 收敛为两档（此前 0.55 / 0.78 / 0.92 / 0.94 四档并存）。
///
/// 实底档：承载列表 / 滑条等密集内容的浮层（控制条 popover、剧集侧栏面板），
/// 近实底保证行文本可读。
const double kVideoOverlaySolidAlpha = 0.94;

/// 半透明档：允许画面透出的侧栏 / 独立浮钮（设置等 push-aside 半透明侧栏、
/// 侧边锁按钮圆底）。
const double kVideoOverlayTranslucentAlpha = 0.78;
