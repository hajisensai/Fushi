import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare_action.dart';
import 'package:fushi/src/media/novel/online/lnreader_extensions_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_installed_sources_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/utils.dart';

import 'fake_lnreader_runtime.dart';

/// 小说源三段与浏览页的真渲染：行用的是和漫画 / 视频同一个
/// [MangaExtensionManagementTile]、内置仓库不给删改、开关真写穿、浏览按模式分派。
/// 导入页接线（book 域才挂、过合规门）由 `ios_store_compliance_guard_test` 守。
void main() {
  late Directory root;
  late FakeLnReaderRuntime runtime;
  late LnReaderManager manager;

  const String builtin = 'https://builtin.example/plugins.min.json';

  LnReaderRepoPlugin repoPlugin(
    String id,
    String lang, {
    String version = '1.0.0',
  }) => LnReaderRepoPlugin(
    id: id,
    name: id,
    site: 'https://$id.example/',
    lang: lang,
    version: version,
    url: 'https://$id.example/p.js',
    iconUrl: '',
    storeUrl: builtin,
  );

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('lnreader_ui_test');
    runtime = FakeLnReaderRuntime(
      items: const <LnReaderNovelItem>[
        LnReaderNovelItem(name: 'Novel A', path: '/a'),
        LnReaderNovelItem(name: 'Novel B', path: '/b'),
      ],
    );
    // 预置一个已装插件（state.json + 源码文件），其余目录由 debugSetAvailable 给。
    await File('${root.path}/state.json').writeAsString(
      '{"stores":[],"installed":[{"id":"syosetu","name":"Syosetu",'
      '"site":"https://syosetu.example/","lang":"日本語","version":"1.0.0",'
      '"url":"","iconUrl":"","storeUrl":"$builtin","enabled":true,'
      '"pinned":false,"sortOrder":0,"installedAt":0}]}',
    );
    manager = LnReaderManager(
      rootDirectory: root,
      runtime: runtime,
      httpClientFactory: HttpClient.new,
      builtinStoreUrl: builtin,
    );
    await manager.initialise();
    await manager.pluginFile('syosetu').create(recursive: true);
    manager.debugSetAvailable(<LnReaderRepoPlugin>[
      repoPlugin('syosetu', '日本語', version: '1.2.0'),
      repoPlugin('kakuyomu', '日本語'),
      repoPlugin('royalroad', 'English'),
    ]);
  });

  tearDown(() async {
    manager.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: child,
        ),
      ),
    );
    await tester.pump();
  }

  /// 等真实 IO（插件源码读盘 → 假运行时）落定。页面的续体排在 FakeAsync 区，
  /// 只有 pump 才冲洗；真实 IO 只在 runAsync 里推进——所以两者交替，条件达成即
  /// 返回，5 秒兜底失败。
  Future<void> untilCalled(WidgetTester tester, String call) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!runtime.calls.contains(call)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('runtime never received $call (got ${runtime.calls})');
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    // 结果回来后的 setState 再出一帧。
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpSlivers(WidgetTester tester, List<Widget> slivers) =>
      pump(tester, Scaffold(body: CustomScrollView(slivers: slivers)));

  testWidgets('仓库段：内置仓库带「内置」标记且没有编辑 / 删除按钮', (WidgetTester tester) async {
    await pumpSlivers(tester, <Widget>[
      LnReaderExtensionsSection(
        manager: manager,
        showStores: true,
        showCatalog: false,
      ),
    ]);
    expect(find.textContaining(t.novel_store_builtin_label), findsOneWidget);
    expect(find.byTooltip(t.mihon_store_remove), findsNothing);
    expect(find.byTooltip(t.mihon_store_edit), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is FushiIconButton && w.label == t.mihon_store_add,
      ),
      findsOneWidget,
    );
    expect(find.byType(MangaExtensionManagementTile), findsNothing);
  });

  testWidgets('扩展段：共享扩展行 + 已装排前 + 有更新显示版本跳变 + 语言筛选生效', (
    WidgetTester tester,
  ) async {
    await pumpSlivers(tester, <Widget>[
      LnReaderExtensionsSection(
        manager: manager,
        showStores: false,
        showCatalog: true,
      ),
    ]);
    final Finder tiles = find.byType(MangaExtensionManagementTile);
    expect(tiles, findsNWidgets(3));
    expect(
      tester.widget<MangaExtensionManagementTile>(tiles.first).title,
      'syosetu',
      reason: '已装的排在目录最前。',
    );
    expect(find.text('日本語 · 1.0.0 → 1.2.0 · syosetu.example'), findsOneWidget);
    expect(find.text(t.mihon_extension_update), findsOneWidget);
    expect(find.text(t.mihon_extension_install), findsNWidgets(2));

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENGLISH').last);
    await tester.pumpAndSettle();
    expect(find.byType(MangaExtensionManagementTile), findsOneWidget);
    expect(find.text('royalroad'), findsOneWidget);
  });

  testWidgets('在线源段：开关真写穿，点行进源，停用的行不可点', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await pumpSlivers(tester, <Widget>[
      LnReaderInstalledSourcesSection(
        manager: manager,
        onOpenSource: (LnReaderInstalledPlugin plugin) => opened.add(plugin.id),
      ),
    ]);
    expect(find.text('Syosetu'), findsOneWidget);
    await tester.tap(find.text('Syosetu'));
    expect(opened, <String>['syosetu']);

    await tester.runAsync(() async {
      await manager.setEnabled(manager.installed.single, false);
    });
    await tester.pump();
    expect(
      File('${root.path}/state.json').readAsStringSync(),
      contains('"enabled": false'),
    );
    await tester.tap(find.text('Syosetu'));
    expect(opened, <String>['syosetu'], reason: '停用的源不能进浏览页。');
  });

  testWidgets('浏览页：热门进页即拉，切最新 / 提交搜索各走各的调用面', (WidgetTester tester) async {
    await pump(
      tester,
      LnReaderSourceBrowsePage(
        manager: manager,
        plugin: manager.installed.single,
      ),
    );
    await untilCalled(tester, 'popular:1:false');
    expect(find.text('Novel A'), findsOneWidget);
    expect(runtime.calls.first, 'popular:1:false');
    expect(
      runtime.popularFilters.first,
      isNull,
      reason: '用户没动筛选时不传，宿主会补插件自带的默认值。',
    );

    await tester.tap(find.text(t.mihon_source_latest));
    await untilCalled(tester, 'popular:1:true');

    await tester.enterText(
      find.byKey(const ValueKey<String>('novel_browse_search_field')),
      '異世界',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await untilCalled(tester, 'search:異世界:1');
  });

  testWidgets('下载范围对话框：默认全部，从某章起时区间从那一章开始', (WidgetTester tester) async {
    const List<LnReaderChapter> chapters = <LnReaderChapter>[
      LnReaderChapter(name: '一', path: '/1'),
      LnReaderChapter(name: '二', path: '/2'),
      LnReaderChapter(name: '三', path: '/3'),
    ];
    RangeValues? result;
    await pump(
      tester,
      Builder(
        builder: (BuildContext context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showDialog<RangeValues>(
                context: context,
                builder: (_) => const LnReaderChapterRangeDialog(
                  chapters: chapters,
                  initialStart: 1,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text(t.novel_download_range_hint(from: 2, to: 3, count: 2)),
      findsOneWidget,
    );
    await tester.tap(find.text(t.novel_download_range_all));
    await tester.pump();
    expect(
      find.text(t.novel_download_range_hint(from: 1, to: 3, count: 3)),
      findsOneWidget,
    );
    await tester.tap(find.text(t.novel_download_start));
    await tester.pumpAndSettle();
    expect(result, const RangeValues(0, 2));
  });

  test('连载状态：标准值本地化、Unknown 不显示、非标准值原样', () {
    expect(lnReaderStatusLabel(null), isNull);
    expect(lnReaderStatusLabel('Unknown'), isNull);
    expect(lnReaderStatusLabel('Ongoing'), t.novel_status_ongoing);
    expect(lnReaderStatusLabel('On Hiatus'), t.novel_status_on_hiatus);
    expect(
      lnReaderStatusLabel('Publishing Finished'),
      t.novel_status_publishing_finished,
    );
    expect(lnReaderStatusLabel('連載中（毎週更新）'), '連載中（毎週更新）');
  });

  LnReaderCloudflare newCloudflare() =>
      LnReaderCloudflare(MangaCookieJar(File('${root.path}/cookies.json')));

  LnReaderCloudflareChallenge challenge() => LnReaderCloudflareChallenge(
    url: Uri.parse('https://syosetu.example/rank'),
    userAgent: 'PluginUA/1',
  );

  const ValueKey<String> verifyKey = ValueKey<String>(
    'novel_source_cloudflare_verify_syosetu',
  );

  testWidgets('浏览页：被 Cloudflare 拦下回空列表时给出「站点验证」，未拦时不占位', (
    WidgetTester tester,
  ) async {
    runtime.items = const <LnReaderNovelItem>[];
    final LnReaderCloudflare cloudflare = newCloudflare();
    final LnReaderManager guarded = LnReaderManager(
      rootDirectory: root,
      runtime: runtime,
      httpClientFactory: HttpClient.new,
      builtinStoreUrl: builtin,
      cloudflare: cloudflare,
    );
    addTearDown(guarded.dispose);
    // 真实文件 IO 在 FakeAsync 区里永远不完成，必须出区跑。
    await tester.runAsync(guarded.initialise);
    await pump(
      tester,
      LnReaderSourceBrowsePage(
        manager: guarded,
        plugin: guarded.installed.single,
      ),
    );
    await untilCalled(tester, 'popular:1:false');
    expect(find.text(t.novel_source_no_results), findsOneWidget);
    expect(find.byKey(verifyKey), findsNothing);

    // 桥在这次调用里撞上挑战（fetchText 吞掉 403，插件只回空列表）。
    cloudflare.record('syosetu', challenge());
    await tester.tap(find.text(t.mihon_source_latest));
    await untilCalled(tester, 'popular:1:true');
    expect(find.byKey(verifyKey), findsOneWidget);
  });

  testWidgets('站点验证：同 UA 打开被拦地址，解开后挑战作废并重新加载', (WidgetTester tester) async {
    final LnReaderCloudflare cloudflare = newCloudflare()
      ..record('syosetu', challenge());
    LnReaderCloudflareChallenge? opened;
    int reloads = 0;
    await pump(
      tester,
      Scaffold(
        body: LnReaderCloudflareAction(
          cloudflare: cloudflare,
          pluginId: 'syosetu',
          onVerified: () => reloads++,
          pageBuilder: (LnReaderCloudflareChallenge challenge) {
            opened = challenge;
            return Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('solved'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byKey(verifyKey));
    await tester.pumpAndSettle();
    expect(opened?.url.toString(), 'https://syosetu.example/rank');
    expect(opened?.userAgent, 'PluginUA/1');
    await tester.tap(find.text('solved'));
    await tester.pumpAndSettle();
    expect(reloads, 1);
    expect(cloudflare.challengeFor('syosetu'), isNull);
  });
}
