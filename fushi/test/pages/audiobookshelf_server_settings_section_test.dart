/// 「Audiobookshelf 服务器」设置区的写穿契约：新服务器落偏好（未登录不进注册表）、
/// 已登录的进注册表、退出登录清令牌并离开注册表、设置页开着期间发生的令牌轮换
/// 不会被草稿里的旧令牌覆盖回去、改地址即退出登录。
library;

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf_server_settings_section.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_abs_pp');
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
    storeDir = Directory.systemTemp.createTempSync('fushi_abs_settings');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  const AudiobookshelfTokens tokensA = AudiobookshelfTokens(
    accessToken: 'acc-a',
    refreshToken: 'ref-a',
  );

  Future<void> seedSignedIn() =>
      prefs.setDiscoveryAudiobookshelfServers(<AudiobookshelfServerConfig>[
        AudiobookshelfServerConfig(
          id: 'srv1',
          name: 'Home',
          serverUrl: Uri.parse('https://abs.example.com'),
          username: 'alice',
          tokens: tokensA,
        ),
      ]);

  Widget harness() => ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: const Scaffold(
        body: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: AudiobookshelfServerSettingsSection(),
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

  Future<void> flushDebounce(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  Iterable<AudiobookshelfDiscoverySource> absSources() => appModel
      .mediaDiscoveryService
      .sources
      .whereType<AudiobookshelfDiscoverySource>();

  testWidgets('新加服务器：地址写穿偏好，未登录不进注册表、不存任何凭据', (WidgetTester tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey<String>('abs-server-add')));
    await tester.pumpAndSettle();
    await enter(tester, 'abs-server-0-name', 'Home');
    await enter(tester, 'abs-server-0-url', 'https://abs.example.com/');
    await enter(tester, 'abs-server-0-username', 'alice');
    await enter(tester, 'abs-server-0-password', 'secret');
    await flushDebounce(tester);

    final List<AudiobookshelfServerConfig> saved =
        prefs.discoveryAudiobookshelfServers;
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Home');
    expect(saved.single.serverUrl.toString(), 'https://abs.example.com');
    expect(saved.single.isSignedIn, isFalse);
    expect(
      prefs.getPref('discovery_audiobookshelf_servers', defaultValue: '')
          as String,
      isNot(contains('secret')),
      reason: '密码只用来换令牌，永不落盘',
    );
    expect(absSources(), isEmpty);
    expect(
      find.byKey(const ValueKey<String>('abs-server-0-connect')),
      findsOneWidget,
    );
  });

  testWidgets('已登录服务器进注册表；退出登录清令牌并离开注册表', (WidgetTester tester) async {
    await seedSignedIn();
    expect(
      absSources().map((AudiobookshelfDiscoverySource s) => s.id),
      <String>['abs-srv1'],
    );

    await pumpSection(tester);
    expect(
      find.byKey(const ValueKey<String>('abs-server-0-password')),
      findsNothing,
      reason: '已登录时不显示凭据输入框',
    );
    final Finder signOut = find.byKey(
      const ValueKey<String>('abs-server-0-sign-out'),
    );
    await tester.ensureVisible(signOut);
    await tester.tap(signOut);
    await tester.pumpAndSettle();
    await flushDebounce(tester);

    expect(prefs.discoveryAudiobookshelfServers.single.isSignedIn, isFalse);
    expect(absSources(), isEmpty);
    expect(
      find.byKey(const ValueKey<String>('abs-server-0-password')),
      findsOneWidget,
    );
  });

  testWidgets('设置页开着期间发生的令牌轮换不会被草稿里的旧令牌覆盖', (WidgetTester tester) async {
    await seedSignedIn();
    await pumpSection(tester);

    // 发现源在后台刷新了令牌（refresh token 轮换）。
    const AudiobookshelfTokens tokensB = AudiobookshelfTokens(
      accessToken: 'acc-b',
      refreshToken: 'ref-b',
    );
    await tester.runAsync(
      () => appModel.persistAudiobookshelfTokens('srv1', tokensB),
    );

    // 用户随后只改了显示名。
    await enter(tester, 'abs-server-0-name', 'Renamed');
    await flushDebounce(tester);

    final AudiobookshelfServerConfig saved =
        prefs.discoveryAudiobookshelfServers.single;
    expect(saved.name, 'Renamed');
    expect(saved.tokens, tokensB);
  });

  testWidgets('改服务器地址即退出登录（旧令牌不能发给新地址）', (WidgetTester tester) async {
    await seedSignedIn();
    await pumpSection(tester);

    await enter(tester, 'abs-server-0-url', 'https://other.example.com');
    await flushDebounce(tester);

    final AudiobookshelfServerConfig saved =
        prefs.discoveryAudiobookshelfServers.single;
    expect(saved.serverUrl.host, 'other.example.com');
    expect(saved.tokens, isNull);
    expect(absSources(), isEmpty);
  });
}
