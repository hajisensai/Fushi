import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 剧详情：季 tab 切换重拉集；点集时播放请求的 members 是当前季**已加载的全部集**、
/// index 是点中的下标；单季不显示季 tab；电影详情「播放」直接播。
void main() {
  late FakeMediaServerBrowser browser;
  late List<MediaServerPlayRequest> played;

  const MediaServerItem series = MediaServerItem(
    id: 's1',
    name: 'Series s1',
    type: MediaServerItemType.series,
    // Emby 4.9 真机：ChildCount 是季数（2）、RecursiveItemCount 才是集数（26）。
    childCount: 2,
    episodeCount: 26,
  );
  const MediaServerItem seasonOne = MediaServerItem(
    id: 'sea1',
    name: 'Season 1',
    type: MediaServerItemType.season,
    seriesId: 's1',
    seasonNumber: 1,
  );
  const MediaServerItem seasonTwo = MediaServerItem(
    id: 'sea2',
    name: 'Season 2',
    type: MediaServerItemType.season,
    seriesId: 's1',
    seasonNumber: 2,
  );

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    browser = FakeMediaServerBrowser();
    played = <MediaServerPlayRequest>[];
  });

  Widget harness(MediaServerItem item, {String? initialSeasonId}) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MediaServerDetailView(
            session: MediaServerSession(
              browser: browser,
              play: (BuildContext _, MediaServerPlayRequest request) =>
                  played.add(request),
            ),
            item: item,
            initialSeasonId: initialSeasonId,
          ),
        ),
      ),
    );
  }

  Iterable<FakePageRequest> episodeRequests() =>
      browser.requests.where((FakePageRequest r) => r.kind == 'episodes');

  /// 共享布局的 hero 就占 460+ 高，默认 800×600 视口里季 tab / 集卡全在屏外
  /// （sliver 只在 cache extent 里构建、对 finder 算 offstage），统一用高视口。
  void useTallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final Finder seasonTabs = find.byKey(
    const ValueKey<String>('collection-season-tabs'),
  );

  testWidgets('双季：季 tab 切换重拉该季集清单', (WidgetTester tester) async {
    useTallView(tester);
    browser.seasons['s1'] = <MediaServerItem>[seasonOne, seasonTwo];
    browser.episodes['s1|sea1'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 3,
    );
    browser.episodes['s1|sea2'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea2',
      seasonNumber: 2,
      count: 2,
    );

    await tester.pumpWidget(harness(series));
    await tester.pumpAndSettle();
    expect(seasonTabs, findsOneWidget);
    // 「全 N 话」必须是集数，不是季数。
    expect(
      find.textContaining(t.collection_hero_total_episodes(count: 26)),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.collection_hero_total_episodes(count: 2)),
      findsNothing,
    );

    expect(episodeRequests().single.seasonId, 'sea1', reason: '缺省第一季');
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-sea1-ep1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-season-sea2')),
    );
    await tester.pumpAndSettle();

    expect(episodeRequests().last.seasonId, 'sea2');
    expect(episodeRequests().last.startIndex, 0, reason: '换季从第一页重来');
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-sea2-ep2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-sea1-ep1')),
      findsNothing,
      reason: '旧季的集不能残留',
    );
  });

  testWidgets('点集：members = 当前季已加载全部集，index = 点中下标', (
    WidgetTester tester,
  ) async {
    browser.seasons['s1'] = <MediaServerItem>[seasonOne, seasonTwo];
    browser.episodes['s1|sea1'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 4,
    );
    browser.episodes['s1|sea2'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea2',
      seasonNumber: 2,
      count: 3,
    );

    useTallView(tester);
    await tester.pumpWidget(harness(series, initialSeasonId: 'sea2'));
    await tester.pumpAndSettle();
    expect(
      episodeRequests().single.seasonId,
      'sea2',
      reason: 'initialSeasonId 命中就从那一季起',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-episode-sea2-ep3')),
    );
    await tester.pumpAndSettle();

    expect(played, hasLength(1));
    final MediaServerPlayRequest request = played.single;
    expect(request.info.id, 'sea2-ep3');
    expect(request.members.map((m) => m.id).toList(), <String>[
      'sea2-ep1',
      'sea2-ep2',
      'sea2-ep3',
    ], reason: '同伴是当前季全部集、按集号序');
    expect(request.initialIndex, 2);
    expect(request.hasCollection, isTrue);
  });

  testWidgets('单季不显示季 tab；详情失败回退清单条目', (WidgetTester tester) async {
    useTallView(tester);
    browser.seasons['s1'] = <MediaServerItem>[seasonOne];
    browser.episodes['s1|sea1'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 1,
    );

    await tester.pumpWidget(harness(series));
    await tester.pumpAndSettle();

    expect(seasonTabs, findsNothing);
    expect(browser.itemDetailCalls, 1);
    expect(
      find.text('Series s1'),
      findsWidgets,
      reason: 'itemDetail 抛时仍用清单那条画',
    );
  });

  testWidgets('电影详情：简介 + 播放，播放直接出请求且不带同伴', (WidgetTester tester) async {
    useTallView(tester);
    const MediaServerItem movie = MediaServerItem(
      id: 'm1',
      name: 'Movie m1',
      type: MediaServerItemType.movie,
      productionYear: 2001,
    );
    browser.details['m1'] = const MediaServerItem(
      id: 'm1',
      name: 'Movie m1',
      type: MediaServerItemType.movie,
      productionYear: 2001,
      overview: '一段简介',
      communityRating: 7.5,
    );

    await tester.pumpWidget(harness(movie));
    await tester.pumpAndSettle();

    expect(find.text('一段简介'), findsOneWidget);
    expect(seasonTabs, findsNothing);
    expect(find.text(t.video_episode_list), findsNothing, reason: '电影无选集区');
    expect(episodeRequests(), isEmpty, reason: '电影不拉集');

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-detail-play')),
    );
    await tester.pumpAndSettle();
    expect(played.single.info.id, 'm1');
    expect(played.single.hasCollection, isFalse);
  });

  group('多版本（MediaSources > 1）', () {
    const MediaServerItem movie = MediaServerItem(
      id: 'm2',
      name: 'Movie m2',
      type: MediaServerItemType.movie,
    );
    const MediaServerVersion hd = MediaServerVersion(
      id: 'ms-1080',
      name: '1080p',
      sizeBytes: 2040109465,
      bitrate: 11200000,
      width: 1920,
      height: 1080,
      videoCodec: 'h264',
      audioTracks: <MediaServerStreamTrack>[
        MediaServerStreamTrack(index: 1, displayTitle: 'Japanese AAC stereo'),
      ],
      subtitleTracks: <MediaServerStreamTrack>[
        MediaServerStreamTrack(index: 2, displayTitle: '简体中文 ASS'),
      ],
    );
    const MediaServerVersion uhd = MediaServerVersion(
      id: 'ms-2160',
      name: '2160p HDR',
      width: 3840,
      height: 2160,
      videoCodec: 'hevc',
      videoRange: 'HDR',
      audioTracks: <MediaServerStreamTrack>[
        MediaServerStreamTrack(index: 1, displayTitle: 'Japanese FLAC 5.1'),
      ],
    );

    setUp(() {
      mediaServerVersionMemory = InMemoryMediaServerVersionMemory();
    });

    testWidgets('版本胶囊 + 选中版本规格；改选记住并换规格', (WidgetTester tester) async {
      useTallView(tester);
      browser.details['m2'] = const MediaServerItem(
        id: 'm2',
        name: 'Movie m2',
        type: MediaServerItemType.movie,
        versions: <MediaServerVersion>[hd, uhd],
      );
      await tester.pumpWidget(harness(movie));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('media-server-versions')),
        findsOneWidget,
      );
      expect(find.text(t.media_server_versions), findsOneWidget);
      expect(find.text('1080p H264 · 1.9 GB · 11.2 Mbps'), findsOneWidget);
      expect(
        find.textContaining('Japanese AAC stereo'),
        findsOneWidget,
        reason: '音轨按选中版本列出',
      );
      expect(find.textContaining('简体中文 ASS'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('media-server-version-ms-2160')),
      );
      await tester.pumpAndSettle();
      expect(find.text('2160p HEVC HDR'), findsOneWidget);
      expect(find.textContaining('Japanese FLAC 5.1'), findsOneWidget);
      expect(find.textContaining('简体中文 ASS'), findsNothing);
      expect(
        resolveMediaServerVersionIndex(
          serverId: browser.serverId,
          itemId: 'm2',
          seriesId: null,
          versions: const <MediaServerVersion>[hd, uhd],
        ),
        1,
        reason: '选择写进版本记忆，取流时按它带 MediaSourceId',
      );
    });

    testWidgets('记住过的版本进来即选中；单版本不显示版本区', (WidgetTester tester) async {
      useTallView(tester);
      rememberMediaServerVersion(
        serverId: browser.serverId,
        itemId: 'm2',
        seriesId: null,
        version: uhd,
      );
      browser.details['m2'] = const MediaServerItem(
        id: 'm2',
        name: 'Movie m2',
        type: MediaServerItemType.movie,
        versions: <MediaServerVersion>[hd, uhd],
      );
      await tester.pumpWidget(harness(movie));
      await tester.pumpAndSettle();
      expect(find.text('2160p HEVC HDR'), findsOneWidget);

      browser.details['m3'] = const MediaServerItem(
        id: 'm3',
        name: 'Movie m3',
        type: MediaServerItemType.movie,
        versions: <MediaServerVersion>[hd],
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(
          const MediaServerItem(
            id: 'm3',
            name: 'Movie m3',
            type: MediaServerItemType.movie,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('media-server-versions')),
        findsNothing,
      );
    });

    testWidgets('版本胶囊可 Tab 聚焦、Enter 选中', (WidgetTester tester) async {
      useTallView(tester);
      browser.details['m2'] = const MediaServerItem(
        id: 'm2',
        name: 'Movie m2',
        type: MediaServerItemType.movie,
        versions: <MediaServerVersion>[hd, uhd],
      );
      await tester.pumpWidget(harness(movie));
      await tester.pumpAndSettle();
      final Finder uhdChip = find.byKey(
        const ValueKey<String>('media-server-version-ms-2160'),
      );
      bool focused() {
        final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) return false;
        return _isAncestor(uhdChip.evaluate().single, ctx as Element);
      }

      for (int i = 0; i < 40 && !focused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focused(), isTrue, reason: 'Tab 能走到版本胶囊');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('2160p HEVC HDR'), findsOneWidget);
    });
  });
}

bool _isAncestor(Element ancestor, Element node) {
  bool found = false;
  node.visitAncestorElements((Element e) {
    if (e == ancestor) {
      found = true;
      return false;
    }
    return true;
  });
  return found || node == ancestor;
}
