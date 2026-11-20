import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_source_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 拼贴改版「发现」的来源色块（设计稿 DI2 / DI6 / DI17 / DI19）：
///
/// - 漫画首块右侧放置顶源，没有置顶就放前 2 个启用源；网格里不重复；
/// - 来源排序只按「置顶在前 + 现有顺序」（不做「最近使用」）；
/// - 同一来源各处同色（色相按来源 id 共享，兜底是源名哈希）；
/// - 失败态在块内给「无法连接 · 重试」，末尾「添加来源」块只做跳转；
/// - 来源块可用键盘激活（焦点驱动，不用 tester.tap）。
MangaOnlineSourceRow _mihon(String id, {bool pinned = false, int order = 0}) =>
    MangaOnlineSourceRow(
      mediaKind: 'manga',
      extensionPackage: 'pkg',
      sourceId: id,
      name: 'Source $id',
      language: 'en',
      baseUrl: 'https://example.com',
      enabled: true,
      pinned: pinned,
      sortOrder: order,
    );

Widget _wrap(Widget child) => TranslationProvider(
  child: MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DiscoverySourceHues.instance.resetForTest();
  });

  group('MangaSourceCatalog 排序与首块旁两块', () {
    test('有置顶源：首块旁放前 2 个置顶源，置顶排在最前', () {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        mokuroEnabled: true,
        mihonSources: <MangaOnlineSourceRow>[
          _mihon('a'),
          _mihon('b', pinned: true),
          _mihon('c'),
          _mihon('d', pinned: true),
          _mihon('e', pinned: true),
        ],
      );
      final List<String> ids = catalog.entries
          .map((MangaCatalogSourceEntry e) => e.id)
          .toList();
      expect(ids.take(3), <String>[
        'mihon:pkg:b',
        'mihon:pkg:d',
        'mihon:pkg:e',
      ]);
      // 其余保持现有顺序（mokuro → Mihon 原序），没有任何「最近使用」重排。
      expect(ids.skip(3), <String>['mokuro', 'mihon:pkg:a', 'mihon:pkg:c']);
      expect(catalog.heroSideIds, <String>['mihon:pkg:b', 'mihon:pkg:d']);
    });

    test('没有置顶源：首块旁放前 2 个启用源（现有顺序）', () {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        mokuroEnabled: true,
        mihonSources: <MangaOnlineSourceRow>[_mihon('a'), _mihon('b')],
      );
      expect(catalog.heroSideIds, <String>['mokuro', 'mihon:pkg:a']);
    });

    test('只有一个来源：首块旁只放一块', () {
      const MangaSourceCatalog catalog = MangaSourceCatalog(
        mokuroEnabled: true,
      );
      expect(catalog.heroSideIds, <String>['mokuro']);
    });
  });

  group('MangaSourceCatalogSection', () {
    testWidgets('首块旁已显示的来源不在网格里重复', (WidgetTester tester) async {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        mokuroEnabled: true,
        mihonSources: <MangaOnlineSourceRow>[_mihon('a'), _mihon('b')],
      );
      await tester.pumpWidget(
        _wrap(
          MangaSourceCatalogSection(
            catalog: catalog,
            excludeIds: catalog.heroSideIds.toSet(),
            onOpenMokuro: () {},
            onOpenMihon: (_) {},
            onOpenOpds: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('manga-source-mokuro')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('manga-mihon-mihon:pkg:a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('manga-mihon-mihon:pkg:b')),
        findsOneWidget,
      );
      expect(
        find.textContaining(t.discovery_sources_excluded_caption(n: 2)),
        findsOneWidget,
      );
    });

    testWidgets('失败的源块内给「无法连接 · 重试」，块高不变', (WidgetTester tester) async {
      int retries = 0;
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        mihonSources: <MangaOnlineSourceRow>[_mihon('a'), _mihon('b')],
      );
      await tester.pumpWidget(
        _wrap(
          MangaSourceCatalogSection(
            catalog: catalog,
            failures: const <String>{'mihon:pkg:b'},
            onRetry: () => retries++,
            onOpenMokuro: () {},
            onOpenMihon: (_) {},
            onOpenOpds: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder failed = find.byKey(
        const ValueKey<String>('manga-mihon-mihon:pkg:b'),
      );
      final Finder ok = find.byKey(
        const ValueKey<String>('manga-mihon-mihon:pkg:a'),
      );
      expect(
        find.descendant(
          of: failed,
          matching: find.text(t.discovery_source_load_failed),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: ok,
          matching: find.text(t.discovery_source_load_failed),
        ),
        findsNothing,
      );
      expect(tester.getSize(failed).height, tester.getSize(ok).height);
    });

    testWidgets('「添加来源」块只在有去处时出现，且不写计数', (WidgetTester tester) async {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        opdsServers: <OpdsServerConfig>[
          OpdsServerConfig(
            id: 'srv',
            name: 'Shelf',
            catalogUrl: Uri.parse('https://books.example.com/opds'),
          ),
        ],
      );
      Future<void> pump({VoidCallback? onAdd}) async {
        await tester.pumpWidget(
          _wrap(
            MangaSourceCatalogSection(
              catalog: catalog,
              onAddSource: onAdd,
              onOpenMokuro: () {},
              onOpenMihon: (_) {},
              onOpenOpds: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump();
      expect(
        find.byKey(const ValueKey<String>('manga-source-add')),
        findsNothing,
      );
      await pump(onAdd: () {});
      final Finder add = find.byKey(const ValueKey<String>('manga-source-add'));
      expect(add, findsOneWidget);
      expect(
        find.descendant(
          of: add,
          matching: find.text(t.discovery_source_add_title),
        ),
        findsOneWidget,
      );
    });
  });

  group('来源身份色', () {
    test('没取到图片色时用源名哈希，同一来源各处同一色相', () {
      final double a = DiscoverySourceHues.instance.hueOf(
        sourceId: 'mihon:pkg:a',
        name: 'MangaDex',
      );
      final double b = DiscoverySourceHues.instance.hueOf(
        sourceId: 'mihon:pkg:a',
        name: 'MangaDex',
      );
      expect(a, b);
      expect(a, fushiGeneratedCoverHue('MangaDex'));
      expect(
        DiscoverySourceHues.instance.originOf('mihon:pkg:a'),
        DiscoverySourceHueOrigin.nameHash,
      );
    });

    testWidgets('结果行 glyph 与来源块同一配色', (WidgetTester tester) async {
      late Color blockGlyph;
      late Color rowGlyph;
      await tester.pumpWidget(
        _wrap(
          Column(
            children: <Widget>[
              DiscoverySourceColorsBuilder(
                sourceId: 'erogame',
                name: 'erogame.space',
                builder: (BuildContext context, FushiCoverBlockColors colors) {
                  blockGlyph = colors.onContainer;
                  return const SizedBox.shrink();
                },
              ),
              DiscoverySourceColorsBuilder(
                sourceId: 'erogame',
                name: 'erogame.space',
                builder: (BuildContext context, FushiCoverBlockColors colors) {
                  rowGlyph = colors.onContainer;
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      );
      expect(blockGlyph, rowGlyph);
    });
  });

  testWidgets('来源块可用键盘激活：Tab 聚焦 + Enter', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 300,
          child: DiscoverySourceBlock(
            key: const ValueKey<String>('block'),
            sourceId: 'shinnku',
            name: 'Shinnku',
            chips: const <String>['Search only'],
            onTap: () => opened++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('block'))).height,
      kDiscoverySourceBlockHeight,
    );
  });

  testWidgets('网格放进高度不受限的滚动视图：不传 height 的来源块不抛布局错误、块高固定', (
    WidgetTester tester,
  ) async {
    // 回归：网格原来只给格子定宽，块按「填满父级」排时 stretch 的 Row 拿到
    // 无限高约束，发现页 / 漫画来源网格一打开就连环抛错。
    await tester.pumpWidget(
      _wrap(
        DiscoverySourceBlockGrid(
          children: <Widget>[
            for (int i = 0; i < 3; i++)
              DiscoverySourceBlock(
                key: ValueKey<String>('grid-src-$i'),
                sourceId: 'src-$i',
                name: 'Source $i',
                onTap: () {},
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (int i = 0; i < 3; i++) {
      expect(
        tester.getSize(find.byKey(ValueKey<String>('grid-src-$i'))).height,
        kDiscoverySourceBlockHeight,
      );
    }
  });
}
