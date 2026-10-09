// BUG-2957 守卫：premium 档的 [GlassContainer] 必须自带 LiquidGlassLayer。
//
// `liquid_glass_widgets` 的 premium 档在引擎支持着色器 ImageFilter（Impeller，
// 任何平台）时走 `LiquidGlass.grouped`，要从祖先 `LiquidGlassLayer` 取几何渲染
// 链接；`useOwnLayer` 缺省为 false、Fushi 又不在任何地方挂共享层，于是导航底栏
// 胶囊 / 搜索圆钮在 Android（Impeller）上构建期抛错——调试版红块、发布版一块灰色
// 矩形。Skia 后端上 premium 会降成轻量着色器，Windows（3.44 默认 Skia）看不出来，
// 所以这条边界必须靠源码扫描咬住：凡是 quality 可能是 premium 的 GlassContainer
// （`prominent:` / `GlassQuality.premium` / 由它们赋值的局部变量）都要显式写
// `useOwnLayer:`。
//
// 另一半判据：液态 → 磨砂的降级只看引擎能力（`ImageFilter.isShaderFilterSupported`），
// 不许按平台名写死——Android 可能跑 Skia（关 Impeller），桌面在 Flutter 3.47 起
// 默认 Impeller，平台名不等于渲染后端。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 返回 `GlassContainer(` 调用的实参文本（括号配平）。
List<({int line, String args})> _glassContainerCalls(String source) {
  final List<({int line, String args})> calls = <({int line, String args})>[];
  final RegExp open = RegExp(r'\bGlassContainer\(');
  for (final RegExpMatch m in open.allMatches(source)) {
    int depth = 1;
    int i = m.end;
    while (depth > 0 && i < source.length) {
      final String c = source[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      i++;
    }
    final int line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
    calls.add((line: line, args: source.substring(m.end, i - 1)));
  }
  return calls;
}

/// `quality:` 实参的完整表达式（括号配平，止于顶层逗号）；没有该实参时 null。
/// 旧写法 `[^,\n]+` 会把 `fushiGlassQuality(context, prominent: true)` 截成
/// `fushiGlassQuality(context`，内联 premium 全部漏判，守卫空转。
String? _qualityExpr(String args) {
  final RegExpMatch? m = RegExp(r'\bquality:\s*').firstMatch(args);
  if (m == null) return null;
  int depth = 0;
  int i = m.end;
  while (i < args.length) {
    final String c = args[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) break;
      depth--;
    }
    if (c == ',' && depth == 0) break;
    i++;
  }
  return args.substring(m.end, i).trim();
}

bool _mayBePremium(String qualityExpr, String source) {
  if (qualityExpr.contains('prominent') ||
      qualityExpr.contains('GlassQuality.premium')) {
    return true;
  }
  final RegExpMatch? ident = RegExp(
    r'^([A-Za-z_]\w*)$',
  ).firstMatch(qualityExpr.trim());
  if (ident == null) return false;
  // 同文件里由 prominent / premium 赋值的局部变量。
  final RegExp decl = RegExp('\\b${ident.group(1)}\\s*=\\s*([^;]*);');
  return decl
      .allMatches(source)
      .any(
        (RegExpMatch d) =>
            d.group(1)!.contains('prominent: true') ||
            d.group(1)!.contains('GlassQuality.premium'),
      );
}

void main() {
  test('premium-capable GlassContainers declare useOwnLayer', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      for (final ({int line, String args}) call in _glassContainerCalls(
        source,
      )) {
        final String? quality = _qualityExpr(call.args);
        if (quality == null) continue;
        if (!_mayBePremium(quality, source)) continue;
        if (!call.args.contains('useOwnLayer:')) {
          offenders.add('${entity.path}:${call.line}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'premium 档 GlassContainer 缺 useOwnLayer（Impeller 上构建期抛错，'
          'BUG-2957）',
    );
  });

  test('scanner sees the known premium surfaces', () {
    // 反向自检：扫描器真能认出 premium 调用点（防止正则失效后守卫空转）。
    final String nav = File(
      'lib/src/utils/adaptive/adaptive_navigation.dart',
    ).readAsStringSync();
    final int premium = _glassContainerCalls(nav).where((
      ({int line, String args}) call,
    ) {
      final String? q = _qualityExpr(call.args);
      return q != null && _mayBePremium(q, nav);
    }).length;
    expect(premium, greaterThanOrEqualTo(3));
  });

  test('liquid downgrade is judged by engine capability, not platform', () {
    final String source = File(
      'lib/src/utils/adaptive/adaptive_platform.dart',
    ).readAsStringSync();
    final int start = source.indexOf(
      'bool Function() debugShaderFilterSupported',
    );
    final int end = source.indexOf('/// 当前上下文是否走「玻璃」', start);
    expect(start, isNonNegative);
    final String body = source.substring(
      start,
      end > start ? end : source.length,
    );
    expect(body, contains('ImageFilter.isShaderFilterSupported'));
    for (final String banned in <String>[
      'TargetPlatform',
      'Platform.is',
      'defaultTargetPlatform',
    ]) {
      expect(body, isNot(contains(banned)), reason: banned);
    }
  });
}
