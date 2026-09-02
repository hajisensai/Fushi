import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/discovery_source_settings_section.dart';

import '../helpers/test_platform_services.dart';

/// 「发现来源」开关区：它是 `discovery_disabled_sources` 这个偏好的**唯一** UI，
/// 所以断言必须落到偏好本身（写穿），而不是 widget 的局部状态。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_discovery_settings_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late AppModel appModel;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_discovery_settings');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    // prefs 归 AppModel 处置（ProviderScope 拆除时 AppModel.dispose 会 dispose
    // 它）；这里再 dispose 一次会撞 ChangeNotifier 的「已释放」断言。
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Widget harness() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: const DiscoverySourceSettingsSection(),
              ),
            ),
          ),
        ),
      );

  testWidgets('lists every registered discovery source, sukebei off by default',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // 遍历运行期注册表，不抄第二份 id 清单：新加一个 adapter 自动出现在这里。
    final List<MediaDiscoverySource> sources =
        appModel.mediaDiscoveryService.sources;
    expect(sources, isNotEmpty);
    for (final MediaDiscoverySource source in sources) {
      final Finder row =
          find.byKey(ValueKey<String>('discovery-source-${source.id}'));
      expect(row, findsOneWidget, reason: 'missing row for ${source.id}');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(row).value,
        source.id == 'sukebei' ? isFalse : isTrue,
        reason: '${source.id} default',
      );
    }
  });

  testWidgets('用户自配的 OPDS 服务器不进这一区（它自己带 enabled，两套开关会两头对不上）',
      (WidgetTester tester) async {
    // 在这里关掉只影响聚合扇出：OPDS 配置区仍显示「启用」、单选仍能用；
    // 反过来在配置区关掉，源直接离开注册表，停用清单里那条 id 就成了
    // 再没有 UI 能清的垃圾。分界同视频域的自配 Torznab。
    await prefs.setDiscoveryOpdsServers(<OpdsServerConfig>[
      OpdsServerConfig(
        id: 'srv',
        name: 'My Shelf',
        catalogUrl: Uri.parse('https://books.example.com/opds'),
      ),
    ]);
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // 前提：这台服务器确实已经在运行期注册表里（否则这条断言是空转）。
    expect(
      appModel.mediaDiscoveryService.sources
          .where((MediaDiscoverySource s) => s.isUserConfigured),
      hasLength(1),
    );
    expect(
      find.byKey(const ValueKey<String>('discovery-source-opds-srv')),
      findsNothing,
    );
    // 内置源仍在。
    expect(
      find.byKey(const ValueKey<String>('discovery-source-nyaa')),
      findsOneWidget,
    );
  });

  testWidgets('toggling a source writes through to the shared preference',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final Finder nyaa =
        find.byKey(const ValueKey<String>('discovery-source-nyaa'));
    await tester.ensureVisible(nyaa);
    await tester.pumpAndSettle();
    await tester.tap(nyaa);
    await tester.pumpAndSettle();

    // 停用清单是**唯一**状态：开关写的就是发现页聚合读的那个偏好。
    expect(appModel.discoveryDisabledSourceIds, contains('nyaa'));
    expect(prefs.discoveryDisabledSources.split(','), contains('nyaa'));
    expect(tester.widget<SwitchListTile>(nyaa).value, isFalse);

    // 出厂就停用的 sukebei 不能被这次写入顺手打开。
    expect(appModel.discoveryDisabledSourceIds, contains('sukebei'));

    await tester.tap(nyaa);
    await tester.pumpAndSettle();
    expect(appModel.discoveryDisabledSourceIds, isNot(contains('nyaa')));
    expect(tester.widget<SwitchListTile>(nyaa).value, isTrue);
  });
}
