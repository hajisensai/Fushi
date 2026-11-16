import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

/// 游戏库点卡（2026-11-16 所有者：与小说同规则）：刮削过的游戏先进详情页
/// （「启动游戏」在那里），没刮削的照旧直接启动、不进详情页。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppModel> buildModel(List<GalgameEntry> games) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir = Directory.systemTemp.createTempSync(
      'fushi_game_scraped_tap_',
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
    await appModel.setGalgames(games);
    // 合并资料来自 `galgame_sources`（元数据刮削写的那张表），setGames 不写它：
    // 给「刮削过」的游戏落一行源再重载仓储缓存。
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'scraped',
        source: 'bgm',
        dataJson: const GalgameMetadataDraft(
          summary: 'A scraped summary.',
          tags: <String>['ADV'],
          score: 8.1,
        ).encode(),
        fetchedAt: 1,
      ),
    );
    await appModel.reloadGalgames();
    expect(appModel.galgameRepo.byId('scraped')!.metadata.isEmpty, isFalse);
    return appModel;
  }

  Future<void> pumpPage(WidgetTester tester, AppModel appModel) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
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
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  List<GalgameEntry> games() => <GalgameEntry>[
    GalgameEntry(
      id: 'scraped',
      name: 'Scraped Game',
      exePath: r'Z:\missing\scraped.exe',
      workdir: r'Z:\missing',
      addedAt: DateTime(2026),
    ),
    GalgameEntry(
      id: 'plain',
      name: 'Plain Game',
      exePath: r'Z:\missing\plain.exe',
      workdir: r'Z:\missing',
      addedAt: DateTime(2026),
    ),
  ];

  testWidgets('刮削过的游戏点卡进详情页', (WidgetTester tester) async {
    final AppModel appModel = await buildModel(games());
    await pumpPage(tester, appModel);

    await tester.tap(find.text('Scraped Game').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(GalgameDetailPage), findsOneWidget);
  });

  testWidgets('没刮削的游戏点卡照旧直接启动，不进详情页', (WidgetTester tester) async {
    final AppModel appModel = await buildModel(games());
    await pumpPage(tester, appModel);

    await tester.tap(find.text('Plain Game').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(GalgameDetailPage), findsNothing);
    // 走的是启动路径：测试机上 exe 不存在（Windows）/ 平台不支持启动（其余），
    // 启动路径各自的提示出现。
    expect(
      find.text(
        Platform.isWindows ? t.game_exe_missing : t.game_launch_unsupported,
      ),
      findsOneWidget,
    );
    // 让启动路径的提示 toast 自己消失（2 s 计时器），别留到树拆掉之后。
    await tester.pump(const Duration(seconds: 3));
  });
}
