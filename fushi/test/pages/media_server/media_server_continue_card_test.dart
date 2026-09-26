import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/sync/remote_cover_cache.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 「继续观看」横卡：视频是横屏的，这一行用 16:9 缩略图（集截图 / 剧横图逐张
/// 回落），并写明还剩多少、看到哪，而不是 2:3 海报竖卡 + 一条 3px 细线。
void main() {
  late Directory coverDir;

  setUpAll(() {
    coverDir = Directory.systemTemp.createTempSync('fushi-continue-covers');
  });

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    RemoteCoverCache.debugSetDirResolver(() async => coverDir);
  });

  tearDownAll(() {
    RemoteCoverCache.debugSetDirResolver(null);
    coverDir.deleteSync(recursive: true);
  });

  List<String> urlsOf(List<ImageProvider> images) => <String>[
    for (final ImageProvider image in images)
      ((image as ResizeImage).imageProvider as RemoteCoverImage).coverUrl,
  ];

  group('候选图顺序', () {
    test('集：自身 Thumb → 自身 Primary → 剧 Thumb → 剧 Backdrop', () {
      final _CoverFakeBrowser browser = _CoverFakeBrowser();
      const MediaServerItem episode = MediaServerItem(
        id: 'ep',
        name: 'Ep',
        type: MediaServerItemType.episode,
        hasThumb: true,
        hasCover: true,
        hasBackdrop: true,
        parentThumbItemId: 'series',
        parentBackdropItemId: 'series',
      );
      expect(
        urlsOf(mediaServerContinueImages(browser, episode)),
        <String>['ep|thumb', 'ep|primary', 'series|thumb', 'series|backdrop'],
        reason: '集自身的 Backdrop 不参与：服务器给集报的背景通常就是剧的',
      );
    });

    test('集没有任何自身图：直接落到剧的横图；没有上级 id 就不造请求', () {
      final _CoverFakeBrowser browser = _CoverFakeBrowser();
      expect(
        urlsOf(
          mediaServerContinueImages(
            browser,
            const MediaServerItem(
              id: 'ep',
              name: 'Ep',
              type: MediaServerItemType.episode,
              parentBackdropItemId: 'series',
            ),
          ),
        ),
        <String>['series|backdrop'],
      );
      expect(
        mediaServerContinueImages(
          browser,
          const MediaServerItem(
            id: 'ep',
            name: 'Ep',
            type: MediaServerItemType.episode,
          ),
        ),
        isEmpty,
      );
    });

    test('电影：Thumb → Backdrop → Primary 海报', () {
      final _CoverFakeBrowser browser = _CoverFakeBrowser();
      const MediaServerItem movie = MediaServerItem(
        id: 'm',
        name: 'M',
        type: MediaServerItemType.movie,
        hasThumb: true,
        hasCover: true,
        hasBackdrop: true,
      );
      expect(urlsOf(mediaServerContinueImages(browser, movie)), <String>[
        'm|thumb',
        'm|backdrop',
        'm|primary',
      ]);
    });
  });

  group('角标与第二行', () {
    test('有断点：剩余分钟向上取整；不足一分钟或无时长写看到哪', () {
      expect(
        mediaServerContinueBadge(
          const MediaServerItem(
            id: 'a',
            name: 'a',
            type: MediaServerItemType.episode,
            positionMs: 12 * 60000 + 30000,
            durationMs: 24 * 60000,
          ),
        ),
        t.video_home_remaining_minutes(minutes: 12),
      );
      expect(
        mediaServerContinueBadge(
          const MediaServerItem(
            id: 'a',
            name: 'a',
            type: MediaServerItemType.episode,
            positionMs: 24 * 60000 - 20000,
            durationMs: 24 * 60000,
          ),
        ),
        t.video_watched_up_to(time: '23:40'),
      );
      expect(
        mediaServerContinueBadge(
          const MediaServerItem(
            id: 'a',
            name: 'a',
            type: MediaServerItemType.movie,
            positionMs: 65000,
          ),
        ),
        t.video_watched_up_to(time: '1:05'),
      );
    });

    test('没断点：集是 NextUp 的下一集；电影不画角标', () {
      expect(
        mediaServerContinueBadge(
          const MediaServerItem(
            id: 'a',
            name: 'a',
            type: MediaServerItemType.episode,
            durationMs: 24 * 60000,
          ),
        ),
        t.video_next_episode,
      );
      expect(
        mediaServerContinueBadge(
          const MediaServerItem(
            id: 'a',
            name: 'a',
            type: MediaServerItemType.movie,
          ),
        ),
        isNull,
      );
    });

    test('第二行：集写季集号 + 集名；电影写断点 / 总长', () {
      expect(
        mediaServerContinueSubtitle(
          const MediaServerItem(
            id: 'a',
            name: '出发',
            type: MediaServerItemType.episode,
            seasonNumber: 1,
            episodeNumber: 3,
          ),
        ),
        'S01E03 出发',
      );
      expect(
        mediaServerContinueSubtitle(
          const MediaServerItem(
            id: 'a',
            name: 'M',
            type: MediaServerItemType.movie,
            positionMs: 754000,
            durationMs: 5525000,
          ),
        ),
        '12:34 / 1:32:05',
      );
      expect(
        mediaServerContinueSubtitle(
          const MediaServerItem(
            id: 'a',
            name: 'M',
            type: MediaServerItemType.movie,
            durationMs: 5525000,
          ),
        ),
        '1:32:05',
      );
    });
  });

  group('缩略图回落', () {
    Widget harness(Widget child) => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: kMediaServerContinueCardWidth, child: child),
          ),
        ),
      ),
    );

    testWidgets('集截图 404 → 换剧的横图，不落占位', (WidgetTester tester) async {
      final _CoverFakeBrowser browser = _CoverFakeBrowser(
        failing: <String>{'fb-ep|primary'},
      );
      await tester.pumpWidget(
        harness(
          MediaServerContinueCard(
            browser: browser,
            item: const MediaServerItem(
              id: 'fb-ep',
              name: 'Ep',
              type: MediaServerItemType.episode,
              hasCover: true,
              parentThumbItemId: 'fb-series',
              positionMs: 60000,
              durationMs: 24 * 60000,
            ),
            onTap: () {},
          ),
        ),
      );
      await _settleWithImages(tester);

      expect(browser.fetchedUrls, <String>['fb-ep|primary', 'fb-series|thumb']);
      expect(find.byType(ShelfCoverPlaceholder), findsNothing);
      expect(find.byKey(const ValueKey<int>(1)), findsOneWidget);
    });

    testWidgets('候选全失败 → 占位图', (WidgetTester tester) async {
      final _CoverFakeBrowser browser = _CoverFakeBrowser(
        failing: <String>{'all-ep|primary', 'all-series|backdrop'},
      );
      await tester.pumpWidget(
        harness(
          MediaServerContinueCard(
            browser: browser,
            item: const MediaServerItem(
              id: 'all-ep',
              name: 'Ep',
              type: MediaServerItemType.episode,
              hasCover: true,
              parentBackdropItemId: 'all-series',
            ),
            onTap: () {},
          ),
        ),
      );
      await _settleWithImages(tester);

      expect(find.byType(ShelfCoverPlaceholder), findsOneWidget);
    });
  });

  testWidgets('服务器首页：继续观看是 16:9 横卡 + 剩余时间角标 + 加粗进度条；其它行仍是竖卡', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final FakeMediaServerBrowser browser = FakeMediaServerBrowser();
    browser.libraries.add(
      const MediaServerLibrary(
        id: 'lib-shows',
        name: '动漫剧集',
        kind: MediaServerLibraryKind.tvShows,
      ),
    );
    browser.children['lib-shows'] = fakeMovies(2);
    browser.resume.add(
      const MediaServerItem(
        id: 'ep-resume',
        name: '出发',
        type: MediaServerItemType.episode,
        seriesId: 's1',
        seriesName: '葬送的芙莉莲',
        seasonNumber: 1,
        episodeNumber: 3,
        positionMs: 10 * 60000,
        durationMs: 24 * 60000,
      ),
    );

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaServerHomeView(
              session: MediaServerSession(
                browser: browser,
                play: (BuildContext _, MediaServerPlayRequest __) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder card = find.byType(MediaServerContinueCard);
    expect(card, findsOneWidget);
    final Size thumb = tester.getSize(
      find.descendant(of: card, matching: find.byType(AspectRatio)).first,
    );
    expect(thumb.width, kMediaServerContinueCardWidth);
    expect(thumb.width / thumb.height, closeTo(16 / 9, 0.01));
    expect(
      find.descendant(
        of: card,
        matching: find.text(t.video_home_remaining_minutes(minutes: 14)),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.text('葬送的芙莉莲')), findsOne);
    expect(
      find.descendant(of: card, matching: find.text('S01E03 出发')),
      findsOne,
    );
    final LinearProgressIndicator bar = tester.widget(
      find.byKey(const ValueKey<String>('media-server-continue-progress')),
    );
    expect(bar.value, closeTo(10 / 24, 1e-9));
    expect(bar.minHeight, greaterThanOrEqualTo(4));
    // 库行仍是海报竖卡，不受影响。
    expect(find.byType(MediaServerItemCard), findsNWidgets(2));
  });
}

Future<void> _settleWithImages(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// 1×1 透明 PNG：让能取到的图真的解码出来。
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// 按 kind 对应的旗子给 `'<id>|<kind>'` 形态的 URL；[failing] 里的 URL 取图抛
/// （= 兼容层报了 tag 却 404）。
class _CoverFakeBrowser extends FakeMediaServerBrowser {
  _CoverFakeBrowser({this.failing = const <String>{}})
    : super(serverId: 'fake:continue');

  final Set<String> failing;
  final List<String> fetchedUrls = <String>[];

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    final bool has = switch (kind) {
      MediaServerImageKind.primary => item.hasCover,
      MediaServerImageKind.backdrop => item.hasBackdrop,
      MediaServerImageKind.thumb => item.hasThumb,
      MediaServerImageKind.logo => item.hasLogo,
    };
    return has ? '${item.id}|${kind.name}' : null;
  }

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    fetchedUrls.add(coverUrl);
    if (failing.contains(coverUrl)) throw StateError('404 $coverUrl');
    return _onePixelPng;
  }
}
