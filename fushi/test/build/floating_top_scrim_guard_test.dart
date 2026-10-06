import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';

/// 浮动顶栏页面的顶部可读性只允许无硬边的柔和渐变（2026-10-06 用户：视频
/// 详情页滚动后集卡在顶栏下沿被一条水平硬边切开，之前按页面修过多次仍复发）。
///
/// 根因有两层，本守卫各咬一层：
/// 1. 共享遮罩 [FushiTopFadeScrim] 的不透明度曲线必须单调、连续、末端为 0，
///    相邻采样之间没有跳变（曾经是「实色段 + 20 px 线性降到 0」，顶栏还从栏
///    下沿起画，不透明度在下沿处 0 → 0.92 一步跳上去）。
/// 2. 页面不得自己再画顶部底带 / 渐变：详情布局曾叠一层 `_MediaDetailTopScrim`，
///    与顶栏那层叠加出浅色带；铺到顶栏底下的页面（extendBodyBehindAppBar）
///    的 [FushiAppBar] 不得设非透明底色或 flexibleSpace。
void main() {
  group('FushiTopFadeScrim curve', () {
    Future<List<Color>> pumpScrim(
      WidgetTester tester, {
      required double solidHeight,
      double topOpacity = 0.92,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: FushiTopFadeScrim(
              solidHeight: solidHeight,
              topOpacity: topOpacity,
              color: const Color(0xFFFFFFFF),
            ),
          ),
        ),
      );
      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(FushiTopFadeScrim),
          matching: find.byType(DecoratedBox),
        ),
      );
      final LinearGradient gradient =
          (box.decoration as BoxDecoration).gradient! as LinearGradient;
      return gradient.colors;
    }

    for (final double solid in <double>[0, 56, 120]) {
      testWidgets('solidHeight $solid: monotone, continuous, ends at 0', (
        WidgetTester tester,
      ) async {
        final List<Color> colors = await pumpScrim(tester, solidHeight: solid);
        expect(colors.first.a, closeTo(0.92, 0.001));
        expect(colors.last.a, closeTo(0, 0.001));
        for (int i = 1; i < colors.length; i++) {
          expect(
            colors[i].a,
            lessThanOrEqualTo(colors[i - 1].a + 1e-6),
            reason: 'alpha must not rise at sample $i',
          );
          expect(
            colors[i - 1].a - colors[i].a,
            lessThan(0.2),
            reason: 'no visible step between adjacent samples ($i)',
          );
        }
      });
    }

    testWidgets('topOpacity 1 starts fully opaque (seam continuation)', (
      WidgetTester tester,
    ) async {
      final List<Color> colors = await pumpScrim(
        tester,
        solidHeight: 0,
        topOpacity: 1,
      );
      expect(colors.first.a, closeTo(1, 0.001));
    });
  });

  group('no page-local top bands', () {
    test('MediaDetailLayout draws no own top scrim', () {
      final String kit = File(
        'lib/src/media/detail/media_detail_kit.dart',
      ).readAsStringSync();
      expect(kit.contains('_MediaDetailTopScrim'), isFalse);
      expect(kit.contains('topScrim'), isFalse);
    });

    test('FushiAppBar on extendBodyBehindAppBar pages paints no band', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String source = entity.readAsStringSync();
        if (!source.contains('extendBodyBehindAppBar: true')) continue;
        int from = 0;
        while (true) {
          final int start = source.indexOf('FushiAppBar(', from);
          if (start < 0) break;
          final String args = _balancedArgs(
            source,
            start + 'FushiAppBar'.length,
          );
          from = start + 1;
          final RegExpMatch? bg = RegExp(
            r'(?<![A-Za-z])backgroundColor:\s*([^,)\n]+)',
          ).firstMatch(args);
          if (bg != null && bg.group(1)!.trim() != 'Colors.transparent') {
            offenders.add('${entity.path}: backgroundColor ${bg.group(1)}');
          }
          if (args.contains('flexibleSpace:')) {
            offenders.add('${entity.path}: flexibleSpace');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('top fades go through the shared FushiTopFadeScrim', () {
      // 曾经各页各写一份「底色 → 透明」两色线性渐变（线性渐变末端斜率突变，
      // 在模糊背景上是一道看得见的 Mach 带）。
      final String discovery = File(
        'lib/src/pages/implementations/discovery/discovery_hero_carousel.dart',
      ).readAsStringSync();
      expect(discovery.contains('FushiTopFadeScrim('), isTrue);
    });
  });
}

/// 从 [open]（指向 `(`）开始取配平的参数文本。
String _balancedArgs(String source, int open) {
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return source.substring(open);
}
