// Fushi 语义图标层（M3 Expressive：Material Symbols Rounded）。
//
// 约定（新代码一律走这里，守卫 test/build/fushi_icons_guard_test.dart）：
// - 用语义名取图标：`FushiIcons.books`、`FushiIcons.delete`……不要再写
//   `Icons.xxx_outlined` / `Icons.xxx_rounded`——旧 Material Icons 三套变体混用正是
//   「设置页漫画图标和底栏不一致」这类问题的来源。
// - 选中 / 激活态：`FushiIcons.filled(icon)`（FILL=1 实心字族，任何只收 IconData
//   的 API 都能用），或 `FushiIcons.resolve(icon, filled: selected)`；
//   用 [FushiIcon] 渲染时也可直接传 `fill: 1`（线框字族保留了 FILL 轴，可做过渡）。
// - 渲染优先用 [FushiIcon]：它按字号自动配 opsz / 字重、暗色背景降 GRAD，并在 Apple
//   设计系统下换成同一语义的 SF 风格 CupertinoIcons（[kFushiSymbolAppleMap]）。
//   直接 `Icon(FushiIcons.x)` 也能显示正确字形，只是没有这些自适应。
// - 缺语义名就去 tool/icons/gen_fushi_symbols.py 的 SYMBOLS 表加一行重跑，
//   不要在调用点手写 `IconData(0x…, fontFamily: 'FushiSymbols')`（码位必须在字体子集里）。
import 'package:cupertino_ui/cupertino_ui.dart';

part 'fushi_icons.g.dart';

/// 线框（FILL 可变，默认 0）字族名，见 pubspec.yaml。
const String kFushiSymbolsFontFamily = 'FushiSymbols';

/// 实心（FILL=1）字族名，见 pubspec.yaml。
const String kFushiSymbolsFilledFontFamily = 'FushiSymbolsFilled';

/// [icon] 是否来自语义图标字族（线框或实心）。
bool isFushiSymbol(IconData? icon) {
  if (icon == null || icon.fontPackage != null) return false;
  return icon.fontFamily == kFushiSymbolsFontFamily ||
      icon.fontFamily == kFushiSymbolsFilledFontFamily;
}

/// 语义图标在 Apple 设计系统下的 SF 风格替身；非语义图标或无映射时返回 null。
///
/// 实心判据：字族是实心字族，或调用方显式给了 `fill >= 0.5`。
IconData? fushiSymbolAppleIcon(IconData icon, {double? fill}) {
  if (!isFushiSymbol(icon)) return null;
  final (IconData, IconData)? pair = kFushiSymbolAppleMap[icon.codePoint];
  if (pair == null) return null;
  final bool filled =
      icon.fontFamily == kFushiSymbolsFilledFontFamily || (fill ?? 0) >= 0.5;
  return filled ? pair.$2 : pair.$1;
}

/// M3 Symbols 的光学尺寸：取字号并夹在字体支持的 20..48 内。
double fushiSymbolOpticalSize(double size) => size.clamp(20.0, 48.0);

/// 按字号推荐的字重：小号图标（≤18）用 500 防发虚，常规 400，大号（≥40）300 保持
/// 笔画与正文比例（M3 Symbols 的 opsz 规范同向）。
double fushiSymbolWeight(double size) {
  if (size <= 18) return 500;
  if (size >= 40) return 300;
  return 400;
}

/// 暗色背景上的 GRAD：M3 建议浅色图标在深色底上用 -25 抵消光晕。
double fushiSymbolGrade(Brightness brightness) =>
    brightness == Brightness.dark ? -25 : 0;
