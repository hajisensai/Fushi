import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 下拉刷新 = 手动同步必须跟随「同步与备份 + 互联」模块门（反馈 SJeJd5EEZO）。
///
/// 此前门只写在书架页，视频 / 词典页下拉直接调 [runManualSyncWithFeedback]：关了同步
/// 模块，下拉刷新照样跑一轮同步。修复把门收进 [runPullToRefreshSync]，三页只调它。
///
/// 行为用例用 `syncInProgress = true` 区分「门挡住」与「进了同步外壳」：外壳遇到在飞
/// 同步返回 busy、且在碰数据库之前就返回，因此不需要完整初始化的 AppModel；门挡住时
/// 必须返回 notConfigured、根本不进外壳。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory storeDir;
  late PreferencesRepository prefs;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    storeDir = Directory.systemTemp.createTempSync('fushi_pull_sync_gate');
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
      ..wireDatabaseForTesting(db);
    syncInProgress.value = true;
  });

  tearDown(() async {
    syncInProgress.value = false;
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<ManualSyncOutcome> pull(WidgetTester tester) async {
    late ManualSyncOutcome outcome;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  outcome = await runPullToRefreshSync(
                    context: context,
                    appModel: appModel,
                  );
                },
                child: const Text('pull'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pull'));
    await tester.pump();
    return outcome;
  }

  testWidgets('同步模块关掉时下拉不进同步外壳，返回 notConfigured 且不出提示', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() => prefs.setModuleEnabled(ModuleId.sync, false));
    expect(appModel.moduleVisibility.isEnabled(ModuleId.sync), isFalse);

    final ManualSyncOutcome outcome = await pull(tester);

    expect(outcome, ManualSyncOutcome.notConfigured);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('同步模块开着时照常进同步外壳（在飞同步 → busy，不出提示）', (WidgetTester tester) async {
    expect(appModel.moduleVisibility.isEnabled(ModuleId.sync), isTrue);

    final ManualSyncOutcome outcome = await pull(tester);

    expect(outcome, ManualSyncOutcome.busy);
    expect(find.byType(SnackBar), findsNothing);
  });

  test('三个媒体页的下拉刷新只走 runPullToRefreshSync，不直调同步外壳', () {
    const List<String> pages = <String>[
      'lib/src/pages/implementations/home_dictionary_page.dart',
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/reader_history/remote.part.dart',
    ];
    final RegExp directCall = RegExp(r'runManualSyncWithFeedback\s*\(');
    for (final String path in pages) {
      final String source = File(path).readAsStringSync();
      expect(
        directCall.hasMatch(source),
        isFalse,
        reason: '$path 直调 runManualSyncWithFeedback 会绕过同步模块门',
      );
      expect(source, contains('runPullToRefreshSync('), reason: path);
    }
  });
}
