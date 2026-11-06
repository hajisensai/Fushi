import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-4130 / PR #2984 审查：视频首页同一行里的合集卡、远端卡，长按 / 右键菜单
/// 头部必须与卡片同源（取图链、标题），且封面存在性还在异步探测时打开菜单，落定
/// 后菜单要自己重取——菜单是独立路由，page 的重建到不了它。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_collection_menu_cover_pp',
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
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync(
      'fushi_collection_menu_cover_store',
    );
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

  Widget buildApp(RemoteVideoClient client) => ProviderScope(
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
            section: VideoLibrarySection.home,
            remoteVideoClientLoader: () async => client,
          ),
        ),
      ),
    ),
  );

  Future<void> sizeUp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openMenu(WidgetTester tester, Finder card) async {
    expect(card, findsOneWidget, reason: '前提：卡片已渲染');
    await tester.longPress(card);
    await tester.pumpAndSettle();
  }

  /// 让封面存在性探测（真实 `File.exists`）回话：fakeAsync 里 IO 续体只在
  /// runAsync 之后的 pump 里跑。[stillPending] 为假即停。
  Future<void> settleProbes(
    WidgetTester tester,
    bool Function() stillPending,
  ) async {
    for (int i = 0; i < 200 && stillPending(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  String? remoteUrlOf(ImageProvider<Object>? provider) {
    ImageProvider<Object>? base = provider;
    while (base is ResizeImage) {
      base = base.imageProvider;
    }
    return base is RemoteCoverImage ? base.coverUrl : null;
  }

  testWidgets('「最近添加」纯远端合集卡的菜单头部用卡上同一张剧海报与作品名', (WidgetTester tester) async {
    await sizeUp(tester);
    const String workTitle = 'けいおん！';
    const String seriesCover = 'https://host.example/Items/kon/Images/Primary';
    final int cid = await db.createMediaCollection(
      'Kon',
      collectionType: 'collection',
    );
    await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        mediaType: 'tv',
        title: workTitle,
        collectionId: Value<int?>(cid),
        updatedAt: 1,
      ),
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;

    await tester.pumpWidget(
      buildApp(
        _FakeRemoteVideoClient(<RemoteVideoInfo>[
          RemoteVideoInfo(
            id: 'video/kon-ep1',
            title: 'Kon Ep1',
            seriesCoverUrl: seriesCover,
            importedAt: nowMs,
            collection: const RemoteCollectionMembership(
              collectionName: 'Kon',
              collectionType: 'collection',
              sortIndex: 0,
            ),
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      ValueKey<String>('home_video_recent_collection_$cid'),
    );
    expect(
      find.descendant(of: card, matching: find.text(workTitle)),
      findsOneWidget,
      reason: '前提：卡片本身画的是刮削作品名',
    );

    await openMenu(tester, card);
    final Finder menu = find.byType(MediaItemDialogFrame);
    expect(menu, findsOneWidget);
    final MediaItemDialogFrame frame = tester.widget<MediaItemDialogFrame>(
      menu,
    );
    expect(frame.title, workTitle, reason: '菜单标题与卡片同为刮削作品名，不是合集名');
    expect(
      remoteUrlOf(frame.coverBackdrop),
      seriesCover,
      reason: '纯远端合集：菜单垫底图与卡片同源（远端剧海报），不能因没有本地成员就空着',
    );
    expect(
      tester
          .widgetList<Image>(
            find.descendant(of: menu, matching: find.byType(Image)),
          )
          .where((Image i) => remoteUrlOf(i.image) == seriesCover),
      isNotEmpty,
      reason: '菜单头部封面必须画卡片上那张剧海报',
    );
  });

  testWidgets('合集成员封面探测未落定时打开合集菜单，落定后头部跟着换（不停在加载态）', (
    WidgetTester tester,
  ) async {
    await sizeUp(tester);
    // 不存在的路径：落定 = 「没有封面」。不真读图片文件，免得收尾时还挂着句柄。
    final String missingCover = p.join(storeDir.path, 'no-cover.jpg');
    const String uid = 'video/local-ep1';
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>(uid),
        title: const Value<String>('Local Ep1'),
        videoPath: const Value<String>('/abs/local-ep1.mp4'),
        coverPath: Value<String>(missingCover),
        importedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final int cid = await db.createMediaCollection(
      'Local Kon',
      collectionType: 'collection',
    );
    await db.addToCollection(cid, MediaKind.video, uid);

    await tester.pumpWidget(
      buildApp(_FakeRemoteVideoClient(<RemoteVideoInfo>[])),
    );
    await tester.pumpAndSettle();

    await openMenu(
      tester,
      find.byKey(ValueKey<String>('home_video_recent_collection_$cid')),
    );
    final Finder menu = find.byType(MediaItemDialogFrame);
    expect(menu, findsOneWidget);
    expect(
      tester.widget<MediaItemDialogFrame>(menu).coverBackdrop,
      isA<PendingCoverImage>(),
      reason: '前提：fakeAsync 下 File.exists 未回话，打开菜单时封面仍在探测',
    );

    await settleProbes(
      tester,
      () =>
          tester.widget<MediaItemDialogFrame>(menu).coverBackdrop
              is PendingCoverImage,
    );

    expect(
      tester.widget<MediaItemDialogFrame>(menu).coverBackdrop,
      isNull,
      reason: '探测落定（文件不在）后合集菜单必须重取为「没有封面」，不能永远停在加载态',
    );
  });

  testWidgets('远端封面缓存探测未落定时打开远端卡菜单，落定后头部跟着换（不停在加载态）', (
    WidgetTester tester,
  ) async {
    await sizeUp(tester);
    final String missingCover = p.join(storeDir.path, 'remote-cover.jpg');
    await tester.pumpWidget(
      buildApp(
        _FakeRemoteVideoClient(<RemoteVideoInfo>[
          RemoteVideoInfo(
            id: 'video/remote-new',
            title: 'Remote New',
            coverPath: missingCover,
            importedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await openMenu(
      tester,
      find.byKey(
        const ValueKey<String>('home_video_recent_remote_video_remote-new'),
      ),
    );
    final Finder menu = find.byType(MediaItemDialogFrame);
    expect(menu, findsOneWidget);
    expect(
      tester.widget<MediaItemDialogFrame>(menu).coverBackdrop,
      isA<PendingCoverImage>(),
      reason: '前提：打开菜单时远端封面缓存文件的存在性仍在探测',
    );

    await settleProbes(
      tester,
      () =>
          tester.widget<MediaItemDialogFrame>(menu).coverBackdrop
              is PendingCoverImage,
    );

    expect(
      tester.widget<MediaItemDialogFrame>(menu).coverBackdrop,
      isNull,
      reason: '探测落定（缓存文件不在、没有 URL）后远端卡菜单必须重取，不能永远停在加载态',
    );
  });
}

/// 互联远端视频清单；同时是封面取图器（剧海报走 [RemoteCoverImage]）。取图直接
/// 失败：本文件只断言图源身份，不解码。
class _FakeRemoteVideoClient implements RemoteVideoClient, RemoteCoverFetcher {
  _FakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  String get coverCacheNamespace => 'test-host';

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async =>
      throw StateError('no network in test');

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
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
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
