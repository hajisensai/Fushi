import 'package:material_ui/material_ui.dart';

/// [MaterialApp] 在 [themeMode] / 平台明暗下**最终落定**的主题（不含交叉过渡）。
///
/// MaterialApp 的 `builder` 挂在 AnimatedTheme 之下，主题切换的 280ms 过渡里
/// `Theme.of(context)` 每帧都是一份插值出来的过渡主题。需要「目标主题」的副作用
/// （推给原生窗口的标题栏 / 窗口底色、系统材质明暗）必须读这里：读插值主题会让
/// 每一帧都下发一组新颜色，Windows runner 每次都整窗重铺底色，切主题 / 切深色时
/// 整页连闪（2026-10-09 用户反馈）。
ThemeData fushiSettledTheme({
  required ThemeMode themeMode,
  required Brightness platformBrightness,
  required ThemeData light,
  required ThemeData dark,
}) {
  return switch (themeMode) {
    ThemeMode.light => light,
    ThemeMode.dark => dark,
    ThemeMode.system => platformBrightness == Brightness.dark ? dark : light,
  };
}
