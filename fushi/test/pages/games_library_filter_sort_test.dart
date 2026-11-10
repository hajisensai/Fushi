import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

import '../helpers/test_platform_services.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 游戏库页工具条守卫（契约 §4.1）：搜索命中、排序切换、状态筛选三条真实用户路径。
///
/// 全部经真 [GamesLibraryPage] + 真 Drift 表（内存库）走，不 mock 仓储——库页读的
/// 是不是表、排序筛选有没有真接上纯函数，都由这一层钉死。
void main() {
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppModel> buildModel() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir = Directory.systemTemp.createTempSync(
      'fushi_games_toolbar_',
    );
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db);

    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'alpha',
        exePath: r'Z:\a\alpha.exe',
        workdir: r'Z:\a',
        addedAt: DateTime(2026, 1, 1),
        playStatus: GalgamePlayStatus.playing,
        customData: const GalgameCustomData(tags: <String>['学园']),
      ),
      GalgameEntry(
        id: 'g2',
        name: 'beta',
        exePath: r'Z:\b\beta.exe',
        workdir: r'Z:\b',
        addedAt: DateTime(2026, 1, 2),
        playStatus: GalgamePlayStatus.dropped,
      ),
    ]);
    // 给 g2 一份刮削快照：证明搜索能命中中文名/别名，排序能读站点评分。
    await appModel.galgameRepo.saveScrapeResult(
      gameId: 'g2',
      source: GalgameMetadataSource.bgm,
      draft: const GalgameMetadataDraft(
        name: 'beta',
        nameCn: '贝塔物语',
        aliases: <String>['ベータ'],
        score: 9.1,
      ),
      primarySource: 'bgm',
    );
    return appModel;
  }

  /// 只在网格里找卡片标题：搜索框里刚敲进去的同名文字也是一个 Text，
  /// 不限定祖先会把它一起数进来（findsOneWidget 直接红）。
  /// 游戏进合集后网格改为 CustomScrollView 分区（合集横排行 + 散卡 SliverGrid），
  /// 祖先随之从 GridView 换成 CustomScrollView，语义不变。
  Finder cardTitle(String title) => find.descendant(
    of: find.byType(CustomScrollView),
    matching: find.text(title),
  );

  Future<void> pumpPage(
    WidgetTester tester,
    AppModel appModel, {
    bool embedded = false,
  }) async {
    navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: FushiFocusRoot(child: GamesLibraryPage(embedded: embedded)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('搜索命中原名 / 中文名 / 别名，不命中的卡片消失', (WidgetTester tester) async {
    await pumpPage(tester, await buildModel());
    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('贝塔物语'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('贝塔物语'), findsNothing);

    // 别名（片假名）命中刮削过的那条。
    await tester.enterText(find.byType(TextField), 'ベータ');
    await tester.pumpAndSettle();
    expect(cardTitle('贝塔物语'), findsOneWidget);
    expect(cardTitle('alpha'), findsNothing);

    // 谁都不命中时给「没有符合筛选」的空态，而不是空库文案。
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text(t.game_no_match), findsOneWidget);
    expect(find.text(t.game_empty), findsNothing);
  });

  testWidgets('排序切换：按名称升序 → 再点同项翻成降序', (WidgetTester tester) async {
    await pumpPage(tester, await buildModel());

    Future<void> pickSort(String label) async {
      await tester.tap(find.byIcon(FushiIcons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await pickSort(t.game_sort_name);
    // 'alpha' < '贝塔物语'（归一化后按码位比较），升序时排在前面。
    expect(
      tester.getTopLeft(cardTitle('alpha')).dx,
      lessThan(tester.getTopLeft(cardTitle('贝塔物语')).dx),
    );

    // 再点当前维度 = 翻转方向。
    await pickSort(t.game_sort_name);
    expect(
      tester.getTopLeft(cardTitle('alpha')).dx,
      greaterThan(tester.getTopLeft(cardTitle('贝塔物语')).dx),
    );
  });

  testWidgets('状态筛选只留在玩，且偏好写穿 DB', (WidgetTester tester) async {
    final AppModel appModel = await buildModel();
    await pumpPage(tester, appModel);

    await tester.tap(find.byIcon(FushiIcons.filter));
    await tester.pumpAndSettle();
    // 卡片封面上的状态角标也写着「在玩」：筛选面板在最上层，取最后一个。
    await tester.tap(
      find.text(galgamePlayStatusLabel(GalgamePlayStatus.playing)).last,
    );
    await tester.pumpAndSettle();
    navKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('贝塔物语'), findsNothing);

    // 筛选偏好持久化（下次进页面还在）。
    final GalgameLibraryView saved = GalgameLibraryView.decode(
      appModel.galgameLibraryView,
    );
    expect(saved.status, GalgamePlayStatus.playing);
  });

  // 2026-10 体验优化：窄屏工具条两行（搜索独占一行），刮削 / 排序收进溢出菜单。
  testWidgets('窄屏：搜索框独占一行，排序经溢出菜单仍可切换', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester, await buildModel());

    expect(
      find.byKey(const ValueKey<String>('games_toolbar_compact')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('games_filter_play_status')),
      findsOneWidget,
    );
    // 搜索框拿到近整行宽（旧单行布局里被挤到只剩百余像素）。
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(340));
    // 排序 / 刮削不再平铺在工具条上。
    expect(find.byIcon(FushiIcons.sort), findsNothing);

    Future<void> pickSortFromOverflow() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('games_toolbar_overflow')),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.scrape_all), findsOneWidget);
      await tester.tap(find.text(t.game_sort_name).last);
      await tester.pumpAndSettle();
    }

    await pickSortFromOverflow();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(cardTitle('alpha')).dx,
      lessThan(tester.getTopLeft(cardTitle('贝塔物语')).dx),
    );
    await pickSortFromOverflow();
    expect(
      tester.getTopLeft(cardTitle('alpha')).dx,
      greaterThan(tester.getTopLeft(cardTitle('贝塔物语')).dx),
    );
  });

  // BUG-4277：「管理合集」页列的是本域全部合集，成员数取库页**未筛选**全量的
  // 折叠结果。旧实现在网格 sliver 里发布筛选后的折叠：库页一搜索，合集卡只剩
  // 命中的那一张，管理页就跟着变成「共 1 项」（其它合集 0 项、旁边挂着删除）；
  // 筛选空态不建网格，又会留着上一次的旧数。
  testWidgets('管理合集页成员数不随库页搜索变', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppModel appModel = await buildModel();
    final FushiDatabase db = appModel.database;
    final int series = await db.createMediaCollection('series');
    await db.addToCollection(series, MediaKind.game, 'g1');
    await db.addToCollection(series, MediaKind.game, 'g2');
    // 「管理合集」入口在游戏 tab 的单行页头里（embedded），搜索也是页头 🔍。
    await pumpPage(tester, appModel, embedded: true);

    // 只有 alpha 命中：库页合集卡此刻只折进 1 个成员。
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi-header-search-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(cardTitle('贝塔物语'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_collection_manage')),
    );
    await tester.pumpAndSettle();

    final Finder row = find.byKey(
      ValueKey<String>('collection-manage-row-$series'),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.text(t.collection_detail_member_count(n: 2)),
      ),
      findsOneWidget,
    );
  });
}
