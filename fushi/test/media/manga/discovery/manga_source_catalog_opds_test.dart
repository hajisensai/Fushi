/// OPDS 服务器作为漫画「浏览来源」的第四类来源。
///
/// 这一节是 OPDS 漫画那一半**唯一**的 UI 入口：没有它，cbz 分类与
/// `importMangaArchive` 端口全是够不到的死代码——统一发现页的四个注入点
/// （书库浏览 / 游戏页 / 下载中心书域与游戏域）没有一个传 `manga`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';

OpdsServerConfig _server(String id, {String name = ''}) => OpdsServerConfig(
      id: id,
      name: name,
      catalogUrl: Uri.parse('https://books.example.com/api/v1/opds'),
    );

void main() {
  group('MangaSourceCatalog', () {
    test('isEmpty 计入 OPDS：只有 OPDS 服务器时这一节不算空', () {
      // 算空会让「有扩展宿主却一个来源都没启用」的提示压在有内容的列表上面。
      expect(const MangaSourceCatalog().isEmpty, isTrue);
      expect(
        MangaSourceCatalog(opdsServers: <OpdsServerConfig>[_server('a')])
            .isEmpty,
        isFalse,
      );
    });

    test('sourceOptions 不含 OPDS——它没有热门 feed，进下拉就是个恒空的选择', () {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        mokuroEnabled: true,
        opdsServers: <OpdsServerConfig>[_server('a', name: 'Shelf')],
      );
      final List<String> ids =
          catalog.sourceOptions.map((DiscoverySourceOption o) => o.id).toList();
      expect(ids, <String>[MangaSourceCatalog.mokuroSourceId]);
      expect(ids.any((String id) => id.contains('opds')), isFalse);
    });

    test('filterById 收窄到具体来源时，OPDS 卡片一并让位', () {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        mokuroEnabled: true,
        opdsServers: <OpdsServerConfig>[_server('a')],
      );
      final MangaSourceCatalog narrowed =
          catalog.filterById(MangaSourceCatalog.mokuroSourceId);
      expect(narrowed.mokuroEnabled, isTrue);
      expect(narrowed.opdsServers, isEmpty,
          reason: '选中了别的来源，OPDS 卡片留在列表里与选择无关');
    });

    test('「全部来源」不过滤，OPDS 原样保留', () {
      final MangaSourceCatalog catalog = MangaSourceCatalog(
        opdsServers: <OpdsServerConfig>[_server('a')],
      );
      expect(
        catalog.filterById(kDiscoveryAllSourcesId).opdsServers,
        hasLength(1),
      );
    });
  });

  group('MangaSourceCatalogSection', () {
    Widget harness(
      MangaSourceCatalog catalog, {
      required ValueChanged<OpdsServerConfig> onOpenOpds,
    }) =>
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MangaSourceCatalogSection(
                catalog: catalog,
                onOpenMokuro: () {},
                onOpenAidoku: (_) {},
                onOpenMihon: (_) {},
                onOpenOpds: onOpenOpds,
              ),
            ),
          ),
        );

    testWidgets('每台 OPDS 服务器一张卡片，点击回调带出该服务器', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        harness(
          MangaSourceCatalog(
            opdsServers: <OpdsServerConfig>[
              _server('a', name: 'My Shelf'),
              _server('b'),
            ],
          ),
          onOpenOpds: (OpdsServerConfig s) => opened.add(s.id),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('My Shelf'), findsOneWidget);
      // 空名回退主机名，而不是渲染成一张没有标题的卡片。
      expect(find.text('books.example.com'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('manga-opds-a')));
      await tester.pumpAndSettle();
      expect(opened, <String>['a']);
    });

    testWidgets('没有 OPDS 服务器时不留空卡片', (WidgetTester tester) async {
      await tester.pumpWidget(
        harness(const MangaSourceCatalog(), onOpenOpds: (_) {}),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('manga-opds-a')), findsNothing);
    });
  });
}
