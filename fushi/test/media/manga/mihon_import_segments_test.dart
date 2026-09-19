import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/import_page_segments.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「导入」视图分段化（2026-09-19，视频与漫画两页统一）的三块共享部件：
///
/// 1. [ImportPageSegmentBar]：段按给定顺序渲染、点选回调、窄屏只画文字；
/// 2. [MihonExtensionsPage] 的 `sections`：「仓库」段只有仓库卡与仓库动作，
///    「扩展」段只有扩展目录与导入 APK，空集渲染空 sliver 且不抛；
/// 3. [MihonInstalledSourcesSection]：源行真渲染、搜索真过滤、开关真写穿 DB、
///    点行走 `onOpenSource`。
///
/// 两个宿主页（`MediaSourcesPage` / `MangaSourcesPage`）都从 `appProvider` 拿整个
/// `AppModel`，挂起来测的是环境不是接线，接线由源码守卫
/// `test/pages/import_page_unification_guard_test.dart` 守。
void main() {
  late Directory root;
  late FushiDatabase database;
  late MihonManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('hibiki-import-segments-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    await database.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: 'https://repo.example/index.json',
        name: 'Fixture repository',
        format: MihonStoreFormat.currentJson.name,
        signingKey: const Value<String?>('aabb'),
      ),
    );
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: _PageRuntime(),
    );
    await manager.reload();
    manager.available = <MihonAvailableExtension>[
      _extension(
        name: 'Fixture Extension',
        packageName: 'org.example.fixture',
        sourceName: 'Fixture source',
      ),
    ];
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> pumpSlivers(
    WidgetTester tester,
    List<Widget> slivers, {
    Size size = const Size(1400, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(body: CustomScrollView(slivers: slivers)),
        ),
      ),
    );
    await tester.pump();
  }

  group('ImportPageSegmentBar', () {
    testWidgets('按给定顺序渲染段、点选回调、已选段不回调', (WidgetTester tester) async {
      final List<ImportPageSegment> changes = <ImportPageSegment>[];
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: ImportPageSegmentBar(
              segments: const <ImportPageSegment>[
                ImportPageSegment.local,
                ImportPageSegment.stores,
                ImportPageSegment.sources,
              ],
              selected: ImportPageSegment.local,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(t.media_import_segment_local), findsOneWidget);
      expect(find.text(t.media_import_segment_stores), findsOneWidget);
      expect(find.text(t.media_import_segment_sources), findsOneWidget);
      // 没传的段不出现：书的导入页只有「本地」时整条选择器都不该挂。
      expect(find.text(t.media_import_segment_extensions), findsNothing);
      // 宽屏带图标。
      expect(find.byIcon(Icons.hub_outlined), findsOneWidget);

      await tester.tap(find.text(t.media_import_segment_stores));
      await tester.pump();
      expect(changes, <ImportPageSegment>[ImportPageSegment.stores]);

      await tester.tap(find.text(t.media_import_segment_local));
      await tester.pump();
      expect(changes.length, 1, reason: '点已选中的段不该再回调');
      expect(tester.takeException(), null);
    });

    testWidgets('窄屏只画文字，不带图标', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: ImportPageSegmentBar(
              segments: ImportPageSegment.values,
              selected: ImportPageSegment.extensions,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      for (final ImportPageSegment segment in ImportPageSegment.values) {
        expect(find.text(importPageSegmentLabel(segment)), findsOneWidget);
      }
      expect(find.byIcon(Icons.hub_outlined), findsNothing);
      expect(find.byIcon(Icons.extension_outlined), findsNothing);
      expect(tester.takeException(), null, reason: '四段在 360 宽不得溢出');
    });
  });

  group('MihonExtensionsPage.sections', () {
    testWidgets('「仓库」段：仓库卡 + 刷新 / 添加仓库，没有扩展目录与导入 APK', (
      WidgetTester tester,
    ) async {
      await pumpSlivers(tester, <Widget>[
        MihonExtensionsPage(
          manager: manager,
          embedded: true,
          sections: const <MihonExtensionsSection>[
            MihonExtensionsSection.stores,
          ],
        ),
      ]);
      // 仓库卡：名字 + 改地址 / 删除按钮。
      expect(find.text('Fixture repository'), findsOneWidget);
      expect(find.byTooltip(t.mihon_store_remove), findsOneWidget);
      expect(find.text(t.mihon_store_refresh), findsOneWidget);
      expect(find.text(t.mihon_store_add), findsOneWidget);
      // 扩展目录及其动作一个都不在这一段。
      expect(find.text('Fixture Extension'), findsNothing);
      expect(find.text(t.mihon_extension_import), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('mihon_extension_bulk_install')),
        findsNothing,
      );
      expect(tester.takeException(), null);
    });

    testWidgets('「扩展」段：扩展目录 + 刷新 / 导入 APK，没有仓库卡与添加仓库', (
      WidgetTester tester,
    ) async {
      await pumpSlivers(tester, <Widget>[
        MihonExtensionsPage(
          manager: manager,
          embedded: true,
          sections: const <MihonExtensionsSection>[
            MihonExtensionsSection.catalog,
          ],
        ),
      ]);
      expect(find.text('Fixture Extension'), findsOneWidget);
      expect(find.text(t.mihon_extension_import), findsOneWidget);
      expect(find.text(t.mihon_store_refresh), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('mihon_extension_bulk_install')),
        findsOneWidget,
      );
      // 仓库卡不在这一段（分组表头仍会显示仓库名，所以锚在删除按钮上）。
      expect(find.byTooltip(t.mihon_store_remove), findsNothing);
      expect(find.text(t.mihon_store_add), findsNothing);
      expect(tester.takeException(), null);
    });

    testWidgets('空 sections 渲染空 sliver：兄弟节仍在、不抛', (WidgetTester tester) async {
      await pumpSlivers(tester, <Widget>[
        const SliverToBoxAdapter(child: Text('outer-section-above')),
        MihonExtensionsPage(
          manager: manager,
          embedded: true,
          sections: const <MihonExtensionsSection>[],
        ),
        const SliverToBoxAdapter(child: Text('outer-section-below')),
      ]);
      expect(find.text('outer-section-above'), findsOneWidget);
      expect(find.text('outer-section-below'), findsOneWidget);
      expect(find.text('Fixture repository'), findsNothing);
      expect(find.text('Fixture Extension'), findsNothing);
      expect(find.text(t.mihon_store_refresh), findsNothing);
      expect(tester.takeException(), null);
    });

    testWidgets('默认 sections 与旧内嵌形态相同：两节都在、三动作齐全', (WidgetTester tester) async {
      await pumpSlivers(tester, <Widget>[
        MihonExtensionsPage(manager: manager, embedded: true),
      ]);
      expect(find.text('Fixture repository'), findsWidgets);
      expect(find.text('Fixture Extension'), findsOneWidget);
      expect(find.text(t.mihon_store_refresh), findsOneWidget);
      expect(find.text(t.mihon_extension_import), findsOneWidget);
      expect(find.text(t.mihon_store_add), findsOneWidget);
    });
  });

  group('MihonInstalledSourcesSection', () {
    setUp(() async {
      await database.replaceMangaOnlineSources(
        'org.example.fixture',
        <MangaOnlineSourcesCompanion>[
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'org.example.fixture',
            sourceId: '1',
            name: 'Alpha source',
            language: 'ja',
            sortOrder: const Value<int>(0),
          ),
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'org.example.fixture',
            sourceId: '2',
            name: 'Beta source',
            language: 'en',
            sortOrder: const Value<int>(1),
          ),
        ],
      );
      await manager.reload();
    });

    testWidgets('源行真渲染、搜索真过滤、开关真写穿 DB', (WidgetTester tester) async {
      await pumpSlivers(tester, <Widget>[
        const SliverToBoxAdapter(child: Text('leading-row')),
        MihonInstalledSourcesSection(
          manager: manager,
          leading: const <Widget>[Text('builtin-row')],
        ),
      ]);
      expect(find.text('leading-row'), findsOneWidget);
      expect(find.text('builtin-row'), findsOneWidget);
      expect(find.text('Alpha source'), findsOneWidget);
      expect(find.text('Beta source'), findsOneWidget);
      // 排序箭头只在未筛选时出现。
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNWidgets(2));

      await tester.enterText(
        find.byKey(const ValueKey<String>('mihon_sources_search_field')),
        'beta',
      );
      await tester.pump();
      expect(find.text('Alpha source'), findsNothing);
      expect(find.text('Beta source'), findsOneWidget);
      expect(
        find.byIcon(Icons.keyboard_arrow_up),
        findsNothing,
        reason: '筛选中的列表顺序不是真实顺序，不得提供排序按钮',
      );

      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      await tester.pump();
      final List<MangaOnlineSourceRow> rows = await database
          .getMangaOnlineSources();
      expect(
        rows
            .singleWhere((MangaOnlineSourceRow row) => row.sourceId == '2')
            .enabled,
        isFalse,
        reason: '开关必须写穿 manga_online_sources.enabled',
      );
      expect(tester.takeException(), null);
    });

    testWidgets('点行走 onOpenSource；没传回调时行不可点', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await pumpSlivers(tester, <Widget>[
        MihonInstalledSourcesSection(
          manager: manager,
          onOpenSource: (MangaOnlineSourceRow source) =>
              opened.add(source.sourceId),
        ),
      ]);
      await tester.tap(find.text('Alpha source'));
      await tester.pump();
      expect(opened, <String>['1']);

      await pumpSlivers(tester, <Widget>[
        MihonInstalledSourcesSection(manager: manager),
      ]);
      await tester.tap(find.text('Alpha source'));
      await tester.pump();
      expect(opened, <String>['1'], reason: '没有回调就不该有点击行为');
      expect(tester.takeException(), null);
    });

    testWidgets('窄行动作收进溢出菜单，标题不再被挤成零宽', (WidgetTester tester) async {
      await pumpSlivers(tester, <Widget>[
        MihonInstalledSourcesSection(manager: manager),
      ], size: const Size(390, 760));
      // 内联图标按钮一个都不在，换成一个 ⋮ 菜单。
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
      expect(find.byIcon(Icons.tune), findsNothing);
      final Finder menu = find.byKey(
        const ValueKey<String>('mihon_source_menu_org.example.fixture_1'),
      );
      expect(menu, findsOneWidget);
      // 真实像素抓到过：五个 48dp 图标按钮排开后标题只剩 2px。标题列必须拿到
      // 像样的宽度（量的是 Text 的绘制宽，短标题也远超这个阈值）。
      final Size titleSize = tester.getSize(find.text('Alpha source'));
      expect(titleSize.width, greaterThan(60));

      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text(t.mihon_source_move_down), findsOneWidget);
      expect(find.text(t.mihon_source_preferences), findsOneWidget);
      expect(find.text(t.mihon_source_clear_data), findsOneWidget);
      expect(find.text(t.mihon_source_pin), findsOneWidget);
      // 首行的「上移」在菜单里是禁用项而不是消失。
      final PopupMenuItem<Object?> moveUp = tester
          .widget<PopupMenuItem<Object?>>(
            find.ancestor(
              of: find.text(t.mihon_source_move_up),
              matching: find.byWidgetPredicate(
                (Widget widget) => widget is PopupMenuItem<Object?>,
              ),
            ),
          );
      expect(moveUp.enabled, isFalse);

      // 菜单里点「下移」真写穿排序：Alpha 从第一行挪到第二行。
      await tester.tap(find.text(t.mihon_source_move_down));
      await tester.pumpAndSettle();
      final List<MangaOnlineSourceRow> rows = await database
          .getMangaOnlineSources();
      expect(
        rows.map((MangaOnlineSourceRow row) => row.name).toList(),
        <String>['Beta source', 'Alpha source'],
      );
      expect(tester.takeException(), null);
    });

    testWidgets('一个扩展源都没有时显示 emptyLabel', (WidgetTester tester) async {
      await database.replaceMangaOnlineSources(
        'org.example.fixture',
        const <MangaOnlineSourcesCompanion>[],
      );
      await manager.reload();
      await pumpSlivers(tester, <Widget>[
        MihonInstalledSourcesSection(
          manager: manager,
          emptyLabel: 'nothing-installed',
        ),
      ]);
      expect(find.text('nothing-installed'), findsOneWidget);
      expect(tester.takeException(), null);
    });
  });
}

MihonAvailableExtension _extension({
  required String name,
  required String packageName,
  required String sourceName,
  String storeUrl = 'https://repo.example/index.json',
  String language = 'ja',
}) => MihonAvailableExtension(
  storeUrl: storeUrl,
  name: name,
  packageName: packageName,
  apkUrl: 'https://repo.example/$packageName.apk',
  iconUrl: '',
  libVersion: '1.6',
  extensionVersionCode: 1,
  versionName: '1.6.1',
  language: language,
  contentWarning: 0,
  sources: <MihonAvailableSource>[
    MihonAvailableSource(
      id: packageName,
      name: sourceName,
      language: language,
      baseUrl: 'https://source.example/$packageName',
    ),
  ],
);

class _PageRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
