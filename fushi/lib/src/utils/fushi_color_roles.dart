// M3E 配色角色与状态层的统一入口。
//
// 颜色角色用法约定（新代码遵守；详见 scratchpad icons-colors-kit / 本文件注释）：
// - 页面底：`surface`；分区 / 卡片按层级取 `surfaceContainerLowest..Highest`
//   （列表卡片 Low、浮层菜单 Container、输入框 / 选中未激活块 High、对比最强的
//   嵌套块 Highest），不要用 `surface.withValues(alpha: …)` 或 `Color(0x…)` 自己调灰。
// - 强调色块：`primaryContainer` / `secondaryContainer` / `tertiaryContainer`
//   配各自 `on…Container` 文字；M3E 的「饱和色块」= 这三个容器，不是 primary 加透明度。
//   用 [FushiColorRoles.containerOf] / [FushiColorRoles.onContainerOf] 按 [FushiTone] 取。
// - 跨明暗恒定的强调（播放器 / 阅读器浮层上、不随主题明暗翻转的位置）：
//   `primaryFixed` / `primaryFixedDim` 与 `onPrimaryFixed(Variant)`（secondary /
//   tertiary 同理）。
// - 状态层（hover / focus / press / drag）：一律 [FushiStateLayer]，透明度不在调用点写死。
// - 禁用：内容 `onSurface` × [FushiStateLayer.disabledContent]，容器 × [FushiStateLayer.disabledContainer]。
// - 遮罩：[FushiColorRoles.modalScrim]（scrim × 0.32，M3 规范值）。
// - Apple 设计系统的表面 / 文字仍走 `FushiAppleColors`（iOS 语义色），不经本文件。
import 'package:material_ui/material_ui.dart';

/// M3 状态层透明度（Material 3 / M3E 规范值），全应用唯一来源。
abstract final class FushiStateLayer {
  /// 悬停。
  static const double hover = 0.08;

  /// 键盘 / 手柄焦点（焦点环另画，状态层只是底色提示）。
  static const double focus = 0.10;

  /// 按下。
  static const double pressed = 0.10;

  /// 拖动中。
  static const double dragged = 0.16;

  /// 成片设置列表 / 选择类控件的柔和悬停（鼠标扫过一长列时不跳）。
  static const double softHover = 0.05;

  /// 禁用态内容（文字 / 图标）透明度。
  static const double disabledContent = 0.38;

  /// 禁用态容器（填充 / 描边）透明度。
  static const double disabledContainer = 0.12;

  /// [states] 对应的状态层透明度；无交互状态时为 0。
  ///
  /// 优先级与框架一致：dragged > pressed > focused > hovered。[soft] 把悬停降到
  /// [softHover]（选择类控件 / 密集设置行）。
  static double opacityFor(Set<WidgetState> states, {bool soft = false}) {
    if (states.contains(WidgetState.disabled)) return 0;
    if (states.contains(WidgetState.dragged)) return dragged;
    if (states.contains(WidgetState.pressed)) return pressed;
    if (states.contains(WidgetState.focused)) return focus;
    if (states.contains(WidgetState.hovered)) return soft ? softHover : hover;
    return 0;
  }

  /// 以 [base]（通常是该控件的内容色，如 `onSurface` / `primary` /
  /// `onSecondaryContainer`）为色相的 overlayColor。无交互状态时为 null。
  static WidgetStateProperty<Color?> overlay(Color base, {bool soft = false}) {
    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      final double opacity = opacityFor(states, soft: soft);
      return opacity == 0 ? null : base.withValues(alpha: opacity);
    });
  }

  /// 把状态层实色合成到 [container] 上（自绘背景、不能叠 overlay 的地方用）。
  static Color composite(
    Color container,
    Color content,
    Set<WidgetState> states, {
    bool soft = false,
  }) {
    final double opacity = opacityFor(states, soft: soft);
    if (opacity == 0) return container;
    return Color.alphaBlend(content.withValues(alpha: opacity), container);
  }
}

/// 强调色族：选「哪一组」容器色块。
enum FushiTone { primary, secondary, tertiary, error, neutral }

/// [ColorScheme] 的 M3E 角色取用助手。
extension FushiColorRoles on ColorScheme {
  /// [tone] 的饱和容器色（neutral = surfaceContainerHighest）。
  Color containerOf(FushiTone tone) => switch (tone) {
    FushiTone.primary => primaryContainer,
    FushiTone.secondary => secondaryContainer,
    FushiTone.tertiary => tertiaryContainer,
    FushiTone.error => errorContainer,
    FushiTone.neutral => surfaceContainerHighest,
  };

  /// [containerOf] 上的文字 / 图标色。
  Color onContainerOf(FushiTone tone) => switch (tone) {
    FushiTone.primary => onPrimaryContainer,
    FushiTone.secondary => onSecondaryContainer,
    FushiTone.tertiary => onTertiaryContainer,
    FushiTone.error => onErrorContainer,
    FushiTone.neutral => onSurface,
  };

  /// [tone] 的实心强调色（按钮 / 进度 / 选中指示）。
  Color accentOf(FushiTone tone) => switch (tone) {
    FushiTone.primary => primary,
    FushiTone.secondary => secondary,
    FushiTone.tertiary => tertiary,
    FushiTone.error => error,
    FushiTone.neutral => onSurfaceVariant,
  };

  /// [accentOf] 上的文字 / 图标色。
  Color onAccentOf(FushiTone tone) => switch (tone) {
    FushiTone.primary => onPrimary,
    FushiTone.secondary => onSecondary,
    FushiTone.tertiary => onTertiary,
    FushiTone.error => onError,
    FushiTone.neutral => surface,
  };

  /// 模态遮罩：scrim × 0.32（M3 规范）。
  Color get modalScrim => scrim.withValues(alpha: 0.32);

  /// 禁用态内容色。
  Color get disabledContent =>
      onSurface.withValues(alpha: FushiStateLayer.disabledContent);

  /// 禁用态容器色。
  Color get disabledContainer =>
      onSurface.withValues(alpha: FushiStateLayer.disabledContainer);
}
