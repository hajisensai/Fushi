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
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

// Regression (BUG-037 — sync/backup page "jumps" while scrolling up/down on
// touch): the own-scrolling settings detail used a LAZY `ListView.builder`.
// `RenderSliverList` only lays out visible children and ESTIMATES the extent of
// the off-screen ones from the average of the laid-out children. The sync page's
// sections have wildly unequal heights (a 1-row toggle vs. the tall LAN
// discovery / URL list / server-config widgets), so that estimate — and thus
// `maxScrollExtent` — DRIFTS as you scroll. A fling computed against one extent
// gets re-clamped when the extent changes mid-flight, which the eye sees as the
// content jumping. The fix lays out every section (non-lazy
// SingleChildScrollView + Column), so the extent is exact and constant. This
// test pins that: `maxScrollExtent` must be identical at the top, middle, and
// bottom of the same content.
HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<ScrollController> _pumpSyncDetail(
  WidgetTester tester,
  SettingsRenderer renderer,
) async {
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;

  final HibikiDatabase db = _testDb();
  final PreferencesRepository prefs = PreferencesRepository(db);
  await prefs.loadFromDb();
  final Directory storeDir = Directory.systemTemp.createTempSync('hibiki_sync');
  final SyncRepository repo = SyncRepository(db);
  await repo.setBackendType(SyncBackendType.hibikiServer);
  // Several URLs → a tall, variable-height URL list, exaggerating the unequal
  // section heights that destabilise a lazy list's extent estimate.
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    const HibikiClientUrl(url: 'http://192.168.1.10:38765'),
    const HibikiClientUrl(url: 'http://192.168.1.11:38765'),
    const HibikiClientUrl(url: 'http://192.168.1.12:38765'),
    const HibikiClientUrl(url: 'http://192.168.1.13:38765'),
    const HibikiClientUrl(url: 'http://192.168.1.14:38765'),
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
            height: 360,
            child: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                final SettingsContext sc = SettingsContext(
                  context: context,
                  appModel: ref.read(appProvider),
                  ref: ref,
                  readerSource: ReaderHibikiSource.instance,
                  refresh: () {},
                );
                return renderer.buildDetailContent(
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
  return controller;
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

  // 两个渲染器的自滚动详情路径（shrinkWrap:false）都吃这条修复：Material 走窄屏
  // push 页 + 宽屏主从，Cupertino 走宽屏 master-detail（iPad/macOS-Cupertino）。
  for (final ({String name, SettingsRenderer renderer}) variant
      in <({String name, SettingsRenderer renderer})>[
    (name: 'material', renderer: const MaterialSettingsRenderer()),
    (name: 'cupertino', renderer: const CupertinoSettingsRenderer()),
  ]) {
    testWidgets(
        '${variant.name}: sync/backup detail keeps a stable scroll extent at '
        'every offset', (WidgetTester tester) async {
      final ScrollController controller =
          await _pumpSyncDetail(tester, variant.renderer);

      final double maxTop = controller.position.maxScrollExtent;
      expect(maxTop, greaterThan(0), reason: '内容必须超出视口，否则 extent 稳定性断言为空');

      controller.jumpTo(maxTop / 2);
      await tester.pumpAndSettle();
      final double maxMid = controller.position.maxScrollExtent;

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final double maxBottom = controller.position.maxScrollExtent;

      // 懒加载变高列表：maxScrollExtent 随布局到的子项不同而漂移 → 弹道落点被重
      // clamp → 视觉跳跃。非懒加载（全 section 布局）下三处必须逐像素相等。
      expect(maxMid, maxTop,
          reason: '滚到中部后 extent 从 $maxTop 漂移到 $maxMid（懒加载估算不稳）');
      expect(maxBottom, maxTop,
          reason: '滚到底部后 extent 从 $maxTop 漂移到 $maxBottom（懒加载估算不稳）');
    });
  }
}
