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
///
/// TODO-654：用户决策「远端区完全撑开，和书籍一样」。此前为了不撑爆 Column，远端
/// section 被 LayoutBuilder + ConstrainedBox 限到可用高度的 0.45 并自带内部垂直
/// 滚动（一个小内滚条），手机观感差。现在整个视频库本体改为单一 CustomScrollView：
/// 远端 section 是完全撑开的 shrinkWrap GridView（NeverScrollable，随主滚动），本地
/// 视频是 SliverGrid，两段一起滚动——对齐书架（reader_hibiki_history_page）的远端
/// 书籍区范式。守卫断言相应从「限高内滚」翻转成「完全撑开 + 随主滚动 + 不内滚」。
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

  testWidgets('TODO-654 远端视频很多 + 手机窄屏：远端区完全撑开不内滚，本地视频排在其下方一起布局',
      (WidgetTester tester) async {
    // TODO-654 决策「远端区完全撑开，和书籍一样」。本守卫用 12 个远端视频 + 360x640
    // 窄屏复现「远端很多」，断言新范式：① 无任何渲染异常（CustomScrollView 的 sliver
    // 可无界撑高，不会 RenderFlex 溢出，takeException 应为 null）；② 远端区是完全撑开
    // 的 GridView（不再被关进一个独立内滚条）——远端区祖先里的 GridView 必须
    // shrinkWrap + NeverScrollable，整页只靠外层 CustomScrollView 滚动；③ 远端区与
    // 本地区在同一个 CustomScrollView 里一起布局：远端完全撑开把本地推到所有远端卡片
    // 下方（在足够高的视口里一次性展开可量到本地 dy > 全部远端 dy，正是「完全撑开、
    // 一起布局」的体现）。
    remoteClient = _GridFakeRemoteVideoClient(
      coverPath: remoteVideoCover.path,
      videoCount: 12,
    );
    // 插入若干本地视频：验证「滚动后本地可达」必须真有本地网格可量。
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

    // ① 远端很多 + 窄屏：完全撑开（shrinkWrap）随主滚动，不得 RenderFlex 溢出。
    expect(
      tester.takeException(),
      isNull,
      reason: '远端视频很多时窄屏不得 RenderFlex 溢出（CustomScrollView sliver 可无界撑高）',
    );

    // ② 远端区是完全撑开的网格：首张在视口内可见、在 GridView 内，且该 GridView
    // 不是「自带滚动的独立内滚条」（远端区不再被关进 0.45 限高的内滚 GridView）。
    final Finder firstRemote =
        find.byKey(const ValueKey<String>('remote_video_card_remote_video-1'));
    expect(firstRemote, findsOneWidget, reason: '12 个远端视频时首张应在网格内可见');
    final Iterable<GridView> remoteAncestorGrids = tester.widgetList<GridView>(
      find.ancestor(of: firstRemote, matching: find.byType(GridView)),
    );
    expect(remoteAncestorGrids, isNotEmpty,
        reason: '远端视频很多时仍须是 GridView 网格（窄屏不退回横条）');
    expect(
      remoteAncestorGrids.every((GridView g) =>
          g.shrinkWrap == true && g.physics is NeverScrollableScrollPhysics),
      isTrue,
      reason: 'TODO-654：远端 GridView 须完全撑开（shrinkWrap）且不自带滚动'
          '（NeverScrollable），交给外层 CustomScrollView 一起滚动，不再独立内滚',
    );

    // ③ 远端区完全撑开 + 与本地区在同一个 CustomScrollView 里一起布局：用一个足够高
    // 的视口（360x4000）重新布局，让 12 张单列远端卡片（每张 200 高 ≈ 2400）和本地
    // 视频一次性全部布局，断言——本地视频卡片可见，且它排在所有远端卡片下方（dy 更大）。
    // 旧的 0.45 限高内滚范式下远端区高度被截断、本地区紧贴远端区上限，本地卡片 dy 会被
    // 压在很小的 0.45*视口 之下；完全撑开后本地 dy 必须落在最后一张远端卡片之后，证明
    // 「远端完全撑开、本地随其后、整页一起布局」。
    const Size tallPhone = Size(360, 4000);
    tester.view.physicalSize = tallPhone;
    await tester.pumpWidget(buildApp(size: tallPhone));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '高视口完全展开时同样不得渲染异常');

    final Finder localCard =
        find.byKey(const ValueKey<String>('home_video_local/video-1'));
    expect(localCard, findsOneWidget,
        reason: '远端完全撑开后本地视频卡片应在同一页里一起布局可见（高视口一次性展开）');
    final Size localSize = tester.getSize(localCard);
    expect(localSize.height, greaterThan(0), reason: '本地视频卡片须有 > 0 的渲染高度');

    // 本地卡片必须排在所有远端卡片下方：取所有已布局的远端卡片里最大的 dy，本地 dy
    // 必须比它更大（远端区完全撑开把本地推到下面），证明两段一起纵向布局、远端未限高。
    final double localTop = tester.getTopLeft(localCard).dy;
    final Iterable<Element> remoteEls = find
        .byWidgetPredicate((Widget w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>)
                .value
                .startsWith('remote_video_card_remote_video-'))
        .evaluate();
    expect(remoteEls, isNotEmpty, reason: '高视口应布局出远端卡片');
    final double maxRemoteTop = remoteEls
        .map((Element e) => tester.getTopLeft(find.byWidget(e.widget)).dy)
        .reduce((double a, double b) => a > b ? a : b);
    expect(localTop, greaterThan(maxRemoteTop),
        reason: 'TODO-654：本地视频卡片应排在所有远端卡片下方（远端完全撑开，未被 0.45 限高截断）');
  });

  test(
      '源码守卫：远端区完全撑开（shrinkWrap+NeverScrollable）、整 body 单 CustomScrollView、无横向 ListView/固定宽卡片/限高 fraction',
      () {
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
    // TODO-654：远端区与本地区在同一个 CustomScrollView 里一起滚动。
    expect(
      src.contains('CustomScrollView('),
      isTrue,
      reason: 'TODO-654：视频库本体须用单一 CustomScrollView（远端 + 本地一起滚动）',
    );
    // TODO-654：本地视频区须作为 SliverGrid 挂进主滚动（不再独立 GridView 自带滚动）。
    expect(
      src.contains('SliverGrid.builder('),
      isTrue,
      reason: 'TODO-654：本地视频区须用 SliverGrid 挂进主 CustomScrollView',
    );
    // TODO-654：远端 section 不得再被 0.45 限高（删除 _kRemoteSectionMaxHeightFraction）。
    expect(
      src.contains('_kRemoteSectionMaxHeightFraction'),
      isFalse,
      reason:
          'TODO-654：远端 section 须完全撑开，不再用 _kRemoteSectionMaxHeightFraction 限高',
    );
    // 范围限定在 [_buildRemoteVideoSection] 方法体内检查，避免误命中页面别处。
    final int sectionStart = src.indexOf('Widget _buildRemoteVideoSection(');
    final int sectionEnd = src.indexOf('Widget _buildRemoteVideoCard(');
    expect(sectionStart >= 0 && sectionEnd > sectionStart, isTrue,
        reason: '应能定位 _buildRemoteVideoSection 方法体');
    final String remoteSection = src.substring(sectionStart, sectionEnd);
    // TODO-654：远端网格须完全撑开（shrinkWrap），随主滚动延展。
    expect(
      remoteSection.contains('shrinkWrap: true'),
      isTrue,
      reason: 'TODO-654：远端 GridView 须 shrinkWrap 完全撑开（高度=全部卡片高度，随主滚动）',
    );
    // TODO-654：远端网格不得自带滚动（须 NeverScrollable，靠外层 CustomScrollView 滚）。
    expect(
      remoteSection.contains('NeverScrollableScrollPhysics'),
      isTrue,
      reason: 'TODO-654：远端 GridView 须 NeverScrollable（不自带内滚），交给主滚动消化',
    );
    // TODO-654：远端 section 不得再被 Expanded 包裹（那是「占有界高度 + 内滚」旧范式）。
    expect(
      remoteSection.contains('Expanded('),
      isFalse,
      reason: 'TODO-654：远端 section 不得再用 Expanded（旧「限高内滚」范式残留）',
    );
  });
}

class _GridFakeRemoteVideoClient implements RemoteVideoClient {
  _GridFakeRemoteVideoClient({required this.coverPath, this.videoCount = 2});

  final String coverPath;

  /// 远端视频条数。默认 2（网格化守卫只需两张区分换行/横排）；完全撑开守卫传更大值
  /// （如 12）模拟「远端视频很多」把远端区撑长、本地区被推到下方需滚动才可见。
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

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs,
  ) async {}
}

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
