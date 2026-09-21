/// 「AList / OpenList 站点」设置区的写穿契约（与 OPDS 段同一套断言口径）：
/// 落到偏好本身 + 运行期源注册表，游客站（账号空）也能保存并进注册表，
/// 一个库都没勾时不落盘。
library;

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/sources/alist_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/alist_site_settings_section.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('hibiki_alist_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_alist_settings');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
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
              width: 640,
              child: SingleChildScrollView(
                child: const AListSiteSettingsSection(),
              ),
            ),
          ),
        ),
      );

  Future<void> pumpSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    final Finder field = find.byKey(ValueKey<String>(key));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  Iterable<AListDiscoverySource> userSites() =>
      appModel.mediaDiscoveryService.sources
          .whereType<AListDiscoverySource>()
          .where((AListDiscoverySource s) => s.isUserConfigured);

  testWidgets('加一个游客站：账号留空也写穿偏好，并立刻进注册表', (WidgetTester tester) async {
    await pumpSection(tester);
    expect(prefs.discoveryAListSites, isEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('alist-site-add')));
    await tester.pumpAndSettle();
    await enter(tester, 'alist-site-0-name', 'Cat OD');
    await enter(tester, 'alist-site-0-url', 'https://od.example.com/GD-1');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final List<AListSiteConfig> saved = prefs.discoveryAListSites;
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Cat OD');
    expect(saved.single.username, isEmpty, reason: '游客访问：账号空即合法');
    expect(saved.single.origin, 'https://od.example.com',
        reason: '贴了带路径的地址只取站点根');
    expect(saved.single.kinds, kDefaultAListSiteKinds);

    final List<AListDiscoverySource> added = userSites().toList();
    expect(added, hasLength(1), reason: '保存后必须立刻能在发现页选到，不是等冷启动');
    expect(added.single.id, alistSourceIdFor(saved.single.id));
    expect(added.single.displayName, 'Cat OD');
    expect(added.single.capabilities.kinds, kDefaultAListSiteKinds);
    // 内置 erogame 站仍在、且不被当成自配。
    expect(
      appModel.mediaDiscoveryService.sources
          .whereType<AListDiscoverySource>()
          .where((AListDiscoverySource s) => !s.isUserConfigured),
      hasLength(1),
    );
  });

  testWidgets('勾选库：改 kinds 写穿到偏好与注册表；最后一个不可取消', (WidgetTester tester) async {
    await prefs.setDiscoveryAListSites(<AListSiteConfig>[
      AListSiteConfig(
        id: 'site-1',
        name: 'S',
        baseUrl: Uri.parse('https://od.example.com'),
        kinds: const <DiscoveryMediaKind>{DiscoveryMediaKind.novel},
      ),
    ]);
    await pumpSection(tester);

    Future<void> tapKind(String kind) async {
      final Finder chip =
          find.byKey(ValueKey<String>('alist-site-0-kind-$kind'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    await tapKind('manga');
    expect(prefs.discoveryAListSites.single.kinds, <DiscoveryMediaKind>{
      DiscoveryMediaKind.novel,
      DiscoveryMediaKind.manga
    });
    expect(userSites().single.capabilities.kinds, <DiscoveryMediaKind>{
      DiscoveryMediaKind.novel,
      DiscoveryMediaKind.manga
    });

    await tapKind('manga');
    await tapKind('novel');
    // 全取消会让整条配置无效而消失，所以最后一个 chip 的取消是 no-op。
    expect(prefs.discoveryAListSites.single.kinds,
        <DiscoveryMediaKind>{DiscoveryMediaKind.novel});
    expect(userSites().single.capabilities.kinds,
        <DiscoveryMediaKind>{DiscoveryMediaKind.novel});
  });

  testWidgets('停用的站点不进注册表', (WidgetTester tester) async {
    await prefs.setDiscoveryAListSites(<AListSiteConfig>[
      AListSiteConfig(
        id: 'site-off',
        name: 'Off',
        baseUrl: Uri.parse('https://od.example.com'),
        enabled: false,
      ),
    ]);
    await pumpSection(tester);
    expect(userSites(), isEmpty);

    final Finder toggle =
        find.byKey(const ValueKey<String>('alist-site-0-enabled'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(userSites(), hasLength(1));
  });

  testWidgets('明文 HTTP 未放行：报专门提示且不落盘', (WidgetTester tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey<String>('alist-site-add')));
    await tester.pumpAndSettle();
    await enter(tester, 'alist-site-0-url', 'http://192.168.1.10:5244');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(t.discovery_alist_url_needs_http_optin), findsOneWidget);
    expect(prefs.discoveryAListSites, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('alist-site-0-test')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
              find.byKey(const ValueKey<String>('alist-site-0-test')))
          .onPressed,
      isNull,
      reason: '配置无效时测试连接不可用',
    );
  });
}
