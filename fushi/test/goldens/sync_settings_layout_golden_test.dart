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
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 同步/互联设置页排版的 golden 基线（C 系列重组的改前/改后对照）。
///
/// 两页各出宽窄两档：900 宽 ≈ 桌面主从布局的详情 pane，400 宽 ≈ 手机单列。
/// 高度按档给足（宽 2400、窄 3800），让整页内容一次落在图里（详情容器是非懒
/// 加载的 SingleChildScrollView，见 BUG-037），改前/改后的总长度一眼可比。
/// 页面长高到装不下时 [_expectWholePageVisible] 直接报红，而不是让 golden
/// 悄悄只截到上半页（BUG-3494：窄档曾被截掉约 650px 无人察觉）。
///
/// 数据：同步页选 WebDAV（把凭据表单显示出来）；互联页开总开关 + 5 个对端地址
/// （把最高的对端列表撑出来）。字体是测试字体（Ahem），只比排版不比字形。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<void> _pumpDetail(
  WidgetTester tester, {
  required SettingsDestination Function() destination,
  required double width,
  required double height,
  required Future<void> Function(SyncRepository repo) seed,
}) async {
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final FushiDatabase db = _testDb();
  final PreferencesRepository prefs = PreferencesRepository(db);
  await prefs.loadFromDb();
  final Directory storeDir = Directory.systemTemp.createTempSync(
    'fushi_sync_golden',
  );
  await seed(SyncRepository(db));

  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('light'),
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

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
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
            // refresh 必须真的重建：同步设置内存态异步 load 完成后靠它重算各节的
            // 可见性谓词（互联页整页都门控在「互联已启用」上）。
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) => Consumer(
                builder: (BuildContext context, WidgetRef ref, _) {
                  final SettingsContext sc = SettingsContext(
                    context: context,
                    appModel: ref.read(appProvider),
                    ref: ref,
                    readerSource: ReaderFushiSource.instance,
                    refresh: () => setState(() {}),
                  );
                  return const MaterialSettingsRenderer().buildDetailContent(
                    settingsContext: sc,
                    destination: destination(),
                    scrollController: ScrollController(),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // 不用 pumpAndSettle：互联页有常驻动画（LAN 发现的进度指示），永远 settle 不了。
  // 有界地多推几帧，让异步 load（偏好、凭据、对端列表）都落地即可。
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // 测试字体 Ahem 让文字比真机宽约 50%，窄屏下个别行尾按钮会 RenderFlex 溢出——
  // 那是字体伪影不是排版回归，这里只比排版，把它 drain 掉（真机字宽由 C2 复核）。
  Object? e;
  while ((e = tester.takeException()) != null) {
    debugPrint('[sync-golden] drained: $e');
  }
}

/// 断言竖向滚动区都没有可滚余量：整页确实落在截图里。
void _expectWholePageVisible(WidgetTester tester) {
  for (final ScrollableState scrollable in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    if (scrollable.position.axis != Axis.vertical) continue;
    expect(
      scrollable.position.maxScrollExtent,
      0,
      reason: 'page no longer fits the golden viewport; raise its height',
    );
  }
}

Future<void> _seedSyncPage(SyncRepository repo) async {
  await repo.setBackendType(SyncBackendType.webDav);
  await repo.setWebDavUrl('https://dav.example.com/remote.php/dav');
  await repo.setWebDavUsername('reader');
}

Future<void> _seedInterconnectPage(SyncRepository repo) async {
  await repo.setInterconnectEnabled(true);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    const FushiClientUrl(url: 'http://192.168.1.10:38765'),
    const FushiClientUrl(url: 'http://192.168.1.11:38765'),
    const FushiClientUrl(url: 'http://192.168.1.12:38765'),
    const FushiClientUrl(url: 'http://192.168.1.13:38765'),
    const FushiClientUrl(url: 'http://192.168.1.14:38765'),
  ]);
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
  // 同步设置内存态按 AppModel 全局缓存：不重置，上一用例的状态会在本用例的
  // setInterconnectEnabled 广播里去读已关闭的库。
  setUp(resetSyncSettingsStateForTest);
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  // syncHeight：同步与备份页比互联页长（反馈 AWp-0BtDDv 加了「同步设置」与
  // 「合并导入时包含设置」两行），单独给它更高的视口，互联页基线不动。
  for (final ({String name, double width, double height, double syncHeight})
      size
      in <({String name, double width, double height, double syncHeight})>[
        (name: 'wide', width: 900, height: 2400, syncHeight: 2800),
        (name: 'narrow', width: 400, height: 3800, syncHeight: 4900),
      ]) {
    testWidgets('sync & backup page · ${size.name}', (
      WidgetTester tester,
    ) async {
      await _pumpDetail(
        tester,
        destination: buildSyncBackupDestination,
        width: size.width,
        height: size.syncHeight,
        seed: _seedSyncPage,
      );
      _expectWholePageVisible(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          'golden_files/sync_settings_sync_backup_${size.name}.png',
        ),
      );
    }, tags: <String>['golden']);

    testWidgets('interconnect page · ${size.name}', (
      WidgetTester tester,
    ) async {
      await _pumpDetail(
        tester,
        destination: buildInterconnectDestination,
        width: size.width,
        height: size.height,
        seed: _seedInterconnectPage,
      );
      _expectWholePageVisible(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          'golden_files/sync_settings_interconnect_${size.name}.png',
        ),
      );
    }, tags: <String>['golden']);
  }
}
