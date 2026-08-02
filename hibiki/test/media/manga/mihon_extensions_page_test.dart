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

/// keiyoushi 这类真实仓库的索引地址：注意路径里带 `raw`（GitHub 原始文件直链）。
/// BUG-1441 的一半根因就长在这个字符串上——它曾经是可搜字段。
const String _kRepoIndexUrl =
    'https://github.com/keiyoushi/extensions/raw/repo/index.pb';

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

  Future<void> pumpStandalone(WidgetTester tester) async {
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
  }

  testWidgets('search filters extensions by normalized name and package',
      (WidgetTester tester) async {
    await pumpStandalone(tester);

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

  // BUG-1441（其一）：可搜字段里混进了**仓库级**的 `storeUrl`。同一个仓库的每个
  // 扩展 storeUrl 完全一样，于是任何命中该 URL 的查询都会「命中全部」——用户搜
  // 「raw」（想找 RawKuma 这类生肉源），keiyoushi 索引地址里的斜杠 raw 斜杠让 1900
  // 个扩展一个不少地留下来，看上去就是「筛选完全不生效」。
  testWidgets('搜索不吃仓库 URL：搜 raw 只留名字里真有 raw 的扩展', (WidgetTester tester) async {
    manager.available = <MihonAvailableExtension>[
      _extension(
        name: 'RawKuma',
        packageName: 'org.example.rawkuma',
        sourceName: 'RawKuma',
        storeUrl: _kRepoIndexUrl,
      ),
      _extension(
        name: 'AHottie',
        packageName: 'org.example.ahottie',
        sourceName: 'AHottie',
        storeUrl: _kRepoIndexUrl,
      ),
      _extension(
        name: 'Akuma',
        packageName: 'org.example.akuma',
        sourceName: 'Akuma',
        storeUrl: _kRepoIndexUrl,
      ),
    ];
    await pumpStandalone(tester);
    expect(find.text('AHottie'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey<String>('mihon_extension_search_field')),
      'raw',
    );
    await tester.pump();

    expect(find.text('RawKuma'), findsWidgets);
    expect(
      find.text('AHottie'),
      findsNothing,
      reason: '仓库索引地址里的 raw 不该把整个仓库都算作命中',
    );
    expect(find.text('Akuma'), findsNothing);
  });

  // BUG-1441（其二）：语言下拉选 JA 时，实现额外放行 language 为 all 的扩展。
  // keiyoushi 的 all 多是多语言聚合站，于是选了日语整屏还是 all——用户口径同样
  // 是「筛选不生效」。all 现在是下拉里的一个普通选项，选 JA 就只有 JA。
  testWidgets('语言选 JA 不再混进 all 语言的扩展', (WidgetTester tester) async {
    manager.available = <MihonAvailableExtension>[
      _extension(
        name: 'Japanese only',
        packageName: 'org.example.ja',
        sourceName: 'JA source',
        language: 'ja',
      ),
      _extension(
        name: 'Multi language',
        packageName: 'org.example.all',
        sourceName: 'ALL source',
        language: 'all',
      ),
    ];
    await pumpStandalone(tester);
    expect(find.text('Japanese only'), findsOneWidget);
    expect(find.text('Multi language'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    // 展开后的菜单项挂在 Overlay 里（树序在后），关闭态那份在 DropdownButton 自己的
    // IndexedStack 里；`.last` 取的是菜单那份。先 ensureVisible 再点，免得菜单
    // 正好把它排在需要滚动的位置。
    final Finder languageItem =
        find.byKey(const ValueKey<String>('mihon_extension_language_ja')).last;
    await tester.ensureVisible(languageItem);
    await tester.pumpAndSettle();
    // warnIfMissed: false —— 命中的是菜单项外面那层 `_DropdownMenuItemButton`
    // 的 InkWell（真实用户点击也是它接手），DropdownMenuItem 自己不是 hit target。
    await tester.tap(languageItem, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Japanese only'), findsOneWidget);
    expect(find.text('Multi language'), findsNothing);
  });

  // 用户口径：漫画扩展不另开顶层 tab，收进「来源」视图当一节。那一节的宿主是
  // 「来源」视图自己的滚动容器，所以这一页必须能在**外层已在滚动**的语境里渲染：
  // 既不能自带第二层可滚动列表，也不能再摆一套页面 chrome。同时三个页头动作
  // 一个都不能丢。
  //
  // BUG-1441：宿主现在是 CustomScrollView，内嵌节返回 sliver。
  testWidgets('embedded 模式可直接塞进「来源」视图的 CustomScrollView：无 chrome、无自带滚动、动作齐全',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                const SliverToBoxAdapter(child: Text('outer-section-above')),
                MihonExtensionsPage(manager: manager, embedded: true),
                const SliverToBoxAdapter(child: Text('outer-section-below')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 真渲染出扩展条目，不是空壳。
    expect(find.text('フェイト Extension'), findsOneWidget);
    // 上下两节都在——说明它没有把外层滚动容器撑爆或吞掉兄弟节点。
    expect(find.text('outer-section-above'), findsOneWidget);
    expect(find.text('outer-section-below'), findsOneWidget);
    // 整棵树只有外层那一个纵向滚动容器：内嵌节不得再嵌一层。
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    // 页头三动作降级成本节顶部按钮行，能力不减。
    expect(find.text(t.mihon_store_refresh), findsWidgets);
    expect(find.text(t.mihon_extension_import), findsWidgets);
    expect(find.text(t.mihon_store_add), findsWidgets);
    // 反向锚：独立页形态才有 chrome，内嵌形态一层都不能有。
    expect(find.byType(HibikiPageHeader), findsNothing);
    expect(find.byType(DesktopContentLayout), findsNothing);
    expect(tester.takeException(), null);
  });

  // BUG-1441（其三，也是「下拉框很卡」的真正来源）：内嵌节以前是裸 Column，
  // keiyoushi 的 1900+ 个扩展会全部实体化成 RenderObject —— Column 没有视口
  // 裁剪，每帧都要布局并绘制全部条目。这条守卫锚在「视口外的条目根本没被建出来」
  // 上：改回 Column（或任何非 sliver 容器）都会让它变红。
  testWidgets('内嵌节懒建：视口外的扩展不进 widget 树', (WidgetTester tester) async {
    manager.available = <MihonAvailableExtension>[
      for (int i = 0; i < 300; i++)
        _extension(
          name: 'Extension $i',
          packageName: 'org.example.e$i',
          sourceName: 'Source $i',
        ),
    ];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                MihonExtensionsPage(manager: manager, embedded: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Extension 0'), findsOneWidget);
    expect(
      find.text('Extension 299'),
      findsNothing,
      reason: '末尾条目远在视口之外，懒建的话根本不该存在于 widget 树里',
    );
  });
}

MihonAvailableExtension _extension({
  required String name,
  required String packageName,
  required String sourceName,
  String storeUrl = 'https://repo.example/index.json',
  String language = 'ja',
}) =>
    MihonAvailableExtension(
      storeUrl: storeUrl,
      name: name,
      packageName: packageName,
      apkUrl: 'https://repo.example/$packageName.apk',
      iconUrl: '',
      libVersion: '1.6',
      versionCode: 1,
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
