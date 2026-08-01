import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late Directory root;
  late HibikiDatabase database;
  late MihonManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('hibiki-mihon-extensions-');
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
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
        name: 'フェイト Extension',
        packageName: 'org.example.fate',
        sourceName: 'Moon source',
      ),
      _extension(
        name: 'Unrelated extension',
        packageName: 'org.example.package-hit',
        sourceName: 'Other source',
      ),
    ];
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('search filters extensions by normalized name and package',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: MihonExtensionsPage(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('フェイト Extension'), findsOneWidget);
    expect(find.text('Unrelated extension'), findsOneWidget);

    final Finder search =
        find.byKey(const ValueKey<String>('mihon_extension_search_field'));
    await tester.enterText(search, 'ふぇいと');
    await tester.pump();

    expect(find.text('フェイト Extension'), findsOneWidget);
    expect(find.text('Unrelated extension'), findsNothing);

    await tester.enterText(search, 'package hit');
    await tester.pump();

    expect(find.text('フェイト Extension'), findsNothing);
    expect(find.text('Unrelated extension'), findsOneWidget);
  });

  // 用户口径：漫画扩展不另开顶层 tab，收进「来源」视图当一节。那一节的宿主是
  // 「来源」视图自己的 ListView，所以这一页必须能在**无界高度 + 外层已在滚动**
  // 的语境里渲染：既不能自带第二层可滚动列表（嵌套滚动 = 约束异常），也不能再
  // 摆一套页面 chrome（外层已有页头）。同时三个页头动作一个都不能丢。
  testWidgets('embedded 模式可直接塞进「来源」视图的 ListView：无 chrome、无自带滚动、动作齐全',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                const Text('outer-section-above'),
                MihonExtensionsPage(manager: manager, embedded: true),
                const Text('outer-section-below'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 真渲染出扩展条目，不是空壳。
    expect(find.text('フェイト Extension'), findsOneWidget);
    // 上下两节都在——说明它没有把外层 ListView 撑爆或吞掉兄弟节点。
    expect(find.text('outer-section-above'), findsOneWidget);
    expect(find.text('outer-section-below'), findsOneWidget);
    // 整棵树只有外层那一个可滚动体：内嵌节不得再嵌一层。
    expect(find.byType(Scrollable), findsOneWidget);
    // 页头三动作降级成本节顶部按钮行，能力不减。
    expect(find.text(t.mihon_store_refresh), findsWidgets);
    expect(find.text(t.mihon_extension_import), findsWidgets);
    expect(find.text(t.mihon_store_add), findsWidgets);
    // 反向锚：独立页形态才有 chrome，内嵌形态一层都不能有。
    expect(find.byType(HibikiPageHeader), findsNothing);
    expect(find.byType(DesktopContentLayout), findsNothing);
    expect(tester.takeException(), null);
  });
}

MihonAvailableExtension _extension({
  required String name,
  required String packageName,
  required String sourceName,
}) =>
    MihonAvailableExtension(
      storeUrl: 'https://repo.example/index.json',
      name: name,
      packageName: packageName,
      apkUrl: 'https://repo.example/$packageName.apk',
      iconUrl: '',
      libVersion: '1.6',
      versionCode: 1,
      versionName: '1.6.1',
      language: 'ja',
      contentWarning: 0,
      sources: <MihonAvailableSource>[
        MihonAvailableSource(
          id: packageName,
          name: sourceName,
          language: 'ja',
          baseUrl: 'https://source.example/$packageName',
        ),
      ],
    );

class _PageRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
