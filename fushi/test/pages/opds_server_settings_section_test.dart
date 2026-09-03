/// 「OPDS 书目服务器」设置区的写穿契约。
///
/// 断言必须落到**偏好本身 + 运行期源注册表**，不能只看 widget 局部状态：
/// 这一段最容易坏的两处正是「存了但没重建注册表」（发现页里看不见新服务器，
/// 要冷启动才出现）和「按钮亮着但配置其实无效」。
library;

import 'dart:io';

// drift 也导出 isNull/isNotNull（SQL 表达式），与 matcher 撞名，故只取所需。
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/opds_server_settings_section.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('hibiki_opds_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_opds_settings');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  /// [showSection] = false 时只把区块从树上摘掉，**ProviderScope 原位保留**。
  ///
  /// 这一点是刻意的：整棵树换掉会连 ProviderScope 一起拆，AppModel 与
  /// PreferencesRepository 跟着 dispose，于是 dispose-flush 的异步写会撞上
  /// 一个已释放的 repo——那是 harness 假象，不是生产行为（真实 app 里
  /// ProviderScope 在根上，切走设置页只卸载区块）。
  Widget harness({bool showSection = true}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: showSection
                    ? const OpdsServerSettingsSection()
                    : const SizedBox.shrink(),
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

  testWidgets('加一台服务器：写穿偏好，并且**立刻**出现在源注册表里', (WidgetTester tester) async {
    await pumpSection(tester);
    expect(prefs.discoveryOpdsServers, isEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('opds-server-add')));
    await tester.pumpAndSettle();

    await enter(tester, 'opds-server-0-name', 'My Shelf');
    await enter(tester, 'opds-server-0-url', 'https://books.example.com/opds');
    await enter(tester, 'opds-server-0-username', 'reader');
    await enter(tester, 'opds-server-0-password', 'pw');
    // 防抖窗口（600ms）过去后才落盘。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final List<OpdsServerConfig> saved = prefs.discoveryOpdsServers;
    expect(saved, hasLength(1));
    expect(saved.single.name, 'My Shelf');
    expect(
        saved.single.catalogUrl.toString(), 'https://books.example.com/opds');
    expect(saved.single.username, 'reader');
    expect(saved.single.password, 'pw');

    // 关键：注册表是构造期快照，不重建的话新服务器要等冷启动才出现。
    final List<OpdsDiscoverySource> added = appModel
        .mediaDiscoveryService.sources
        .whereType<OpdsDiscoverySource>()
        .toList();
    expect(added, hasLength(1), reason: '保存后必须立刻能在发现页选到这台服务器，而不是等冷启动');
    expect(added.single.id, opdsSourceIdFor(saved.single.id));
    expect(added.single.displayName, 'My Shelf');
  });

  testWidgets('停用的服务器不进注册表（关掉 = 不出现，不是进去再被排除）', (WidgetTester tester) async {
    await prefs.setDiscoveryOpdsServers(<OpdsServerConfig>[
      OpdsServerConfig(
        id: 'srv',
        name: 'Off',
        catalogUrl: Uri.parse('https://books.example.com/opds'),
        enabled: false,
      ),
    ]);
    await pumpSection(tester);

    expect(
      appModel.mediaDiscoveryService.sources.whereType<OpdsDiscoverySource>(),
      isEmpty,
    );

    // 打开开关 → 立刻进注册表。
    final Finder toggle =
        find.byKey(const ValueKey<String>('opds-server-0-enabled'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(
      appModel.mediaDiscoveryService.sources.whereType<OpdsDiscoverySource>(),
      hasLength(1),
    );
  });

  testWidgets('明文 HTTP 未放行：报专门的提示，且不落盘', (WidgetTester tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey<String>('opds-server-add')));
    await tester.pumpAndSettle();
    await enter(tester, 'opds-server-0-url', 'http://192.168.1.10:8080/opds');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(prefs.discoveryOpdsServers, isEmpty, reason: '无效配置不该被写进偏好');
    // 「地址看着没错却存不下」是最容易让人反复检查地址本身的一种失败，
    // 所以它有独立文案，而不是复用通用的「地址无效」。
    expect(find.text(t.discovery_opds_url_needs_http_optin), findsOneWidget);

    // 勾上放行开关后同一个地址即可保存。
    final Finder allow =
        find.byKey(const ValueKey<String>('opds-server-0-allow-http'));
    await tester.ensureVisible(allow);
    await tester.pumpAndSettle();
    await tester.tap(allow);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(prefs.discoveryOpdsServers, hasLength(1));
    expect(prefs.discoveryOpdsServers.single.allowInsecureHttp, isTrue);
  });

  testWidgets('半截地址不落盘，也不报错——那是打字中间态', (WidgetTester tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey<String>('opds-server-add')));
    await tester.pumpAndSettle();
    await enter(tester, 'opds-server-0-url', 'htt');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(prefs.discoveryOpdsServers, isEmpty);
    // 条目仍在 UI 里，等用户填完。
    expect(find.byKey(const ValueKey<String>('opds-server-0-url')),
        findsOneWidget);
  });

  testWidgets('移除一台服务器同时从偏好和注册表消失', (WidgetTester tester) async {
    await prefs.setDiscoveryOpdsServers(<OpdsServerConfig>[
      OpdsServerConfig(
        id: 'srv',
        name: 'Gone',
        catalogUrl: Uri.parse('https://books.example.com/opds'),
      ),
    ]);
    await pumpSection(tester);
    expect(
      appModel.mediaDiscoveryService.sources.whereType<OpdsDiscoverySource>(),
      hasLength(1),
    );

    final Finder remove =
        find.byKey(const ValueKey<String>('opds-server-0-remove'));
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();

    expect(prefs.discoveryOpdsServers, isEmpty);
    expect(
      appModel.mediaDiscoveryService.sources.whereType<OpdsDiscoverySource>(),
      isEmpty,
    );
  });

  testWidgets(
    '防抖窗口内切走页面：编辑必须被 flush，而不是连同异常一起丢掉',
    (WidgetTester tester) async {
      // 这条路径正是 dispose-flush 存在的唯一理由。第一版实现在 dispose 里
      // `ref.read(appProvider)`，而那时 element 已 deactivated，Riverpod 直接抛
      // 「Looking up a deactivated widget's ancestor is unsafe」——用户那次编辑
      // 连同异常一起没了。
      await pumpSection(tester);
      await tester.tap(find.byKey(const ValueKey<String>('opds-server-add')));
      await tester.pumpAndSettle();
      await enter(
        tester,
        'opds-server-0-url',
        'https://books.example.com/opds',
      );
      await enter(tester, 'opds-server-0-name', 'Flushed');

      // 不等防抖到期就把区块摘掉（= 用户切走了设置页）。
      expect(prefs.discoveryOpdsServers, isEmpty, reason: '前提：此时还没落盘');
      await tester.pumpWidget(harness(showSection: false));
      await tester.pumpAndSettle();

      expect(prefs.discoveryOpdsServers, hasLength(1));
      expect(prefs.discoveryOpdsServers.single.name, 'Flushed');
    },
  );

  testWidgets('配置无效时「测试连接」按钮不可用', (WidgetTester tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey<String>('opds-server-add')));
    await tester.pumpAndSettle();

    final Finder test0 =
        find.byKey(const ValueKey<String>('opds-server-0-test'));
    await tester.ensureVisible(test0);
    await tester.pumpAndSettle();
    // 空地址 → 不可点（而不是点了再报一个通用错误）。
    expect(tester.widget<OutlinedButton>(test0).onPressed, isNull);

    await enter(tester, 'opds-server-0-url', 'https://books.example.com/opds');
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(test0).onPressed, isNotNull);

    // 让防抖落盘跑完再结束：拆 harness 会连 ProviderScope 一起 dispose，
    // 在途的异步写会撞上已释放的 PreferencesRepository（harness 假象）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });
}
