import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-593：手机端远端（互通）视频此前用固定高 200 的横向 ListView 渲染成
/// 「一横条滚动」，本地视频却是响应式网格。该守卫钉死「远端视频和本地视频用
/// 同一套响应式网格（GridView + SliverGridDelegateWithMaxCrossAxisExtent），
/// 而不是横向单行滚动」。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_grid_pp');
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

  late HibikiDatabase db;
  late AppModel appModel;
  late _GridFakeRemoteVideoClient remoteClient;
  late File remoteVideoCover;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_grid_store');
    remoteVideoCover = File('${storeDir.path}/remote-video-cover.png')
      ..writeAsBytesSync(_tinyPngBytes);
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    remoteClient = _GridFakeRemoteVideoClient(coverPath: remoteVideoCover.path);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp({required Size size}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: size),
              child: Scaffold(
                body: HomeVideoPage(
                  repo: VideoBookRepository(db),
                  remoteVideoClientLoader: () async => remoteClient,
                  remoteVideoDownloadDestination: (RemoteVideoInfo
                          video) async =>
                      File('${pathProviderDir.path}/${video.id.hashCode}.mp4'),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('手机窄屏远端视频用 GridView 网格，不是横向滚动 ListView',
      (WidgetTester tester) async {
    // 模拟手机竖屏极窄宽度：响应式网格在这里降为单列，能真正区分「网格换行」
    // 与「横排单行滚动」——横排单行无论多窄都不换行，所有卡片 dy 恒相等。
    const Size phone = Size(240, 900);
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp(size: phone));
    await tester.pumpAndSettle();

    final Finder firstCard = find.byKey(
      const ValueKey<String>('remote_video_card_remote_video-1'),
    );
    final Finder secondCard = find.byKey(
      const ValueKey<String>('remote_video_card_remote_video-2'),
    );
    expect(firstCard, findsOneWidget);
    expect(secondCard, findsOneWidget);

    // 远端卡片必须在一个 GridView 内（与本地视频网格一致）。
    expect(
      find.ancestor(of: firstCard, matching: find.byType(GridView)),
      findsWidgets,
      reason: '远端视频卡片应渲染在 GridView 网格里（与本地视频一致）',
    );

    // 远端卡片绝不能被横向滚动的 ListView 包裹（横条滚动的根因）。
    // 只检查远端卡片的祖先链——页面其它合法横向滚动组件（如标签筛选条
    // HibikiTagFilterBar）不在排查范围内。
    final Iterable<ListView> remoteAncestorHorizontalListViews = tester
        .widgetList<ListView>(
          find.ancestor(of: firstCard, matching: find.byType(ListView)),
        )
        .where((ListView lv) => lv.scrollDirection == Axis.horizontal);
    expect(
      remoteAncestorHorizontalListViews,
      isEmpty,
      reason: '远端视频卡片不得被横向滚动 ListView（一横条滚动）包裹',
    );

    // 极窄屏单列网格：第二张卡片必须换行排在第一张下方（dy 更大），
    // 而不是横排单行滚动里水平排在右侧（dy 恒相等）。
    final Offset firstPos = tester.getTopLeft(firstCard);
    final Offset secondPos = tester.getTopLeft(secondCard);
    expect(
      secondPos.dy,
      greaterThan(firstPos.dy),
      reason: '窄屏单列网格：第二张远端卡片应换行排在第一张下方，非右侧横排',
    );
  });

  test('源码守卫：远端 section 复用本地网格 delegate、无横向 ListView/固定宽卡片', () {
    final String src =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    // 远端 section 必须用与本地一致的响应式网格 delegate。
    expect(
      src.contains('SliverGridDelegateWithMaxCrossAxisExtent'),
      isTrue,
      reason: '远端视频应复用本地网格的 SliverGridDelegateWithMaxCrossAxisExtent',
    );
    // 不得再出现横向滚动 ListView（横条滚动根因）。
    expect(
      src.contains('scrollDirection: Axis.horizontal'),
      isFalse,
      reason: '远端视频不得再用横向滚动 ListView 渲染（TODO-593 回归）',
    );
    // 远端卡片不得再被固定 260 宽 SizedBox 包裹（应填满 grid cell）。
    expect(
      src.contains('width: 260'),
      isFalse,
      reason: '远端卡片应填满网格 cell，不再固定 260 宽',
    );
  });
}

class _GridFakeRemoteVideoClient implements RemoteVideoClient {
  _GridFakeRemoteVideoClient({required this.coverPath});

  final String coverPath;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        RemoteVideoInfo.fromJson(<String, Object?>{
          'id': 'remote/video-1',
          'title': 'Remote Episode 1',
          'sizeBytes': 1024,
          'hasSubtitle': true,
          'coverPath': coverPath,
        }),
        RemoteVideoInfo.fromJson(<String, Object?>{
          'id': 'remote/video-2',
          'title': 'Remote Episode 2',
          'sizeBytes': 2048,
          'hasSubtitle': false,
          'coverPath': coverPath,
        }),
      ];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id) async =>
      RemoteVideoStreamUrls(
        streamUrl: 'http://127.0.0.1:1/stream',
        subtitleUrl: null,
        subtitleFileName: null,
      );

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {}
}

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
