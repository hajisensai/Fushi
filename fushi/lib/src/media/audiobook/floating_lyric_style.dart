import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart'
    show GalHookToolbarPalette, galHookToolbarPalette, galHookToolbarThemeArgs;
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show FloatingLyricStyle;
import 'package:fushi/src/models/preferences_repository.dart';

/// 悬浮字幕的用户设置快照（全部来自偏好，纯数据）。
///
/// 两个样式构造点（app 级 `_appLevelFloatingLyricStyle` / reader 级
/// `_readerFloatingLyricStyle`）读同一份快照、走同一个 [buildFloatingLyricStyle]，
/// 保证「同一个设置，两处一致」——差别只剩配色取自哪套主题明暗。
class FloatingLyricStyleSettings {
  const FloatingLyricStyleSettings({
    required this.fontSize,
    required this.textOpacity,
    required this.buttonBgOpacity,
    required this.bgOpacity,
    required this.cornerRadius,
    required this.windowWidth,
    this.bold = true,
    this.vertical = false,
    this.lineHeight = PreferencesRepository.floatingLyricLineHeightDefault,
    this.letterSpacing = 0,
    this.outlineWidth = 0,
    this.textAlignment = 0,
    this.textPadding = PreferencesRepository.floatingLyricTextPaddingDefault,
    this.contextOpacity =
        PreferencesRepository.floatingLyricContextOpacityDefault,
    this.colors = const <FloatingLyricColorRole, int>{},
    this.fontFamily = '',
    this.fontPath,
  });

  factory FloatingLyricStyleSettings.fromPreferences(
    PreferencesRepository prefs, {
    double? fontSize,
    ({String family, String? path})? font,
  }) {
    return FloatingLyricStyleSettings(
      fontSize: fontSize ?? prefs.floatingLyricFontSize,
      textOpacity: prefs.floatingLyricTextOpacity,
      buttonBgOpacity: prefs.floatingLyricButtonBgOpacity,
      bgOpacity: prefs.floatingLyricBgOpacity,
      cornerRadius: prefs.floatingLyricCornerRadius,
      windowWidth: prefs.floatingLyricWidth,
      bold: prefs.floatingLyricBold,
      vertical: prefs.floatingLyricVertical,
      lineHeight: prefs.floatingLyricLineHeight,
      letterSpacing: prefs.floatingLyricLetterSpacing,
      outlineWidth: prefs.floatingLyricOutlineWidth,
      textAlignment: prefs.floatingLyricTextAlignment,
      textPadding: prefs.floatingLyricTextPadding,
      contextOpacity: prefs.floatingLyricContextOpacity,
      colors: <FloatingLyricColorRole, int>{
        for (final FloatingLyricColorRole role in FloatingLyricColorRole.values)
          role: prefs.floatingLyricColor(role),
      },
      fontFamily: font?.family ?? '',
      fontPath: font?.path,
    );
  }

  final double fontSize;
  final int textOpacity;
  final int buttonBgOpacity;
  final int bgOpacity;
  final int cornerRadius;
  final int windowWidth;
  final bool bold;
  final bool vertical;
  final double lineHeight;
  final double letterSpacing;
  final double outlineWidth;
  final int textAlignment;
  final int textPadding;
  final int contextOpacity;
  final Map<FloatingLyricColorRole, int> colors;
  final String fontFamily;
  final String? fontPath;

  /// [role] 的用户自选色；null = 跟随主题（含 map 里缺这一项）。0 是合法的
  /// 完全透明黑，不是跟随主题。
  int? customColor(FloatingLyricColorRole role) {
    final int stored =
        colors[role] ?? PreferencesRepository.floatingLyricColorFollowTheme;
    return stored == PreferencesRepository.floatingLyricColorFollowTheme
        ? null
        : stored;
  }
}

