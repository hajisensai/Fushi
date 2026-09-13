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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          // 必须给不受限的竖向空间：行内 Column 是 mainAxisSize.max，放进定高
          // 容器会被拉满（`FushiListItem` 的 golden 注释同一坑）。真实调用点也
          // 都在可滚动列表里。
          body: SizedBox(
            width: 390,
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

  testWidgets('一行元信息的扩展行高不超过 72（旧的三行版是 ~89）', (WidgetTester tester) async {
    final double height = await pumpTile(
      tester,
      subtitle: Text(
        mangaSourceMetaLine(<String?>['EN', 'Version 19', 'asurascans.com']),
      ),
    );
    expect(height, lessThanOrEqualTo(72));
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
