import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_links_section.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverPlaceholder;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:material_ui/material_ui.dart';

/// 详情页「同一作品」区块（作品图谱 L0 + L1 建议卡）。
///
/// 钉五件事：
/// ① 只有已确认的连接进「同一作品」行，建议进「可能相关」行；
/// ② 本地存在的条目点了走 onOpen（带端点）；
/// ③ 本地不存在的端点是「未入库」灰卡，点了不走 onOpen；
/// ④ 建议卡「确认」/「不相关」真写穿 DB（确认 → 已确认，不相关 → 墓碑）；
/// ⑤ 表变更（别处写入）后区块自己刷新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int animeId;
  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    // 作品图缓存的去抖计时器在测试里立即到点（不留悬空计时器）。
    WorkGraphStore.debounce = Duration.zero;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    animeId = await db.createMediaCollection('某动画');
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'novel',
        title: '某小说',
        epubPath: '/tmp/novel.epub',
        extractDir: '/tmp/novel',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: 0,
      ),
    );
  });

  tearDown(() async {
    WorkGraphStore.debounce = const Duration(milliseconds: 400);
    await db.close();
  });

  Widget buildApp({
    void Function(MediaLinkEntry)? onOpen,
    Future<List<RemoteVideoSource>> Function()? remoteVideoSources,
  }) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MediaLinksSection(
            database: db,
            self: book,
            onOpen: onOpen ?? (MediaLinkEntry _) {},
            remoteVideoSources: remoteVideoSources,
          ),
        ),
      ),
    ),
  );

  testWidgets('已确认进「同一作品」，点卡片走 onOpen；未入库是灰卡不可点', (WidgetTester tester) async {
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(animeId),
      ),
    );
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: (kind: MediaLinkKind.game, key: 'missing-game'),
    );
    MediaLinkEntry? opened;
    await tester.pumpWidget(buildApp(onOpen: (MediaLinkEntry e) => opened = e));
    await tester.pumpAndSettle();

    expect(find.text('同一作品'), findsWidgets);
    expect(find.text('某动画'), findsOneWidget);
    // 关系与「未入库」不再压在封面上，进封面下的副行（`关系 · 状态`）。
    final Finder animeCard = find.byKey(
      ValueKey<String>(
        'media-link-card-video_collection-${collectionTagEntryKey(animeId)}',
      ),
    );
    final Finder missingCard = find.byKey(
      const ValueKey<String>('media-link-card-game-missing-game'),
    );
    expect(
      find.descendant(of: animeCard, matching: find.text('改编作')),
      findsOneWidget,
      reason: '本条是原作 → 对端副行「改编作」，已入库不带状态',
    );
    expect(
      find.descendant(of: missingCard, matching: find.text('同一作品 · 未入库')),
      findsOneWidget,
      reason: '未入库端点的副行 = 关系 · 未入库',
    );
    expect(
      find.descendant(of: missingCard, matching: find.byType(ColorFiltered)),
      findsOneWidget,
      reason: '未入库是去饱和灰卡',
    );
    expect(
      tester
          .widget<ColorFiltered>(
            find.descendant(
              of: missingCard,
              matching: find.byType(ColorFiltered),
            ),
          )
          .colorFilter,
      mediaLinkMissingCoverFilter,
      reason: '灰卡走保 alpha 的亮度矩阵（BUG-5457）',
    );
    expect(
      find.descendant(of: animeCard, matching: find.byType(ColorFiltered)),
      findsNothing,
      reason: '已入库卡不灰化',
    );
    expect(find.textContaining('未入库'), findsOneWidget);
    expect(find.text('可能相关'), findsNothing);

    await tester.tap(find.text('missing-game'));
    await tester.pumpAndSettle();
    expect(opened, isNull, reason: '未入库灰卡不可点');

    await tester.tap(find.text('某动画'));
    await tester.pumpAndSettle();
    expect(opened?.endpoint.kind, MediaLinkKind.videoCollection);
    expect(opened?.endpoint.key, collectionTagEntryKey(animeId));
  });

  // BUG-5457：封面材质的烘焙纹理四周有给投影留的透明外扩区。混合模式去饱和
  // （BlendMode.saturation）把透明像素涂成滤镜色，灰卡背后多出一整块灰板；亮度
  // 矩阵只改 RGB，透明处仍透明。这里直接读像素：同一棵树，换旧滤镜做对照。
  testWidgets('灰卡滤镜不把透明像素涂成灰板', (WidgetTester tester) async {
    Future<({int cornerAlpha, List<int> centre})> render(
      ColorFilter filter,
    ) async {
      final GlobalKey boundary = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundary,
              child: ColorFiltered(
                colorFilter: filter,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 10,
                      height: 10,
                      child: ColoredBox(color: Color(0xFFFF0000)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final ByteData bytes = (await tester.runAsync<ByteData?>(() async {
        final RenderRepaintBoundary box =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final ui.Image image = await box.toImage();
        final ByteData? data = await image.toByteData();
        image.dispose();
        return data;
      }))!;
      int at(int x, int y, int channel) =>
          bytes.getUint8((y * 40 + x) * 4 + channel);
      return (
        cornerAlpha: at(1, 1, 3),
        centre: <int>[for (int c = 0; c < 4; c++) at(20, 20, c)],
      );
    }

    final ({int cornerAlpha, List<int> centre}) fixed = await render(
      mediaLinkMissingCoverFilter,
    );
    expect(fixed.cornerAlpha, 0, reason: '透明外扩区仍透明');
    expect(fixed.centre[3], 255);
    expect(fixed.centre[0], fixed.centre[1], reason: '封面本体去饱和成灰');
    expect(fixed.centre[1], fixed.centre[2]);

    final ({int cornerAlpha, List<int> centre}) old = await render(
      const ColorFilter.mode(Colors.grey, BlendMode.saturation),
    );
    expect(old.cornerAlpha, greaterThan(0), reason: '对照：旧滤镜把透明处涂成灰');
  });

  testWidgets('建议卡：确认写成已确认，不相关写墓碑', (WidgetTester tester) async {
    await db.proposeMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(animeId),
      ),
      source: MediaLinkSource.mal,
      confidence: 0.6,
      reason: 'MAL lists the novel as the source',
    );
    await db.proposeMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: (kind: MediaLinkKind.game, key: 'g'),
      source: MediaLinkSource.ai,
      confidence: 0.5,
      reason: 'same title',
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('可能相关'), findsOneWidget);
    expect(find.text('MAL lists the novel as the source'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey<String>(
          'media-link-card-video_collection-${collectionTagEntryKey(animeId)}',
        ),
      ),
      findsNothing,
      reason: '建议不进「同一作品」行',
    );

    final Finder animeSuggestion = find.byKey(
      ValueKey<String>(
        'media-link-suggestion-video_collection-'
        '${collectionTagEntryKey(animeId)}',
      ),
    );
    await tester.tap(
      find.descendant(
        of: animeSuggestion,
        matching: find.byKey(
          const ValueKey<String>('media-link-suggestion-confirm'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder gameSuggestion = find.byKey(
      const ValueKey<String>('media-link-suggestion-game-g'),
    );
    await tester.tap(
      find.descendant(
        of: gameSuggestion,
        matching: find.byKey(
          const ValueKey<String>('media-link-suggestion-reject'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final List<MediaLinkRow> rows =
        await tester.runAsync(
          () => db.mediaLinksForEndpoint(
            book.kind,
            book.key,
            includeRemoved: true,
          ),
        ) ??
        const <MediaLinkRow>[];
    final MediaLinkRow anime = rows.firstWhere(
      (MediaLinkRow r) => r.toKind == 'video_collection',
    );
    final MediaLinkRow game = rows.firstWhere(
      (MediaLinkRow r) => r.toKind == 'game',
    );
    expect(mediaLinkStateOf(anime), MediaLinkState.confirmed);
    expect(mediaLinkStateOf(game), MediaLinkState.removed);

    // ⑤ 表变更后区块自己刷新：确认的那条进了「同一作品」行，建议行消失。
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        ValueKey<String>(
          'media-link-card-video_collection-${collectionTagEntryKey(animeId)}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('可能相关'), findsNothing);
  });

  testWidgets('合集有本机没有的集（Jellyfin / 互联远端集）→ 卡片带云图标；全本地的不带', (
    WidgetTester tester,
  ) async {
    // 「某动画」只有一集远端集：成员行的 entryKey 是服务器条目 id，本机没有视频行。
    await db.addToCollection(animeId, MediaKind.video, 'jellyfin-item-1');
    // 另一部全是本地集。
    final int localId = await db.createMediaCollection('本地动画');
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'local-ep-1',
        title: '本地动画 01',
        videoPath: '/tmp/local01.mkv',
      ),
    );
    await db.addToCollection(localId, MediaKind.video, 'local-ep-1');
    for (final int id in <int>[animeId, localId]) {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book,
        to: (
          kind: MediaLinkKind.videoCollection,
          key: collectionTagEntryKey(id),
        ),
      );
    }
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    Finder cloudIn(int collectionId) => find.descendant(
      of: find.byKey(
        ValueKey<String>(
          'media-link-card-video_collection-'
          '${collectionTagEntryKey(collectionId)}',
        ),
      ),
      matching: find.byWidgetPredicate(
        (Widget w) => w is FushiIcon && w.icon == FushiIcons.cloud,
      ),
    );
    expect(cloudIn(animeId), findsOneWidget, reason: '有远端集 = 云图标');
    expect(cloudIn(localId), findsNothing, reason: '全本地 = 无云图标');
  });

  group('远端合集卡的服务器海报', () {
    const String seriesPoster =
        'http://jf:8096/Items/s1/Images/Primary?maxWidth=720&api_key=tok';
    late _FakeLookupSource source;
    late int sourceResolves;

    setUp(() {
      source = _FakeLookupSource(<RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'jellyfin-item-1',
          title: '某动画 01',
          coverUrl: 'http://jf:8096/Items/jellyfin-item-1/Images/Primary',
          seriesCoverUrl: seriesPoster,
        ),
      ]);
      sourceResolves = 0;
    });

    Future<List<RemoteVideoSource>> loader() async {
      sourceResolves++;
      return <RemoteVideoSource>[source];
    }

    Finder cardOf(int collectionId) => find.byKey(
      ValueKey<String>(
        'media-link-card-video_collection-'
        '${collectionTagEntryKey(collectionId)}',
      ),
    );

    /// 卡片里经 [ResizeImage] 包着的 [RemoteCoverImage]（与视频库同一形态）。
    Finder posterIn(int collectionId) => find.descendant(
      of: cardOf(collectionId),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is Image &&
            w.image is ResizeImage &&
            (w.image as ResizeImage).imageProvider is RemoteCoverImage,
      ),
    );

    RemoteCoverImage posterOf(WidgetTester tester, int collectionId) =>
        (tester.widget<Image>(posterIn(collectionId).first).image
                    as ResizeImage)
                .imageProvider
            as RemoteCoverImage;

    Future<void> linkCollection(int collectionId) => db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(collectionId),
      ),
    );

    testWidgets('只在 Jellyfin 上的合集：按成员 id 查到剧海报，与视频库同一缓存键', (
      WidgetTester tester,
    ) async {
      await db.addToCollection(animeId, MediaKind.video, 'jellyfin-item-1');
      await linkCollection(animeId);
      await tester.pumpWidget(buildApp(remoteVideoSources: loader));
      await tester.pumpAndSettle();

      expect(posterIn(animeId), findsWidgets);
      final RemoteCoverImage poster = posterOf(tester, animeId);
      expect(poster.coverUrl, seriesPoster);
      expect(
        poster.cacheKey,
        '/Items/s1/Images/Primary',
        reason: '缓存键 = 不含令牌的路径，与视频库合集卡共用磁盘缓存',
      );
      expect(identical(poster.fetcher, source), isTrue);
      expect(source.lookups, <List<String>>[
        <String>['jellyfin-item-1'],
      ]);

      // 区块重载（表变更）不再解析来源、不再问远端。
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book,
        to: (kind: MediaLinkKind.game, key: 'g'),
      );
      await tester.pumpAndSettle();
      expect(find.text('g'), findsOneWidget, reason: '区块确实重载了');
      expect(posterIn(animeId), findsWidgets);
      expect(sourceResolves, 1);
      expect(source.lookups, hasLength(1));
    });

    testWidgets('多个来源并存：成员只在后一个来源上，海报照样取到（反馈 k5Ey2AglAf）', (
      WidgetTester tester,
    ) async {
      final _FakeLookupSource empty = _FakeLookupSource(<RemoteVideoInfo>[]);
      await db.addToCollection(animeId, MediaKind.video, 'jellyfin-item-1');
      await linkCollection(animeId);
      await tester.pumpWidget(
        buildApp(
          remoteVideoSources: () async => <RemoteVideoSource>[empty, source],
        ),
      );
      await tester.pumpAndSettle();

      expect(empty.lookups, hasLength(1));
      expect(source.lookups, hasLength(1));
      expect(posterIn(animeId), findsWidgets);
      expect(
        identical(posterOf(tester, animeId).fetcher, source),
        isTrue,
        reason: '取图器必须是查到这条成员的那个来源',
      );
    });

    testWidgets('没有远端成员的合集：不解析来源、不发查询', (WidgetTester tester) async {
      final int localId = await db.createMediaCollection('本地动画');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'local-ep-1',
          title: '本地动画 01',
          videoPath: '/tmp/local01.mkv',
        ),
      );
      await db.addToCollection(localId, MediaKind.video, 'local-ep-1');
      await linkCollection(localId);
      await tester.pumpWidget(buildApp(remoteVideoSources: loader));
      await tester.pumpAndSettle();

      expect(cardOf(localId), findsOneWidget);
      expect(posterIn(localId), findsNothing);
      expect(sourceResolves, 0);
      expect(source.lookups, isEmpty);
    });

    testWidgets('查询失败：卡片保持占位图', (WidgetTester tester) async {
      source.fail = true;
      await db.addToCollection(animeId, MediaKind.video, 'jellyfin-item-1');
      await linkCollection(animeId);
      await tester.pumpWidget(buildApp(remoteVideoSources: loader));
      await tester.pumpAndSettle();

      expect(source.lookups, hasLength(1));
      expect(posterIn(animeId), findsNothing);
      expect(
        find.descendant(
          of: cardOf(animeId),
          matching: find.byType(ShelfCoverPlaceholder),
        ),
        findsOneWidget,
      );
    });
  });
}

/// 具备「按 id 查」与「取封面」两种能力的假远端来源（Jellyfin 形态），只记调用。
class _FakeLookupSource
    implements RemoteVideoSource, RemoteVideoLookup, RemoteCoverFetcher {
  _FakeLookupSource(this.videos);

  final List<RemoteVideoInfo> videos;
  final List<List<String>> lookups = <List<String>>[];
  bool fail = false;

  @override
  Future<List<RemoteVideoInfo>> remoteVideosByIds(List<String> ids) async {
    lookups.add(ids);
    if (fail) throw const SocketException('unreachable');
    return <RemoteVideoInfo>[
      for (final RemoteVideoInfo v in videos)
        if (ids.contains(v.id)) v,
    ];
  }

  // 测试不解码图片：取字节永不完成，图片停在加载中（断言的是 provider 本身）。
  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) =>
      Completer<Uint8List>().future;

  @override
  String get coverCacheNamespace => 'fake-jellyfin';

  @override
  String get remoteLibrarySourceId => 'fake-jellyfin';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() =>
      throw UnimplementedError('poster lookup must not enumerate the library');

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) => throw UnimplementedError();
}
