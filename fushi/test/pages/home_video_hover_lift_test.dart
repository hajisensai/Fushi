import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
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
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-2002：视频页所有卡都要有悬停抬升（[FushiHoverLift]，与书架/游戏库同壳）。
///
/// 该壳当初推广时视频页只包了墙格散卡 `_buildCard` 一条路径；横滚行通用卡
/// `_buildRowMediaCard`（首页「继续观看/下一集/最近添加」全部行卡）、合集墙卡
/// `_buildCollectionCoverCard`、远端占位卡 `_buildRemoteVideoCard` 三条路径全部
/// 漏包——而视频首页默认（[VideoLibrarySection.home]）恰好只渲染横滚行，用户
/// 打开视频 tab 看到的每一张卡都没有悬停反馈。
///
/// 另有一条几何门：横滚行视口高度若恰等于卡高，放大溢出的上下沿会被 ListView
/// 视口裁成平边（墙格无此问题：格间不裁）。行高必须给 (scale-1)/2 留余量。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_hover_lift_pp',
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
    storeDir = Directory.systemTemp.createTempSync('fushi_hover_lift_store');
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
  }) => ProviderScope(
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

  Future<void> pumpPage(
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

  /// 最近的 [AnimatedScale] 祖先——即包着这张卡的 [FushiHoverLift] 动画层。
  AnimatedScale liftScaleOf(WidgetTester tester, String cardKey) {
    final Finder scales = find.ancestor(
      of: find.byKey(ValueKey<String>(cardKey)),
      matching: find.byType(AnimatedScale),
    );
    expect(
      scales,
      findsWidgets,
      reason: '卡 $cardKey 外面必须包着 FushiHoverLift 的 AnimatedScale（BUG-2002）',
    );
    return tester.widget<AnimatedScale>(scales.first);
  }

  Future<TestGesture> hoverOnto(WidgetTester tester, String cardKey) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byKey(ValueKey<String>(cardKey))));
    await tester.pumpAndSettle();
    return mouse;
  }

  Future<void> expectHoverLifts(WidgetTester tester, String cardKey) async {
    expect(liftScaleOf(tester, cardKey).scale, 1.0);
    final TestGesture mouse = await hoverOnto(tester, cardKey);
    expect(
      liftScaleOf(tester, cardKey).scale,
      kFushiHoverLiftScale,
      reason: '鼠标悬停必须放大到 kFushiHoverLiftScale',
    );
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(liftScaleOf(tester, cardKey).scale, 1.0, reason: '鼠标移出必须复位');
  }

  Future<void> seedInProgress(String uid, String title) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(title),
      videoPath: Value<String>('/abs/$title.mp4'),
      lastPositionMs: const Value<int>(60000),
    ),
  );

  testWidgets('首页继续观看行卡：悬停放大、移出复位', (WidgetTester tester) async {
    await seedInProgress('video/row', 'Row Show');
    await pumpPage(tester);
    await expectHoverLifts(tester, 'home_video_continue_video/row');
  });

  testWidgets('横滚行视口给放大留出余量（不被裁成平边）', (WidgetTester tester) async {
    await seedInProgress('video/room', 'Room Show');
    await pumpPage(tester);

    final Finder card = find.byKey(
      const ValueKey<String>('home_video_continue_video/room'),
    );
    final Rect cardRect = tester.getRect(card);
    final Rect rowRect = tester.getRect(
      find.ancestor(of: card, matching: find.byType(ListView)).first,
    );
    final double need = cardRect.height * (kFushiHoverLiftScale - 1) / 2;
    expect(
      cardRect.top - rowRect.top,
      greaterThanOrEqualTo(need - 0.5),
      reason: '放大溢出的上沿会被行视口裁掉：行高必须留 (scale-1)/2 余量',
    );
    expect(
      rowRect.bottom - cardRect.bottom,
      greaterThanOrEqualTo(need - 0.5),
      reason: '放大溢出的下沿会被行视口裁掉：行高必须留 (scale-1)/2 余量',
    );
  });

  testWidgets('系列墙格的合集卡：悬停放大、移出复位', (WidgetTester tester) async {
    final int cid = await db.createMediaCollection(
      'LiftShow',
      collectionType: 'playlist',
    );
    await seedInProgress('video/ep1', 'Ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');

    await pumpPage(tester, section: VideoLibrarySection.series);
    await expectHoverLifts(tester, 'home_video_collection_card_$cid');
  });

  testWidgets('全部视频墙格的远端占位卡：悬停放大、移出复位', (WidgetTester tester) async {
    await pumpPage(
      tester,
      section: VideoLibrarySection.allVideos,
      remote: const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'video/remote-lift', title: 'Remote Lift'),
      ],
    );
    await expectHoverLifts(tester, 'remote_video_card_video_remote-lift');
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
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async => const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

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
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
