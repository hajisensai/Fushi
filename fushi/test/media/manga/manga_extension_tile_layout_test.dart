import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/utils.dart';

/// 扩展行以前的副标题是「语言 · 版本」+ 硬 `\n` + **完整 URL** 两行，配上
/// standard 密度（上下各 12、下限 56）和 17px 标题，单行高度冲到 ~89px：手机一屏
/// 只装得下六条，而三行里两行是噪音。这里钉住「一行元信息 + 紧凑行高」这两条，
/// 免得下次有人顺手又把 `\n` 加回来。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<double> pumpTile(
    WidgetTester tester, {
    required Widget subtitle,
    int subtitleMaxLines = 1,
    double width = 600,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          // 必须给不受限的竖向空间：行内 Column 是 mainAxisSize.max，放进定高
          // 容器会被拉满（`FushiListItem` 的 golden 注释同一坑）。真实调用点也
          // 都在可滚动列表里。
          // 2026-10 体验优化：<480 宽时动作按钮会下移到副标题下方（行高随之
          // 变高），量「紧凑行高」默认用宽屏 600；窄屏另有专测。
          body: SizedBox(
            width: width,
            child: ListView(
              children: <Widget>[
                MangaExtensionManagementTile(
                  title: 'Asura Scans',
                  subtitle: subtitle,
                  subtitleMaxLines: subtitleMaxLines,
                  primaryLabel: 'Install',
                  onPrimary: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // FushiCard 的自身尺寸含行间外边距，量行高要量卡面本身。
    return tester.getSize(find.byType(FushiListItem)).height;
  }

  testWidgets('一行元信息的扩展行高不超过 MD3 两行行下限（旧的三行版是 ~89）',
      (WidgetTester tester) async {
    final double height = await pumpTile(
      tester,
      subtitle: Text(
        mangaSourceMetaLine(<String?>['EN', 'Version 19', 'asurascans.com']),
      ),
    );
    // MD3 两行列表行（标题 + 一行副标题）的下限是 72，外加行恒画的 1px 透明
    // 边框 ×2（几何不随选中态变）= 74；多一行副标题就会超出。
    expect(height, lessThanOrEqualTo(74));
    // 触摸端命中区不能为了紧凑被牺牲。
    expect(height, greaterThanOrEqualTo(56));
  });

  testWidgets('相邻两行之间有实边距，不靠圆角缺口分隔', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              for (final String name in <String>['A', 'B'])
                MangaExtensionManagementTile(
                  title: name,
                  subtitle: const Text('EN · Version 1'),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // 卡片 padding 为 0，所以行内容的外沿就是卡面外沿：两行之间的距离即行间
    // 外边距。
    final Iterable<Element> rows = find.byType(FushiListItem).evaluate();
    expect(rows, hasLength(2));
    final Rect first = tester.getRect(find.byWidget(rows.first.widget));
    final Rect second = tester.getRect(find.byWidget(rows.last.widget));
    expect(second.top - first.bottom, greaterThan(0));
  });

  testWidgets('副标题默认只留一行；调用点可显式放宽', (WidgetTester tester) async {
    await pumpTile(tester, subtitle: const Text('EN · Version 19'));
    Text subtitle = tester.widget<Text>(find.text('EN · Version 19'));
    expect(subtitle.maxLines, isNull, reason: '行数由 FushiListItem 的默认样式承担');

    final RichText rendered = tester.widget<RichText>(
      find.descendant(
        of: find.text('EN · Version 19'),
        matching: find.byType(RichText),
      ),
    );
    expect(rendered.maxLines, 1);

    await pumpTile(
      tester,
      subtitle: const Text('EN · Version 19'),
      subtitleMaxLines: 3,
    );
    final RichText widened = tester.widget<RichText>(
      find.descendant(
        of: find.text('EN · Version 19'),
        matching: find.byType(RichText),
      ),
    );
    expect(widened.maxLines, 3);
    subtitle = tester.widget<Text>(find.text('EN · Version 19'));
    expect(subtitle.data, 'EN · Version 19');
  });

  // 2026-10 体验优化：trailing 的 Wrap 在 FushiListItem 的 Row 里拿到无界宽度、
  // 永远不换行；窄屏上「预览 + 安装」+ 开关把标题挤没。
  testWidgets('窄屏（<480）文字按钮下移到副标题下方，开关留在 trailing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ListView(
              children: <Widget>[
                MangaExtensionManagementTile(
                  title: 'A very long extension name that needs room',
                  subtitle: const Text('EN · Version 19'),
                  enabled: true,
                  onEnabledChanged: (_) {},
                  secondaryLabel: 'Preview',
                  onSecondary: () {},
                  primaryLabel: 'Uninstall',
                  onPrimary: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final Finder compact = find.byKey(
      const ValueKey<String>('manga_extension_tile_compact_actions'),
    );
    expect(compact, findsOneWidget);
    expect(
      find.descendant(of: compact, matching: find.text('Preview')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: compact, matching: find.text('Uninstall')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: compact, matching: find.byType(Switch)),
      findsNothing,
    );
    // 按钮行在副标题下方。
    expect(
      tester.getTopLeft(find.text('Uninstall')).dy,
      greaterThan(tester.getBottomLeft(find.text('EN · Version 19')).dy),
    );
    // 标题列留出了实宽（旧布局下只剩几个字宽）。
    expect(
      tester.getSize(find.textContaining('A very long')).width,
      greaterThan(150),
    );
  });

  testWidgets('宽屏（>=480）文字按钮仍在 trailing', (WidgetTester tester) async {
    await pumpTile(tester, subtitle: const Text('EN · Version 19'));
    expect(
      find.byKey(
        const ValueKey<String>('manga_extension_tile_compact_actions'),
      ),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.text('Install')).dx,
      greaterThan(tester.getTopRight(find.text('EN · Version 19')).dx),
    );
  });

  group('mangaSourceMetaLine', () {
    test('跳过空片段，用 · 串成一行', () {
      expect(
        mangaSourceMetaLine(<String?>['EN', null, '  ', 'Version 2', 'x.org']),
        'EN · Version 2 · x.org',
      );
      expect(mangaSourceMetaLine(<String?>[null, '']), '');
    });
  });

  group('mangaSourceHostLabel', () {
    test('去掉 scheme / www / 根路径', () {
      expect(
        mangaSourceHostLabel('https://www.silentquill.net'),
        'silentquill.net',
      );
      expect(mangaSourceHostLabel('https://asurascans.com/'), 'asurascans.com');
      expect(
        mangaSourceHostLabel('https://a.example/manga'),
        'a.example/manga',
      );
    });

    test('不是 URL 的（Aidoku 只有包 id）原样返回', () {
      expect(mangaSourceHostLabel('multi.batcave'), 'multi.batcave');
      expect(mangaSourceHostLabel('  '), '');
    });
  });
}
