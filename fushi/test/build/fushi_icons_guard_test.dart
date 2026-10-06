import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// M3E 语义图标层守卫（2026-10-05「图标和配色也统一成 m3e」）。
///
/// 1. 映射层自洽：语义名唯一、实心版都在实心字族、Apple 设计系统每个语义名都有
///    SF 风格替身（线框 / 实心各一）。
/// 2. 已迁移的面（顶层导航、设置分类图标）只用语义图标——「设置页漫画图标和底栏
///    不一致」这类问题的根是同一概念散落多个 `Icons.*` 变体。
/// 3. 渐进迁移棘轮：`lib/` 下直接写 `Icons.xxx` 的次数按文件封顶在
///    `fushi_icons_legacy_allowlist.json`（生成于迁移起点）。新文件不许出现
///    `Icons.*`；存量文件只能减不能增。迁完一个文件就把它的计数调低 / 删掉。
///    确需新增语义名：改 `tool/icons/gen_fushi_symbols.py` 的 SYMBOLS 表重跑。
void main() {
  group('映射层', () {
    test('语义名与码位：线框字族、无重复名、实心版落在实心字族', () {
      expect(FushiIcons.all, isNotEmpty);
      for (final MapEntry<String, IconData> e in FushiIcons.all.entries) {
        expect(e.value.fontFamily, kFushiSymbolsFontFamily, reason: e.key);
        expect(isFushiSymbol(e.value), isTrue, reason: e.key);
        final IconData filled = FushiIcons.filled(e.value);
        expect(filled.fontFamily, kFushiSymbolsFilledFontFamily, reason: e.key);
        expect(filled.codePoint, e.value.codePoint, reason: e.key);
        expect(FushiIcons.resolve(e.value, filled: false), e.value);
        expect(FushiIcons.resolve(e.value, filled: true), filled);
      }
    });

    test('Apple 设计系统：每个语义名都有线框 / 实心 SF 替身', () {
      final List<String> missing = <String>[
        for (final MapEntry<String, IconData> e in FushiIcons.all.entries)
          if (fushiSymbolAppleIcon(e.value) == null) e.key,
      ];
      expect(missing, isEmpty);
      final IconData outline = fushiAppleIcon(FushiIcons.home)!;
      final IconData solid = fushiAppleIcon(
        FushiIcons.filled(FushiIcons.home),
      )!;
      expect(outline.fontFamily, CupertinoIcons.house.fontFamily);
      expect(outline, isNot(solid));
      // 线框字族 + 显式 fill >= 0.5 同样取实心。
      expect(fushiAppleIcon(FushiIcons.home, fill: 1), solid);
    });

    test('非语义图标原样返回', () {
      expect(FushiIcons.filled(CupertinoIcons.add), CupertinoIcons.add);
      expect(isFushiSymbol(CupertinoIcons.add), isFalse);
    });

    test('字号自适应：opsz 夹在 20..48、小号加粗、大号变细、暗底降 GRAD', () {
      expect(fushiSymbolOpticalSize(12), 20);
      expect(fushiSymbolOpticalSize(24), 24);
      expect(fushiSymbolOpticalSize(96), 48);
      expect(fushiSymbolWeight(16), 500);
      expect(fushiSymbolWeight(24), 400);
      expect(fushiSymbolWeight(48), 300);
      expect(fushiSymbolGrade(Brightness.dark), -25);
      expect(fushiSymbolGrade(Brightness.light), 0);
    });
  });

  group('已迁移的面', () {
    test('顶层导航：线框 / 实心语义图标', () {
      for (final HomeTab tab in HomeTab.values) {
        final AdaptiveNavItem item = homeNavItemFor(tab);
        expect(isFushiSymbol(item.icon), isTrue, reason: '$tab icon');
        expect(item.selectedIcon, FushiIcons.filled(item.icon), reason: '$tab');
      }
    });

    test('设置分类（SettingsDestination）图标不再直接写 Icons.*', () {
      final RegExp destIcon = RegExp(
        r'SettingsDestination\([\s\S]*?\bicon:\s*([^,\n]+)',
      );
      final List<String> hits = <String>[];
      for (final FileSystemEntity f in Directory(
        'lib/src/settings',
      ).listSync()) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final RegExpMatch m in destIcon.allMatches(f.readAsStringSync())) {
          final String expr = m.group(1)!.trim();
          if (RegExp(r'(?<![\w.])Icons\.').hasMatch(expr)) {
            hits.add('${f.uri.pathSegments.last}: $expr');
          }
        }
      }
      expect(hits, isEmpty);
    });
  });

  test('棘轮：lib/ 新增的直接 Icons.* 用法（改用 FushiIcons）', () {
    final Map<String, dynamic> allow =
        jsonDecode(
              File(
                'test/build/fushi_icons_legacy_allowlist.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final RegExp legacy = RegExp(r'(?<![\w.])Icons\.[a-z0-9_]+');
    final List<String> over = <String>[];
    for (final FileSystemEntity f in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String rel = f.path.replaceAll(r'\', '/');
      final int n = legacy.allMatches(f.readAsStringSync()).length;
      final int cap = (allow[rel] as int?) ?? 0;
      if (n > cap) over.add('$rel: $n > $cap');
    }
    expect(
      over,
      isEmpty,
      reason:
          '新代码用 FushiIcons（lib/src/utils/fushi_icons.dart）的语义名，'
          '不要再直接写 Icons.xxx_outlined / _rounded。',
    );
  });
}
