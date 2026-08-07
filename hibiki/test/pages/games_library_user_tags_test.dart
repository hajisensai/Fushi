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
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/pages/implementations/tag_picker_page.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1113「游戏没有标签」的 UI 侧守卫：游戏库页必须接上书架 / 视频页那套**共享**
/// 用户标签体系——同一个 [FushiTagFilterBar]、同一个标签池、同一套 AND 筛选、
/// 同一个 [TagPickerPage] 打标签入口。
///
/// 全部经真 [GamesLibraryPage] + 真 Drift 表（内存库）走，不 mock：接没接上、筛没筛
/// 中、入口通不通，由这一层钉死。
void main() {
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<(AppModel, FushiDatabase)> buildModel() async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_games_user_tags_');
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
      ),
      GalgameEntry(
        id: 'g2',
        name: 'beta',
        exePath: r'Z:\b\beta.exe',
        workdir: r'Z:\b',
        addedAt: DateTime(2026, 1, 2),
      ),
    ]);
    return (appModel, db);
  }

  Finder cardTitle(String title) => find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.text(title),
      );

  Future<void> pumpPage(WidgetTester tester, AppModel appModel) async {
    navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const FushiFocusRoot(child: GamesLibraryPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('游戏库顶部渲染共享标签筛选栏，标签 chip 出自共享标签池', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    await db.createTag('神作', 0xFFEF5350);
    await pumpPage(tester, appModel);

    expect(find.byType(FushiTagFilterBar), findsOneWidget,
        reason: '必须复用书架/视频页同一组件，而不是游戏页自己手搓一条');
    expect(
      find.descendant(
        of: find.byType(FushiTagFilterBar),
        matching: find.text('神作'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('点标签 chip 只留挂了该标签的游戏，再点取消恢复全部', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    final int tagId = await db.createTag('神作', 0xFFEF5350);
    await db.addTagToGame('g1', tagId);
    await pumpPage(tester, appModel);

    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('beta'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(FushiTagFilterBar),
      matching: find.text('神作'),
    ));
    await tester.pumpAndSettle();

    expect(cardTitle('alpha'), findsOneWidget, reason: 'g1 挂了该标签');
    expect(cardTitle('beta'), findsNothing, reason: 'g2 没挂，必须被筛掉');

    await tester.tap(find.descendant(
      of: find.byType(FushiTagFilterBar),
      matching: find.text('神作'),
    ));
    await tester.pumpAndSettle();

    expect(cardTitle('alpha'), findsOneWidget);
    expect(cardTitle('beta'), findsOneWidget);
  });

  testWidgets('全部游戏都不挂选中标签时给「没有符合筛选」空态，而不是空库文案', (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    await db.createTag('神作', 0xFFEF5350);
    await pumpPage(tester, appModel);

    await tester.tap(find.descendant(
      of: find.byType(FushiTagFilterBar),
      matching: find.text('神作'),
    ));
    await tester.pumpAndSettle();

    // i18n key 是 game_*（命名术语表禁用 games_ 前缀），生产代码用的也是
    // games_library_page.dart:772/798 的 t.game_empty / t.game_no_match。
    expect(find.text(t.game_no_match), findsOneWidget);
    expect(find.text(t.game_empty), findsNothing);
  });

  testWidgets('卡片菜单有「标签」项，点开进共享 TagPickerPage 并真写穿 DB',
      (WidgetTester tester) async {
    final (AppModel appModel, FushiDatabase db) = await buildModel();
    final int tagId = await db.createTag('神作', 0xFFEF5350);
    await pumpPage(tester, appModel);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text(t.tag_label), findsOneWidget);

    await tester.tap(find.text(t.tag_label));
    await tester.pumpAndSettle();
    expect(find.byType(TagPickerPage), findsOneWidget,
        reason: '复用书/视频/合集那张选择器，不另做一套游戏专用的');

    // 勾上标签：必须真落 galgame_tag_mappings（不是只改本地 state）。
    await tester.tap(find.text('神作'));
    await tester.pumpAndSettle();

    final List<BookTagRow> tags = await db.getTagsForGame('g1');
    expect(tags.map((BookTagRow t) => t.id).toList(), <int>[tagId]);
  });
}
