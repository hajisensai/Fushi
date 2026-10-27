import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 能按条目取版本的服务器（Jellyfin / Emby 形态）：版本表可编程、调用有计数。
class _VersionedBrowser extends FakeMediaServerBrowser
    implements MediaServerItemVersions {
  final Map<String, List<MediaServerVersion>> versionsById =
      <String, List<MediaServerVersion>>{};
  final List<String> versionRequests = <String>[];

  @override
  Future<List<MediaServerVersion>> listItemVersions(
    MediaServerItem item,
  ) async {
    versionRequests.add(item.id);
    return versionsById[item.id] ?? const <MediaServerVersion>[];
  }
}

/// mxYhpVcwOX：详情页每一集都能在播放前选版本——点集时有多版本且记住的选择对不上
/// 就先弹版本选择；选过之后同剧其它集按同名 / 同规格自动跟上；长按 / 右键强制重选；
/// 不支持多版本的服务器（Plex v1）点集直接播。
void main() {
  late List<MediaServerPlayRequest> played;

  const MediaServerItem series = MediaServerItem(
    id: 's1',
    name: 'Series s1',
    type: MediaServerItemType.series,
  );

  List<MediaServerVersion> twoVersions(String episodeId) =>
      <MediaServerVersion>[
        MediaServerVersion(
          id: '$episodeId-hd',
          name: '1080p',
          width: 1920,
          height: 1080,
          videoCodec: 'h264',
        ),
        MediaServerVersion(
          id: '$episodeId-uhd',
          name: '4K HDR',
          width: 3840,
          height: 2160,
          videoCodec: 'hevc',
          videoRange: 'HDR10',
        ),
      ];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    played = <MediaServerPlayRequest>[];
    mediaServerVersionMemory = InMemoryMediaServerVersionMemory();
  });

  void useTallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpDetail(
    WidgetTester tester,
    FakeMediaServerBrowser browser,
  ) async {
    useTallView(tester);
    browser.episodes['s1|'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 3,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaServerDetailView(
              session: MediaServerSession(
                browser: browser,
                play: (BuildContext _, MediaServerPlayRequest request) =>
                    played.add(request),
              ),
              item: series,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder episode(String id) =>
      find.byKey(ValueKey<String>('media-server-episode-$id'));

  final Finder picker = find.text('选择版本');

  testWidgets('非续播集也能选版本；选过后同剧其它集按同名版本直接播', (WidgetTester tester) async {
    final _VersionedBrowser browser = _VersionedBrowser();
    for (final String id in <String>['sea1-ep1', 'sea1-ep2', 'sea1-ep3']) {
      browser.versionsById[id] = twoVersions(id);
    }
    await pumpDetail(tester, browser);

    // 第 3 集不是续播集（续播是第 1 集）：照样先问版本，不直接播。
    await tester.tap(episode('sea1-ep3'));
    await tester.pumpAndSettle();
    expect(played, isEmpty, reason: '多版本且没选过：先选版本');
    expect(picker, findsOneWidget);
    expect(find.text('4K HDR'), findsOneWidget);
    expect(browser.versionRequests, <String>['sea1-ep3']);

    await tester.tap(find.text('4K HDR'));
    await tester.pumpAndSettle();
    expect(played.single.info.id, 'sea1-ep3');
    expect(
      resolveMediaServerVersionIndex(
        serverId: browser.serverId,
        itemId: 'sea1-ep3',
        seriesId: 's1',
        versions: twoVersions('sea1-ep3'),
      ),
      1,
      reason: '选中的版本记住（取流时客户端按它带 MediaSourceId）',
    );
    // 查过的集在集卡上标版本数。
    expect(
      find.descendant(
        of: episode('sea1-ep3'),
        matching: find.textContaining(t.media_server_version_count(n: 2)),
      ),
      findsOneWidget,
    );

    // 同剧第 2 集：同名版本对得上，不再问，直接播（取流时选 4K HDR）。
    await tester.tap(episode('sea1-ep2'));
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(played, hasLength(2));
    expect(played.last.info.id, 'sea1-ep2');
    expect(
      resolveMediaServerVersionIndex(
        serverId: browser.serverId,
        itemId: 'sea1-ep2',
        seriesId: 's1',
        versions: twoVersions('sea1-ep2'),
      ),
      1,
    );
  });

  testWidgets('记住的版本这一集没有（名称 / 规格都对不上）：再问', (WidgetTester tester) async {
    final _VersionedBrowser browser = _VersionedBrowser();
    browser.versionsById['sea1-ep1'] = twoVersions('sea1-ep1');
    browser.versionsById['sea1-ep2'] = const <MediaServerVersion>[
      MediaServerVersion(id: 'a', name: 'TV', width: 1280, videoCodec: 'h264'),
      MediaServerVersion(id: 'b', name: 'BD', width: 1920, videoCodec: 'av1'),
    ];
    rememberMediaServerVersion(
      serverId: browser.serverId,
      itemId: 'sea1-ep1',
      seriesId: 's1',
      version: twoVersions('sea1-ep1')[1],
    );
    await pumpDetail(tester, browser);

    await tester.tap(episode('sea1-ep2'));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    expect(played, isEmpty);
  });

  testWidgets('取消版本选择：不播', (WidgetTester tester) async {
    final _VersionedBrowser browser = _VersionedBrowser();
    browser.versionsById['sea1-ep2'] = twoVersions('sea1-ep2');
    await pumpDetail(tester, browser);

    await tester.tap(episode('sea1-ep2'));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(played, isEmpty);
  });

  testWidgets('单版本集直接播；清单报 MediaSourceCount 的集卡先标版本数', (
    WidgetTester tester,
  ) async {
    final _VersionedBrowser browser = _VersionedBrowser();
    browser.versionsById['sea1-ep1'] = const <MediaServerVersion>[
      MediaServerVersion(id: 'only', name: '1080p', width: 1920),
    ];
    useTallView(tester);
    final List<MediaServerItem> eps = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 2,
    );
    browser.episodes['s1|'] = <MediaServerItem>[
      eps[0],
      MediaServerItem(
        id: eps[1].id,
        name: eps[1].name,
        type: MediaServerItemType.episode,
        seriesId: 's1',
        seasonId: 'sea1',
        seasonNumber: 1,
        episodeNumber: 2,
        versionCount: 3,
      ),
    ];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaServerDetailView(
              session: MediaServerSession(
                browser: browser,
                play: (BuildContext _, MediaServerPlayRequest request) =>
                    played.add(request),
              ),
              item: series,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: episode('sea1-ep2'),
        matching: find.textContaining(t.media_server_version_count(n: 3)),
      ),
      findsOneWidget,
    );

    await tester.tap(episode('sea1-ep1'));
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(played.single.info.id, 'sea1-ep1');
  });

  testWidgets('长按集卡：记住过也重新问', (WidgetTester tester) async {
    final _VersionedBrowser browser = _VersionedBrowser();
    browser.versionsById['sea1-ep2'] = twoVersions('sea1-ep2');
    rememberMediaServerVersion(
      serverId: browser.serverId,
      itemId: 'sea1-ep2',
      seriesId: 's1',
      version: twoVersions('sea1-ep2')[1],
    );
    await pumpDetail(tester, browser);

    await tester.longPress(episode('sea1-ep2'));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    await tester.tap(find.text('1080p'));
    await tester.pumpAndSettle();
    expect(played.single.info.id, 'sea1-ep2');
    expect(
      resolveMediaServerVersionIndex(
        serverId: browser.serverId,
        itemId: 'sea1-ep2',
        seriesId: 's1',
        versions: twoVersions('sea1-ep2'),
      ),
      0,
      reason: '重选覆盖旧记忆',
    );
  });

  testWidgets('不支持按条目取版本的服务器（Plex v1）：点集直接播', (WidgetTester tester) async {
    final FakeMediaServerBrowser browser = FakeMediaServerBrowser();
    await pumpDetail(tester, browser);

    await tester.tap(episode('sea1-ep2'));
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(played.single.info.id, 'sea1-ep2');
  });
}
