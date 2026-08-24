import 'dart:io';

import 'package:drift/drift.dart' show Value;
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
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-1808：视频首页（[VideoLibrarySection.home]）横滚行卡必须画用户标签。
///
/// series-first 拆分把墙格从首页移去「系列 / 全部视频」后，首页只剩 hero + 三条
/// 横滚行；标签层当时只写在墙卡 `_buildCard` 上，于是「打了标签，首页一个都看不
/// 见」。这几条断言就是那个缺口的行为门：继续观看行的散卡、合集卡与最近添加行卡
/// 各自认自己那条标签，没打标签的卡不得凭空长出 chip。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_home_row_tags_pp');
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
    storeDir = Directory.systemTemp.createTempSync('fushi_home_row_tags_store');
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

  Widget buildApp({
    VideoLibrarySection section = VideoLibrarySection.home,
    List<RemoteVideoInfo> remote = const <RemoteVideoInfo>[],
  }) =>
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
                section: section,
                remoteVideoClientLoader: remote.isEmpty
                    ? null
                    : () async => _ListFakeRemoteVideoClient(remote),
              ),
            ),
          ),
        ),
      );

  Future<void> pumpHome(
    WidgetTester tester, {
    VideoLibrarySection section = VideoLibrarySection.home,
    List<RemoteVideoInfo> remote = const <RemoteVideoInfo>[],
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section: section, remote: remote));
    await tester.pumpAndSettle();
  }

  /// 有播放痕迹（未看完）→ 进「继续观看」行。
  Future<void> seedInProgress(String uid, String title) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(title),
        videoPath: Value<String>('/abs/$title.mp4'),
        lastPositionMs: const Value<int>(60000),
      ));

  Finder tagTextIn(String cardKey, String tagName) => find.descendant(
        of: find.byKey(ValueKey<String>(cardKey)),
        matching: find.text(tagName),
      );

  testWidgets('继续观看行的散卡显示该视频的标签', (WidgetTester tester) async {
    await seedInProgress('video/tagged', 'Tagged Show');
    await seedInProgress('video/plain', 'Plain Show');
    final int tagId = await db.createTag('WatchLater', 0xFF2196F3);
    await db.addTagToVideoBook('video/tagged', tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_continue_video/tagged', 'WatchLater'),
      findsOneWidget,
      reason: '首页横滚卡必须和墙卡一样画出已打的标签（BUG-1808）',
    );
    expect(
      tagTextIn('home_video_continue_video/plain', 'WatchLater'),
      findsNothing,
      reason: '标签只属于打过它的那条视频，不得整行铺开',
    );
  });

  testWidgets('最近添加行的卡显示该视频的标签', (WidgetTester tester) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('video/fresh'),
      title: const Value<String>('Fresh Show'),
      videoPath: const Value<String>('/abs/fresh.mp4'),
      importedAt: Value<int>(nowMs),
    ));
    final int tagId = await db.createTag('Backlog', 0xFF4CAF50);
    await db.addTagToVideoBook('video/fresh', tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_recent_video/fresh', 'Backlog'),
      findsOneWidget,
      reason: '「最近添加」行卡与「继续观看」同一标签口径',
    );
  });

  testWidgets('继续观看行的合集卡显示合集自己的标签', (WidgetTester tester) async {
    final int cid =
        await db.createMediaCollection('MyShow', collectionType: 'playlist');
    await seedInProgress('video/ep1', 'Ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    final int tagId = await db.createTag('Airing', 0xFFFF9800);
    await db.addTagToCollection(cid, tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_continue_collection_$cid', 'Airing'),
      findsOneWidget,
      reason: '合集的标签走 collectionTagMapProvider，与合集墙卡同一口径',
    );
  });

  // ── 远端占位卡：host 清单下发的是标签**名**（标签本身每设备本地） ──────────

  testWidgets('继续观看行的远端占位卡显示 host 下发的标签', (WidgetTester tester) async {
    await pumpHome(
      tester,
      remote: const <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-watching',
          title: 'Remote Watching',
          positionMs: 60000,
          positionUpdatedAtMs: 1700000000000,
          tags: <String>['HostTag'],
        ),
      ],
    );

    expect(
      tagTextIn('home_video_continue_remote_video_remote-watching', 'HostTag'),
      findsOneWidget,
      reason: 'RemoteVideoInfo.tags 一直在清单里，远端卡不该是唯一看不到标签的卡',
    );
  });

  testWidgets('远端标签借本机同名标签的颜色，本机没有则走 chip 默认色',
      (WidgetTester tester) async {
    const int knownColor = 0xFF9C27B0;
    await db.createTag('Known', knownColor);

    await pumpHome(
      tester,
      remote: const <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-colored',
          title: 'Remote Colored',
          positionMs: 60000,
          positionUpdatedAtMs: 1700000000000,
          tags: <String>['Known', 'Unknown'],
        ),
      ],
    );

    final FushiTagChip known = tester.widget<FushiTagChip>(find.ancestor(
      of: find.text('Known'),
      matching: find.byType(FushiTagChip),
    ));
    final FushiTagChip unknown = tester.widget<FushiTagChip>(find.ancestor(
      of: find.text('Unknown'),
      matching: find.byType(FushiTagChip),
    ));

    expect(known.color, const Color(knownColor),
        reason: '本机有同名标签就借它的颜色，两端看同一条标签颜色才一致');
    expect(unknown.color, isNull,
        reason: 'host 只下发名字，本机没这条标签时不得凭空造颜色');
  });

  testWidgets('「全部视频」墙格里的远端占位卡也显示标签（与字幕角标并成一列）',
      (WidgetTester tester) async {
    await pumpHome(
      tester,
      section: VideoLibrarySection.allVideos,
      remote: const <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-wall',
          title: 'Remote Wall',
          hasSubtitle: true,
          tags: <String>['WallTag'],
        ),
      ],
    );

    expect(
      tagTextIn('remote_video_card_video_remote-wall', 'WallTag'),
      findsOneWidget,
      reason: '墙格远端卡此前左上角只有字幕角标，标签整层缺失',
    );
    expect(
      find.descendant(
        of: find.byKey(
            const ValueKey<String>('remote_video_card_video_remote-wall')),
        matching: find.byIcon(Icons.subtitles_outlined),
      ),
      findsOneWidget,
      reason: '补标签不能把字幕角标挤掉——两者并成一列，谁都不遮谁',
    );
  });
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _videos;

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id,
          {int episodeIndex = 0}) async =>
      const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    void Function(double progress)? onProgress,
    int episodeIndex = 0,
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
