import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// UI 巡检 PR-4：视频库卡片的三处封面角标（字幕 / 云端 / 播放列表集数）收敛到
/// PR-0 共享 [CoverBadge]。断言三处都渲染成 CoverBadge（按 key / icon 定位），
/// 防止回退成各自手写的黑胶囊 Container。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_cover_badge_pp');
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
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_cover_badge_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp(_FakeRemoteVideoClient client) => ProviderScope(
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
                // #792 分区化后远端占位卡混排进 series 分区的混排墙，钉住该分区。
                section: VideoLibrarySection.series,
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  testWidgets('字幕 / 云端 / 播放列表三处角标均渲染为共享 CoverBadge',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 单张远端占位卡同时命中三种角标：hasSubtitle（左上字幕）+ episodes>1
    // （左下集数）+ 云角标（右下恒在）。
    await tester.pumpWidget(buildApp(_FakeRemoteVideoClient()));
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_video_card_remote_video-1'),
    );
    expect(card, findsOneWidget);

    // 云角标：稳定 key + widget 类型是 CoverBadge。
    final Finder cloudBadge = find.byKey(
      const ValueKey<String>('remote_video_cloud_badge_remote_video-1'),
    );
    expect(cloudBadge, findsOneWidget);
    expect(tester.widget(cloudBadge), isA<CoverBadge>());

    // 字幕角标：卡内 CoverBadge 携字幕图标。
    expect(
      find.descendant(
        of: card,
        matching: find.widgetWithIcon(CoverBadge, Icons.subtitles_outlined),
      ),
      findsOneWidget,
      reason: '字幕角标必须是共享 CoverBadge',
    );

    // 播放列表集数角标：卡内 CoverBadge 携播放列表图标。
    expect(
      find.descendant(
        of: card,
        matching: find.widgetWithIcon(CoverBadge, Icons.playlist_play),
      ),
      findsOneWidget,
      reason: '播放列表集数角标必须是共享 CoverBadge',
    );
  });

  test('source guard: 视频库页不再手写黑胶囊角标（收敛 CoverBadge）', () {
    final String src =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    expect(src, contains('CoverBadge('), reason: '角标必须走共享 CoverBadge');
    expect(src, isNot(contains('Colors.black.withValues(alpha: 0.62)')),
        reason: '手写黑胶囊角标（0.62）应已被 CoverBadge 取代');
    expect(src, isNot(contains('Colors.black.withValues(alpha: 0.55)')),
        reason: '手写黑胶囊角标（0.55）应已被 CoverBadge 取代');
  });
}

class _FakeRemoteVideoClient implements RemoteVideoClient {
  _FakeRemoteVideoClient();

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        RemoteVideoInfo.fromJson(<String, Object?>{
          'id': 'remote/video-1',
          'title': 'Remote Episode',
          'sizeBytes': 1024,
          'hasSubtitle': true,
          'coverPath': _writeTinyCover().path,
          'episodes': <Map<String, Object?>>[
            <String, Object?>{'index': 0, 'title': 'EP1'},
            <String, Object?>{'index': 1, 'title': 'EP2'},
          ],
        }),
      ];

  File _writeTinyCover() {
    final File file = File(
      '${Directory.systemTemp.path}/hibiki_cover_badge_cover.png',
    );
    if (!file.existsSync()) file.writeAsBytesSync(_tinyPngBytes);
    return file;
  }

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async =>
      const RemoteVideoStreamUrls(
        streamUrl: 'http://127.0.0.1:1/stream',
        subtitleUrl: null,
        subtitleFileName: null,
      );

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
