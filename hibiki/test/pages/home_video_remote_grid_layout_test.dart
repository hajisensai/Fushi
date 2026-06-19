import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
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

  testWidgets('远端视频很多 + 手机窄屏：远端 section 限高内滚不溢出，本地视频区高度 > 0',
      (WidgetTester tester) async {
    // 复核退回的必修回归：TODO-593 把远端横条换成 shrinkWrap GridView 后，远端
    // section 在非 Expanded 槽位、高度随视频数量无界增长；远端视频多时整条
    // DesktopContentLayout→Column→Expanded→Column 链没有垂直滚动容器，会
    // RenderFlex 溢出且把 Expanded(本地网格) 挤到高度 0。本守卫用 12 个远端视频 +
    // 360x640 窄屏复现「无界撑高」，断言：① 无任何渲染异常（RenderFlex 溢出会经
    // FlutterError 上报，被 takeException 捕获）；② 本地视频区（home_video_* 卡片）
    // 仍可见且渲染高度 > 0（没被远端挤没）。
    remoteClient = _GridFakeRemoteVideoClient(
      coverPath: remoteVideoCover.path,
      videoCount: 12,
    );
    // 插入若干本地视频：验证「本地视频区高度 > 0」必须真有本地网格可量。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('local/video-1'),
      title: Value('Local Episode 1'),
      videoPath: Value('/abs/local-1.mp4'),
    ));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('local/video-2'),
      title: Value('Local Episode 2'),
      videoPath: Value('/abs/local-2.mp4'),
    ));

    const Size phone = Size(360, 640);
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp(size: phone));
    await tester.pumpAndSettle();

    // ① 无 RenderFlex 溢出（撤掉限高/shrinkWrap 修复后此处会捕获 overflow 异常）。
    expect(
      tester.takeException(),
      isNull,
      reason: '远端视频很多时窄屏不得 RenderFlex 溢出（远端 section 须限高内滚）',
    );

    // 远端数据确实加载（第 1 张在视口内可见）；远端卡片须在 GridView 内。注意
    // 限高内滚后，靠后的远端卡片在滚动视口外会被 GridView.builder 懒加载（不在
    // widget 树里），这本身就是「限高 + 内部滚动消化超出」生效的体现，故只断言
    // 首张可见即可，不要求第 12 张同时挂载。
    final Finder firstRemote =
        find.byKey(const ValueKey<String>('remote_video_card_remote_video-1'));
    expect(firstRemote, findsOneWidget, reason: '12 个远端视频时首张应在网格内可见（数据已加载）');
    expect(
      find.ancestor(of: firstRemote, matching: find.byType(GridView)),
      findsWidgets,
      reason: '远端视频很多时仍须是 GridView 网格（窄屏不退回横条）',
    );

    // ② 本地视频区高度 > 0：本地网格卡片可见且有正高度，没被远端挤没。
    final Finder localCard =
        find.byKey(const ValueKey<String>('home_video_local/video-1'));
    expect(localCard, findsOneWidget, reason: '本地视频卡片应可见（本地区未被远端挤到高度 0）');
    final Size localSize = tester.getSize(localCard);
    expect(
      localSize.height,
      greaterThan(0),
      reason: '本地视频区必须有 > 0 的高度（不被无界远端网格挤没）',
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
    // 复核退回的必修：远端 section 不得再无界撑高。范围限定在
    // [_buildRemoteVideoSection] 方法体内检查，避免误命中页面别处合法的
    // shrinkWrap（如批量标签操作 sheet 的 ListView）。
    final int sectionStart = src.indexOf('Widget _buildRemoteVideoSection(');
    final int sectionEnd = src.indexOf('Widget _buildRemoteVideoCard(');
    expect(sectionStart >= 0 && sectionEnd > sectionStart, isTrue,
        reason: '应能定位 _buildRemoteVideoSection 方法体');
    final String remoteSection = src.substring(sectionStart, sectionEnd);
    // 远端网格不得 shrinkWrap（会随视频数量无界撑高致 RenderFlex 溢出）。
    expect(
      remoteSection.contains('shrinkWrap: true'),
      isFalse,
      reason: '远端 GridView 不得 shrinkWrap（会随视频数量无界撑高致 RenderFlex 溢出）',
    );
    // 远端网格须自带垂直滚动消化超出高度，不能 NeverScrollable。
    expect(
      remoteSection.contains('NeverScrollableScrollPhysics'),
      isFalse,
      reason: '远端 GridView 须自带垂直滚动（不能 NeverScrollable），靠内滚消化超出高度',
    );
    // 远端 section 须被 LayoutBuilder 拿可用高度 + ConstrainedBox 按
    // _kRemoteSectionMaxHeightFraction 限高（限高逻辑在 _buildVideoLibraryBody）。
    expect(
      src.contains('LayoutBuilder') &&
          src.contains('ConstrainedBox(') &&
          src.contains('_kRemoteSectionMaxHeightFraction'),
      isTrue,
      reason: '远端 section 须用 LayoutBuilder 拿可用高度 + ConstrainedBox 按 '
          '_kRemoteSectionMaxHeightFraction 限高',
    );
  });
}

class _GridFakeRemoteVideoClient implements RemoteVideoClient {
  _GridFakeRemoteVideoClient({required this.coverPath, this.videoCount = 2});

  final String coverPath;

  /// 远端视频条数。默认 2（网格化守卫只需两张区分换行/横排）；溢出守卫传更大值
  /// （如 12）模拟「远端视频很多」把非 Expanded 槽位撑爆的场景。
  final int videoCount;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      List<RemoteVideoInfo>.generate(
        videoCount,
        (int i) => RemoteVideoInfo.fromJson(<String, Object?>{
          'id': 'remote/video-${i + 1}',
          'title': 'Remote Episode ${i + 1}',
          'sizeBytes': 1024 * (i + 1),
          'hasSubtitle': i.isEven,
          'coverPath': coverPath,
        }),
      );

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
