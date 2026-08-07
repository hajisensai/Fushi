import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

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
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_games_toolbar_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
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

  Future<void> pumpPage(WidgetTester tester, AppModel appModel) async {
    navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const HibikiFocusRoot(child: GamesLibraryPage()),
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
      await tester.tap(find.byIcon(Icons.sort));
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

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester
        .tap(find.text(galgamePlayStatusLabel(GalgamePlayStatus.playing)));
    await tester.pumpAndSettle();
    navKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('贝塔物语'), findsNothing);

    // 筛选偏好持久化（下次进页面还在）。
    final GalgameLibraryView saved =
        GalgameLibraryView.decode(appModel.galgameLibraryView);
    expect(saved.status, GalgamePlayStatus.playing);
  });
}
