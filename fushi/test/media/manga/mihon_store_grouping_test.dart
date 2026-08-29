import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 用户反馈（漫画 →「导入」tab 截图）：扩展列表里每个扩展下面铺着几十行
/// 「Akuma (xx) — https://akuma.moe」，整页看不到头 —— 「这里支持下根据仓库折叠」。
///
/// 两处都要治：① 扩展按**仓库**分组、可折叠；② 每个扩展的「包含的源」默认只露几条。
const String kStoreA = 'https://repo-a.example/index.json';
const String kStoreB = 'https://repo-b.example/index.json';

MihonAvailableExtension _ext(
  String name, {
  required String storeUrl,
  int sourceCount = 1,
}) {
  return MihonAvailableExtension(
    storeUrl: storeUrl,
    name: name,
    packageName: 'org.example.${name.toLowerCase().replaceAll(' ', '')}',
    apkUrl: 'https://repo.example/$name.apk',
    iconUrl: '',
    libVersion: '1.6',
    versionCode: 1,
    versionName: '1.6.1',
    language: 'all',
    contentWarning: 0,
    sources: <MihonAvailableSource>[
      for (int i = 0; i < sourceCount; i++)
        MihonAvailableSource(
          id: '$name-$i',
          name: '$name source $i',
          language: 'en',
          baseUrl: 'https://source.example/$i',
        ),
    ],
  );
}

MangaExtensionStoreRow _store(String indexUrl, String name, int sortOrder) {
  return MangaExtensionStoreRow(
    indexUrl: indexUrl,
    name: name,
    badgeLabel: null,
    format: MihonStoreFormat.currentJson.name,
    signingKey: null,
    enabled: true,
    sortOrder: sortOrder,
    etag: null,
    lastModified: null,
    lastSyncAt: null,
    lastError: null,
  );
}

