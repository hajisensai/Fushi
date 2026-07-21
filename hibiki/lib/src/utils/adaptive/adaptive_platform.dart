import 'dart:io' show Platform;

import 'package:flutter/material.dart';

enum HibikiDesignSystem { auto, material, cupertino, macos }

/// macOS 标准标题栏高度（逻辑像素）。`main.dart` 无条件启用透明标题栏 +
/// full-size content view（macos_ui ToolBar 的硬性前提），Flutter 内容会整块
/// 延伸到红黄绿交通灯按钮下方；而 macOS full-size content view 下 embedder 不把
/// 交通灯上报为 `MediaQuery.padding.top`（上报 0），所以普通 `SafeArea` 挡不住。
/// Material 桌面壳需要用它给 `SafeArea.minimum` 预留顶部内边距，让交通灯落在这条
/// 保留带里、不再压住导航 rail / 返回按钮（BUG-869）。交通灯直径 12pt、约在
/// y=[6,18]，28pt 足以完全让位。macos_ui 原生壳由 MacosWindow 自处理让位，不用它。
const double kMacTitleBarHeight = 28.0;

@immutable
class HibikiDesignSystemTheme extends ThemeExtension<HibikiDesignSystemTheme> {
  const HibikiDesignSystemTheme(this.designSystem);

  final HibikiDesignSystem designSystem;

  @override
  HibikiDesignSystemTheme copyWith({HibikiDesignSystem? designSystem}) {
    return HibikiDesignSystemTheme(designSystem ?? this.designSystem);
  }

  @override
  HibikiDesignSystemTheme lerp(
    covariant ThemeExtension<HibikiDesignSystemTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// 墨水屏模式标志的 ThemeExtension 载体。挂在 ThemeNotifier._buildThemeData 的
/// extensions 里，使任意 widget 可经 `Theme.of(context)` 感知 eink（用于把入场
/// 淡入/滑出等 Flutter 侧动画时长归零），零新增数据流、随主题重建自动更新。
@immutable
class HibikiEinkTheme extends ThemeExtension<HibikiEinkTheme> {
  const HibikiEinkTheme(this.einkMode);

  final bool einkMode;

  @override
  HibikiEinkTheme copyWith({bool? einkMode}) {
    return HibikiEinkTheme(einkMode ?? this.einkMode);
  }

  @override
  HibikiEinkTheme lerp(
    covariant ThemeExtension<HibikiEinkTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// True 当墨水屏模式开启（读不到扩展时为 false，测试裸 ThemeData 零破坏）。
bool isEinkTheme(BuildContext context) {
  return Theme.of(context).extension<HibikiEinkTheme>()?.einkMode ?? false;
}

bool isCupertinoPlatform(BuildContext context) {
  final HibikiDesignSystem designSystem =
      Theme.of(context).extension<HibikiDesignSystemTheme>()?.designSystem ??
          HibikiDesignSystem.auto;
  switch (designSystem) {
    case HibikiDesignSystem.material:
      return false;
    case HibikiDesignSystem.cupertino:
      return true;
    case HibikiDesignSystem.macos:
      // Explicit macOS-native design system is NOT Cupertino. The macos_ui shell
      // and converted pages route via [isMacosPlatform]; this keeps the two
      // skins from both claiming the same surface.
      return false;
    case HibikiDesignSystem.auto:
      return false;
  }
}

/// True when the macOS-native (macos_ui) design system should drive this
/// subtree. Converted shells/pages branch on this BEFORE
/// [isCupertinoPlatform].
bool isMacosPlatform(BuildContext context) {
  final HibikiDesignSystem designSystem =
      Theme.of(context).extension<HibikiDesignSystemTheme>()?.designSystem ??
          HibikiDesignSystem.auto;
  switch (designSystem) {
    case HibikiDesignSystem.material:
    case HibikiDesignSystem.cupertino:
      return false;
    case HibikiDesignSystem.macos:
      // Explicitly selecting the macOS-native design system only routes into the
      // macos_ui / MacosWindow shell when actually running on macOS; on other
      // hosts WindowManipulator is unavailable, so fall back to the platform
      // default rather than crash. (Quality point ②)
      return Platform.isMacOS;
    case HibikiDesignSystem.auto:
      return false;
  }
}
