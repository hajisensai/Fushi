import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

// Regression (sync/backup page jumps down on open with the Hibiki interconnect
// backend): the page first renders the googleDrive default while
// `_syncSettings.load()` reads the persisted backend asynchronously, then
// reflows TALLER to the real hibikiServer layout (server config + LAN + host
// sections). HibikiFocusController re-homes the focus cursor during that reflow
// and its reveal scroll-centered a now-lower row — yanking the viewport down.
// In TOUCH mode there is no focus cursor, so passive focus repair must not move
// the scroll offset (mirrors HibikiFocusRing, which only reveals in traditional
// highlight mode). Keyboard/gamepad navigation still reveals.
HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<double> _settledOffset(
  WidgetTester tester,
  FocusHighlightStrategy strategy,
) async {
  FocusManager.instance.highlightStrategy = strategy;

  final HibikiDatabase db = _testDb();
  final PreferencesRepository prefs = PreferencesRepository(db);
  await prefs.loadFromDb();
  final Directory storeDir = Directory.systemTemp.createTempSync('hibiki_sync');
  final SyncRepository repo = SyncRepository(db);
  await repo.setBackendType(SyncBackendType.hibikiServer);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    const HibikiClientUrl(url: 'http://192.168.1.10:38765'),
    const HibikiClientUrl(url: 'http://192.168.1.11:38765'),
    const HibikiClientUrl(url: 'http://192.168.1.12:38765'),
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

  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Scaffold(
        body: HibikiFocusRoot(
          child: SizedBox(
            height: 500,
            child: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                final SettingsContext sc = SettingsContext(
                  context: context,
                  appModel: ref.read(appProvider),
                  ref: ref,
                  readerSource: ReaderHibikiSource.instance,
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
  ));

  await tester.pumpAndSettle();
  // Content must genuinely exceed the viewport, else "no scroll" is vacuous.
  expect(controller.position.maxScrollExtent, greaterThan(0));
  return controller.offset;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ppDir;
  setUpAll(() {
    ppDir = Directory.systemTemp.createTempSync('hibiki_pp');
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

  testWidgets('sync/backup page does not self-scroll on open in touch mode',
      (WidgetTester tester) async {
    final double offset =
        await _settledOffset(tester, FocusHighlightStrategy.alwaysTouch);
    expect(
      offset,
      0,
      reason: 'touch mode has no focus cursor; the async backend reflow must '
          'not yank the viewport down',
    );
  });

  testWidgets('keyboard/gamepad mode still reveals the focus cursor',
      (WidgetTester tester) async {
    final double offset =
        await _settledOffset(tester, FocusHighlightStrategy.alwaysTraditional);
    expect(
      offset,
      greaterThan(0),
      reason: 'traditional highlight mode must bring the focused row on-screen',
    );
  });
}