/// 「跟随主题」时四种颜色的 M3E 配对色（不含透明度缩放）。
///
/// 底 = `surfaceContainerHigh`（M3E 浮层容器），字 = `onSurface`，当前句 =
/// `primary`（与歌词模式当前行同一强调色），描边 = 底色 0xE0（描边宽 > 0 时
/// 读作一圈与底同色的光晕，底板调透明时字也读得出）。设置页色样也走它，保证
/// 「设置页看到的颜色 = 浮窗实际画出的颜色」。
int floatingLyricThemeColor(ColorScheme scheme, FloatingLyricColorRole role) {
  int opaque(Color color) => 0xFF000000 | (color.toARGB32() & 0x00FFFFFF);
  return switch (role) {
    FloatingLyricColorRole.background => opaque(scheme.surfaceContainerHigh),
    FloatingLyricColorRole.text => opaque(scheme.onSurface),
    FloatingLyricColorRole.current => opaque(scheme.primary),
    FloatingLyricColorRole.outline =>
      0xE0000000 | (scheme.surfaceContainerHigh.toARGB32() & 0x00FFFFFF),
  };
}

/// 由设置快照 + 主题构造悬浮字幕样式（M3E）。context-free：调用方按明暗传
/// `appModel.theme` / `appModel.darkTheme`（经单一主题工厂成型，墨水屏 / Apple
/// 配色都在里面），不触碰 `Theme.of`。
FloatingLyricStyle buildFloatingLyricStyle({
  required ThemeData theme,
  required FloatingLyricStyleSettings settings,
}) {
  final ColorScheme scheme = theme.colorScheme;
  int resolve(FloatingLyricColorRole role) =>
      settings.customColor(role) ?? floatingLyricThemeColor(scheme, role);

  final int text = resolve(FloatingLyricColorRole.text);
  final int current = resolve(FloatingLyricColorRole.current);
  final int background = resolve(FloatingLyricColorRole.background);
  final int outline = resolve(FloatingLyricColorRole.outline);
  final int textColor = FloatingLyricStyle.scaleAlpha(
    text,
    settings.textOpacity,
  );
  // 工具条沿用 galgame 台词浮窗的 M3E 浮动工具条配色（同一个原生窗类、同一套
  // 槽位渲染），两种浮窗的工具条长得一样。
  final GalHookToolbarPalette palette = galHookToolbarPalette(
    theme,
    textColor: textColor,
  );
  return FloatingLyricStyle(
    fontSize: settings.fontSize,
    textColor: textColor,
    // TODO-576: 条背景透明度按设置缩放 alpha（默认 70=更不挡视野）。
    bgColor: FloatingLyricStyle.scaleAlpha(background, settings.bgOpacity),
    // Android 的按钮是 TextView 自绘，吃这两色；Windows 工具条吃 toolbarArgs。
    buttonTextColor: scheme.onSecondaryContainer.toARGB32(),
    buttonBgColor: FloatingLyricStyle.scaleAlpha(
      0xFF000000 | (scheme.secondaryContainer.toARGB32() & 0x00FFFFFF),
      settings.buttonBgOpacity,
    ),
    highlightColor: palette.highlightColor,
    activeColor: 0xFF000000 | (scheme.primary.toARGB32() & 0x00FFFFFF),
    cornerRadius: settings.cornerRadius,
    windowWidth: settings.windowWidth,
    fontFamily: settings.fontFamily,
    fontPath: settings.fontPath,
    bold: settings.bold,
    verticalText: settings.vertical,
    lineHeight: settings.lineHeight,
    letterSpacing: settings.letterSpacing,
    textAlignment: settings.textAlignment,
    textPadding: settings.textPadding.toDouble(),
    outlineColor: outline,
    outlineWidth: settings.outlineWidth,
    currentLineColor: FloatingLyricStyle.scaleAlpha(
      current,
      settings.textOpacity,
    ),
    contextLineOpacity: settings.contextOpacity / 100.0,
    toolbarArgs: galHookToolbarThemeArgs(palette),
  );
}
