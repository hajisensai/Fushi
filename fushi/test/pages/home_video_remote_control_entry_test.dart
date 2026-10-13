import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频模块页头的手机遥控按钮：只在探到可遥控的已配对电脑时出现；本机做互联
/// host 时不出现；配对清单变化时重探（不在 build 里探）。harness 与
/// `home_video_filter_empty_test.dart` 同形。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_remote_entry_pp',
    );
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
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_video_remote_entry');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp({Future<List<VideoRemoteTarget>> Function()? loader}) =>
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
                videoRemoteTargetsLoader: loader,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpPage(
    WidgetTester tester, {
    Future<List<VideoRemoteTarget>> Function()? loader,
  }) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(loader: loader));
    await tester.pumpAndSettle();
  }

  final Finder remoteButton = find.byKey(
    const ValueKey<String>('video-library-remote-control'),
  );

  VideoRemoteTarget target(String hostId, String name) => VideoRemoteTarget(
    hostId: hostId,
    displayName: name,
    peer: FushiClientUrl(
      url: 'https://$hostId.lan:8765',
      hostId: hostId,
      token: 'tok-$hostId',
    ),
  );

  testWidgets('有可遥控的电脑：页头出现遥控按钮', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loader: () async => <VideoRemoteTarget>[target('pc', 'Desk PC')],
    );
    expect(remoteButton, findsOneWidget);
    expect(find.byIcon(FushiIcons.remoteControl), findsOneWidget);
  });

  testWidgets('没有可遥控的电脑：不出现', (WidgetTester tester) async {
    await pumpPage(tester, loader: () async => const <VideoRemoteTarget>[]);
    expect(remoteButton, findsNothing);
  });

  testWidgets('本机正在做互联 host：生产探测路径不出现按钮', (WidgetTester tester) async {
    final SyncRepository repo = SyncRepository(db);
    await tester.runAsync(() async {
      await repo.setInterconnectEnabled(true);
      await repo.setServerEnabled(true);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://192.168.1.10:8765',
          hostId: 'pc',
          token: 'tok',
        ),
      ]);
    });
    await pumpPage(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(remoteButton, findsNothing);
  });

  testWidgets('配对清单变化时重探，build 不重探', (WidgetTester tester) async {
    int calls = 0;
    List<VideoRemoteTarget> next = const <VideoRemoteTarget>[];
    await pumpPage(
      tester,
      loader: () async {
        calls++;
        return next;
      },
    );
    expect(calls, 1);
    expect(remoteButton, findsNothing);

    await tester.pump();
    await tester.pump();
    expect(calls, 1, reason: '重建不触发探测');

    next = <VideoRemoteTarget>[target('pc', 'Desk PC')];
    SyncRepository.fushiClientUrlsRevision.value++;
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(remoteButton, findsOneWidget);
  });

  testWidgets('多台电脑：点按钮弹选择框，默认选中上次那台', (WidgetTester tester) async {
    await tester.runAsync(
      () => SyncRepository(db).setVideoRemoteLastHostId('laptop'),
    );
    await pumpPage(
      tester,
      loader: () async => <VideoRemoteTarget>[
        target('pc', 'Desk PC'),
        target('laptop', 'Laptop'),
      ],
    );
    await tester.tap(remoteButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Desk PC'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
  });
}
