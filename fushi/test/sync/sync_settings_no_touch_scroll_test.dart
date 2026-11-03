import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

// Regression (sync/backup page jumps down on open with the Fushi interconnect
// backend): the page first renders the googleDrive default while
// `_syncSettings.load()` reads the persisted backend asynchronously, then
// reflows TALLER to the real fushiServer layout (server config + LAN + host
// sections). FushiFocusController re-homes the focus cursor during that reflow
// and its reveal scroll-centered a now-lower row — yanking the viewport down.
// In TOUCH mode there is no focus cursor, so passive focus repair must not move
// the scroll offset (mirrors FushiFocusRing, which only reveals in traditional
// highlight mode). Keyboard/gamepad navigation still reveals.
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<double> _settledOffset(
  WidgetTester tester,
  FocusHighlightStrategy strategy, {
  int gamepadDownPresses = 0,
}) async {
  FocusManager.instance.highlightStrategy = strategy;

  final FushiDatabase db = _testDb();
  final PreferencesRepository prefs = PreferencesRepository(db);
  await prefs.loadFromDb();
  final Directory storeDir = Directory.systemTemp.createTempSync('fushi_sync');
  final SyncRepository repo = SyncRepository(db);
  await repo.setBackendType(SyncBackendType.fushiServer);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    const FushiClientUrl(url: 'http://192.168.1.10:38765'),
    const FushiClientUrl(url: 'http://192.168.1.11:38765'),
    const FushiClientUrl(url: 'http://192.168.1.12:38765'),
  ]);

  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
    ..wireDatabaseForTesting(db);
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  final ScrollController controller = ScrollController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Scaffold(
          body: FushiFocusRoot(
            child: SizedBox(
              height: 500,
              child: Consumer(
                builder: (BuildContext context, WidgetRef ref, _) {
                  final SettingsContext sc = SettingsContext(
                    context: context,
                    appModel: ref.read(appProvider),
                    ref: ref,
                    readerSource: ReaderFushiSource.instance,
                    refresh: () {},
                  );
                  return const MaterialSettingsRenderer().buildDetailContent(
                    settingsContext: sc,
                    destination: buildSyncBackupDestination(),
                    scrollController: controller,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
  // Content must genuinely exceed the viewport, else "no scroll" is vacuous.
  expect(controller.position.maxScrollExtent, greaterThan(0));
  if (gamepadDownPresses > 0) {
    // 手柄 / 方向键的显式导航（FushiFocusController.move，与 D-pad 同一入口）
    // 把焦点一路往下推到视口之外，传统高亮模式下 viewport 必须跟随。
    final FushiFocusController focus = FushiFocusRoot.controllerOf(
      tester.element(find.byType(Consumer).first),
    );
    for (int i = 0; i < gamepadDownPresses; i++) {
      focus.move(FushiFocusDirection.down);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }
  return controller.offset;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ppDir;
  setUpAll(() {
    ppDir = Directory.systemTemp.createTempSync('fushi_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => ppDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (ppDir.existsSync()) ppDir.deleteSync(recursive: true);
  });

  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('sync/backup page does not self-scroll on open in touch mode', (
    WidgetTester tester,
  ) async {
    final double offset = await _settledOffset(
      tester,
      FocusHighlightStrategy.alwaysTouch,
    );
    expect(
      offset,
      0,
      reason:
          'touch mode has no focus cursor; the async backend reflow must '
          'not yank the viewport down',
    );
  });

  testWidgets('keyboard/gamepad mode still reveals the focus cursor', (
    WidgetTester tester,
  ) async {
    // 页面顶部是常驻的「启用云备份」开关，开页时焦点就停在它上面、本来就在屏内，
    // 开页本身不再需要滚动；所以这里用手柄方向导航把焦点往下推出视口，验证
    // 传统高亮模式仍会把焦点光标滚进视口。
    final double offset = await _settledOffset(
      tester,
      FocusHighlightStrategy.alwaysTraditional,
      gamepadDownPresses: 20,
    );
    expect(
      offset,
      greaterThan(0),
      reason: 'traditional highlight mode must bring the focused row on-screen',
    );
  });
}
