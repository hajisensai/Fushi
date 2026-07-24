import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/galgame_detail_page.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:hibiki/utils.dart';

import '../helpers/test_platform_services.dart';

/// galgame 详情页守卫（契约 §4.2）：三个 tab 渲染 + 统计 KPI 由会话事实表现算。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppModel> buildModel({bool withSessions = true}) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_game_detail_');
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
        customData: const GalgameCustomData(userRating: 9),
      ),
    ]);
    await appModel.galgameRepo.saveScrapeResult(
      gameId: 'g1',
      source: GalgameMetadataSource.bgm,
      draft: const GalgameMetadataDraft(
        name: 'alpha',
        nameCn: '阿尔法物语',
        summary: '这是简介。',
        aliases: <String>['アルファ'],
        tags: <String>['学园'],
        developer: 'Studio A',
        releaseDate: '2024-03-15',
        score: 8.4,
        externalId: '4885',
      ),
      primarySource: 'bgm',
    );
    if (withSessions) {
      // 两条会话：60s + 300s，最后一次结束于 2026-07-02。
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: DateTime(2026, 7, 1, 20).millisecondsSinceEpoch,
          endMs: DateTime(2026, 7, 1, 21).millisecondsSinceEpoch,
          durationSeconds: 3600,
          dateKey: '2026-07-01',
        ),
      );
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: DateTime(2026, 7, 2, 20).millisecondsSinceEpoch,
          endMs: DateTime(2026, 7, 2, 20, 30).millisecondsSinceEpoch,
          durationSeconds: 1800,
          dateKey: '2026-07-02',
        ),
      );
      await appModel.galgameRepo.load();
    }
    return appModel;
  }

  /// 编辑 tab 的字段定位：按 key 而不是按标签文案（文案随 17 语言翻译漂移）。
  Finder editField(String fieldKey) => find.descendant(
        of: find.byKey(ValueKey<String>('galgame-edit-$fieldKey')),
        matching: find.byType(TextField),
      );

  Future<void> pumpPage(
    WidgetTester tester,
    AppModel appModel, {
    int initialTab = 0,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: GalgameDetailPage(gameId: 'g1', initialTab: initialTab),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('头部显示合并后的元数据，统计 tab 的 KPI 由会话现算', (WidgetTester tester) async {
    await pumpPage(tester, await buildModel());

    // 头部：中文名优先 + 开发商 + 站点评分 + 我的评分。
    expect(find.text('阿尔法物语'), findsWidgets);
    expect(find.textContaining('Studio A'), findsOneWidget);
    expect(find.textContaining('8.4'), findsOneWidget);
    expect(find.textContaining('9.0'), findsOneWidget);

    // KPI：累计 5400 秒 = 1h30m、2 次。
    expect(find.text(t.game_stat_total_time), findsOneWidget);
    expect(find.text(formatStatTime(5400 * 1000)), findsOneWidget);
    expect(find.text(t.game_stat_sessions), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // 柱状图与会话流水都在（流水在折叠线以下，先滚上来）。
    expect(
      find.byWidgetPredicate(
          (Widget w) => w is CustomPaint && w.painter is StatBarChartPainter),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
  });

  testWidgets('无会话时给空态而不是崩', (WidgetTester tester) async {
    await pumpPage(tester, await buildModel(withSessions: false));
    expect(find.text(t.games_never_played), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text(t.game_stat_no_sessions), findsOneWidget);
  });

  testWidgets('简介 tab 展示 summary / 别名 / 发行日', (WidgetTester tester) async {
    await pumpPage(tester, await buildModel(), initialTab: 1);
    expect(find.text('这是简介。'), findsOneWidget);
    expect(find.text(t.game_summary_aliases), findsOneWidget);
    expect(find.text('アルファ'), findsOneWidget);
    expect(find.text(t.game_summary_release_date), findsOneWidget);
    expect(find.text('2024-03-15'), findsWidgets);
  });

  testWidgets('编辑 tab 保存写穿覆盖层与 exe 路径', (WidgetTester tester) async {
    final AppModel appModel = await buildModel();
    await pumpPage(tester, appModel, initialTab: 2);

    expect(find.text(t.game_edit_save), findsOneWidget);
    expect(find.text(t.games_scrape), findsOneWidget);

    await tester.enterText(editField('name'), '我的名字');
    await tester.dragUntilVisible(
      find.byKey(const ValueKey<String>('galgame-edit-exePath')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.enterText(editField('exePath'), r'Z:\a\new.exe');
    await tester.dragUntilVisible(
      find.text(t.game_edit_save),
      find.byType(ListView),
      const Offset(0, 120),
    );
    await tester.tap(find.text(t.game_edit_save));
    await tester.pumpAndSettle();

    final GalgameEntry saved = appModel.galgameRepo.byId('g1')!;
    expect(saved.displayName, '我的名字');
    expect(saved.exePath, r'Z:\a\new.exe');
    // 我的评分是覆盖层里的既有值，保存不能把它抹掉。
    expect(saved.userRating, 9);
    await tester.pump(const Duration(seconds: 4)); // 放掉桌面 toast 计时器
  });

  testWidgets('编辑 tab 拒绝半截发行日', (WidgetTester tester) async {
    final AppModel appModel = await buildModel();
    await pumpPage(tester, appModel, initialTab: 2);

    await tester.dragUntilVisible(
      find.byKey(const ValueKey<String>('galgame-edit-releaseDate')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.enterText(editField('releaseDate'), '2024');
    await tester.dragUntilVisible(
      find.text(t.game_edit_save),
      find.byType(ListView),
      const Offset(0, 120),
    );
    await tester.tap(find.text(t.game_edit_save));
    await tester.pumpAndSettle();

    // 拒绝写入：发行日仍是刮削来的完整日期。
    expect(appModel.galgameRepo.byId('g1')!.releaseDate, '2024-03-15');
    await tester.pump(const Duration(seconds: 4)); // 放掉桌面 toast 计时器
  });

  test('buildGalgameMonthChartData 铺满整月且缺省天为 0', () {
    final List<StatDayData> data = buildGalgameMonthChartData(
      DateTime(2026, 2),
      <String, int>{'2026-02-03': 120},
    );
    expect(data.length, 28);
    expect(data.first.dateKey, '2026-02-01');
    expect(data.last.dateKey, '2026-02-28');
    expect(data[2].ms, 120 * 1000);
    expect(data[0].ms, 0);
  });

  test('parseGalgameTagInput / parseGalgameRating 纯函数', () {
    expect(parseGalgameTagInput(' a, b，b、c '), <String>['a', 'b', 'c']);
    expect(parseGalgameTagInput('   '), isEmpty);
    expect(parseGalgameRating(''), isNull);
    expect(parseGalgameRating('abc'), isNull);
    expect(parseGalgameRating('8.5'), 8.5);
    expect(parseGalgameRating('99'), 10);
    expect(parseGalgameRating('-3'), 0);
  });
}