void main() {
  group('buildMihonGroupedRows', () {
    test('按仓库分组，顺序跟随仓库表（sortOrder 是用户排的）', () {
      final List<MihonExtensionListRow> rows = buildMihonGroupedRows(
        stores: <MangaExtensionStoreRow>[
          _store(kStoreA, 'Repo A', 0),
          _store(kStoreB, 'Repo B', 1),
        ],
        extensions: <MihonAvailableExtension>[
          _ext('b1', storeUrl: kStoreB),
          _ext('a1', storeUrl: kStoreA),
          _ext('a2', storeUrl: kStoreA),
        ],
        expanded: (_, __) => true,
      );

      expect(rows.whereType<MihonStoreHeaderRow>().map((r) => r.label).toList(),
          <String>['Repo A', 'Repo B']);
      final MihonStoreHeaderRow first = rows.first as MihonStoreHeaderRow;
      expect(first.count, 2);
      expect(rows.length, 5, reason: '2 个表头 + 3 个扩展');
    });

    test('收起的仓库只贡献一行表头（列表才不会被 1900 条撑爆）', () {
      final List<MihonExtensionListRow> rows = buildMihonGroupedRows(
        stores: <MangaExtensionStoreRow>[_store(kStoreA, 'Repo A', 0)],
        extensions: <MihonAvailableExtension>[
          _ext('a1', storeUrl: kStoreA),
          _ext('a2', storeUrl: kStoreA),
        ],
        expanded: (_, __) => false,
      );

      expect(rows.length, 1);
      final MihonStoreHeaderRow header = rows.single as MihonStoreHeaderRow;
      expect(header.expanded, isFalse);
      expect(header.count, 2, reason: '收起态下条数是「这仓库有没有东西」的唯一线索。');
    });

    test('storeUrl 指向已删仓库的孤儿扩展不会凭空消失，排在最后', () {
      final List<MihonExtensionListRow> rows = buildMihonGroupedRows(
        stores: <MangaExtensionStoreRow>[_store(kStoreA, 'Repo A', 0)],
        extensions: <MihonAvailableExtension>[
          _ext('a1', storeUrl: kStoreA),
          _ext('orphan', storeUrl: 'https://gone.example/index.json'),
        ],
        expanded: (_, __) => true,
      );

      final List<String> labels = rows
          .whereType<MihonStoreHeaderRow>()
          .map((MihonStoreHeaderRow r) => r.label)
          .toList();
      expect(labels, <String>['Repo A', 'https://gone.example/index.json']);
      expect(rows.whereType<MihonExtensionEntryRow>().length, 2);
    });

    test('展开判据拿得到条数（自适应阈值靠它）', () {
      final List<int> seen = <int>[];
      buildMihonGroupedRows(
        stores: <MangaExtensionStoreRow>[_store(kStoreA, 'Repo A', 0)],
        extensions: <MihonAvailableExtension>[
          _ext('a1', storeUrl: kStoreA),
          _ext('a2', storeUrl: kStoreA),
          _ext('a3', storeUrl: kStoreA),
        ],
        expanded: (String url, int count) {
          seen.add(count);
          return true;
        },
      );
      expect(seen, <int>[3]);
    });

    test('空分组不产表头（筛掉整仓后不该剩一个空壳）', () {
      final List<MihonExtensionListRow> rows = buildMihonGroupedRows(
        stores: <MangaExtensionStoreRow>[
          _store(kStoreA, 'Repo A', 0),
          _store(kStoreB, 'Repo B', 1),
        ],
        extensions: <MihonAvailableExtension>[_ext('a1', storeUrl: kStoreA)],
        expanded: (_, __) => true,
      );
      expect(rows.whereType<MihonStoreHeaderRow>().length, 1);
    });
  });

  group('页面行为', () {
    late Directory root;
    late FushiDatabase database;
    late MihonManager manager;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      root = await Directory.systemTemp.createTemp('hibiki-mihon-grouping-');
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: kStoreA,
          name: 'Big repository',
          format: MihonStoreFormat.currentJson.name,
          signingKey: const Value<String?>('aabb'),
        ),
      );
      manager = MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _StubRuntime(),
      );
      await manager.reload();
    });

    tearDown(() async {
      manager.dispose();
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: Scaffold(body: MihonExtensionsPage(manager: manager)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('大仓库默认收起，点表头才铺开', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[
        for (int i = 0; i < kMihonStoreAutoCollapseThreshold + 1; i++)
          _ext('ext$i', storeUrl: kStoreA),
      ];
      await pump(tester);

      expect(find.text('ext0'), findsNothing, reason: '超过阈值的仓库默认收起。');

      // 按 indexUrl 定位分组表头：页面顶部的仓库**管理**卡也画着同一个 name，
      // 按名字找会先撞上那张卡（它没有 onTap，点了什么都不会发生）。
      final Finder header =
          find.byKey(const ValueKey<String>('mihon-store-group-$kStoreA'));
      expect(header, findsOneWidget);
      await tester.tap(header);
      await tester.pump();
      expect(find.text('ext0'), findsOneWidget);
    });

    testWidgets('小仓库默认展开（一眼扫得完就别让人多点一下）', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[
        _ext('only-one', storeUrl: kStoreA),
      ];
      await pump(tester);

      expect(find.text('only-one'), findsOneWidget);
    });

    testWidgets('搜索强制展开：结果躲在收起的分组里等于搜索失效', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[
        for (int i = 0; i < kMihonStoreAutoCollapseThreshold + 1; i++)
          _ext('ext$i', storeUrl: kStoreA),
      ];
      await pump(tester);
      // 断言用条目**独有**的文本：搜索框自己也画着 'ext7'，find.text('ext7')
      // 会连 EditableText 一起命中（2 个），把断言变成一道谜题。
      expect(find.textContaining('ext7 source 0'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey<String>('mihon_extension_search_field')),
        'ext7',
      );
      await tester.pump();

      expect(find.textContaining('ext7 source 0'), findsOneWidget);
    });

    testWidgets('「包含的源」默认只露前 3 条，可展开全部', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[
        _ext('many', storeUrl: kStoreA, sourceCount: 12),
      ];
      await pump(tester);

      expect(find.textContaining('many source 0'), findsOneWidget);
      expect(find.textContaining('many source 2'), findsOneWidget);
      expect(find.textContaining('many source 3'), findsNothing,
          reason: '截图里那一屏的主因就是这里：一个扩展铺了几十行源。');

      final Finder toggle = find.byKey(
        const ValueKey<String>('mihon-sources-toggle-org.example.many'),
      );
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();

      expect(find.textContaining('many source 11'), findsOneWidget);
    });

    testWidgets('源数不超过 3 条时不出「展开全部」按钮', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[
        _ext('few', storeUrl: kStoreA, sourceCount: 2),
      ];
      await pump(tester);

      expect(
        find.byKey(
          const ValueKey<String>('mihon-sources-toggle-org.example.few'),
        ),
        findsNothing,
      );
    });
  });
}

class _StubRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
