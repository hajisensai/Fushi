import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/downloads/download_task_share.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/mining/galgame_home_selection.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/pages/implementations/download_task_sources.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavPeekData, AdaptiveNavPeekEntry;
import 'package:material_ui/material_ui.dart';

// 产品规则（2026-11-22）：侧栏每张速览卡展示的就是点进去那一页的内容。下面四组
// 守的是 BUG（下载 / 游戏成人向 / 游戏运行中 / 音乐远端正在播放）：速览与页面
// 共用同一份数据源与判据，不再各算一份。

DownloadTaskEntry _task(
  String id, {
  required DownloadTaskKind kind,
  required DownloadTaskStatus status,
  int createdAt = 0,
  double? progress,
  String? subtitle,
}) => DownloadTaskEntry(
  id: id,
  title: id,
  kind: kind,
  status: status,
  createdAt: createdAt,
  progress: progress,
  subtitle: subtitle,
  builder: (BuildContext _) => const SizedBox.shrink(),
);

GalgameEntry _game(
  String id, {
  int lastPlayedMs = 0,
  bool nsfw = false,
  String exePath = '',
}) => GalgameEntry(
  id: id,
  name: id,
  exePath: exePath,
  workdir: r'Z:\g',
  addedAt: DateTime(2026),
  lastPlayedMs: lastPlayedMs,
  metadata: GalgameMetadataDraft(nsfw: nsfw),
);

String _code(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('下载速览与下载页同一份任务来源', () {
    tearDown(DownloadTaskShare.instance.reset);

    test('快照问遍来源清单上的每一项，漫画 / 转录 / 远端任务都在、按 id 去重', () async {
      final List<DownloadTaskSource> asked = <DownloadTaskSource>[];
      final List<DownloadTaskEntry> tasks = await collectDownloadTaskSnapshot(
        videoJobs: () => <DownloadTaskEntry>[
          _task(
            'job-1',
            kind: DownloadTaskKind.video,
            status: DownloadTaskStatus.completed,
            createdAt: 1,
          ),
        ],
        source: (DownloadTaskSource source) {
          asked.add(source);
          return switch (source) {
            DownloadTaskSource.manga => <DownloadTaskEntry>[
              _task(
                'manga:1',
                kind: DownloadTaskKind.manga,
                status: DownloadTaskStatus.active,
                createdAt: 5,
                progress: 0.25,
              ),
            ],
            DownloadTaskSource.transcribe => <DownloadTaskEntry>[
              _task(
                'audiobook-transcribe:1',
                kind: DownloadTaskKind.audiobook,
                status: DownloadTaskStatus.queued,
                createdAt: 4,
              ),
            ],
            DownloadTaskSource.remote => <DownloadTaskEntry>[
              _task(
                'remote:host:1',
                kind: DownloadTaskKind.video,
                status: DownloadTaskStatus.attention,
                createdAt: 3,
                subtitle: '客厅 PC',
              ),
            ],
            _ => const <DownloadTaskEntry>[],
          };
        },
      );
      expect(asked, DownloadTaskSource.values);
      expect(
        tasks.map((DownloadTaskEntry e) => e.id),
        unorderedEquals(<String>[
          'job-1',
          'manga:1',
          'audiobook-transcribe:1',
          'remote:host:1',
        ]),
      );

      final AdaptiveNavPeekData data = navPeekDownloadData(
        tasks,
        openDownloads: () {},
      );
      // 页面缺省排序：新建的在前；「继续」= 最前的下载中任务（漫画那条）。
      expect(data.resume?.title, 'manga:1');
      expect(data.resume?.status, '25%');
      expect(data.recent.map((AdaptiveNavPeekEntry e) => e.title), <String>[
        'audiobook-transcribe:1',
        'remote:host:1',
        'job-1',
      ]);
      expect(data.recent[1].subtitle, '客厅 PC');
      // 与下载页概况卡同一组计数，来源不止视频任务。
      expect(
        data.summary,
        <String>[
          t.download_summary_active(n: 1),
          t.download_summary_queued(n: 1),
          '${t.download_task_status_attention} 1',
          t.download_summary_completed(n: 1),
        ].join(' · '),
      );
    });

    test('只由下载页取的来源：读页面递出的最近一份，来源段 dispose 后清掉', () {
      final Object owner = Object();
      final List<DownloadTaskEntry> remote = <DownloadTaskEntry>[
        _task(
          'remote:host:7',
          kind: DownloadTaskKind.video,
          status: DownloadTaskStatus.active,
        ),
      ];
      final DownloadTaskShare share = DownloadTaskShare.instance;
      expect(share.entriesOf(DownloadTaskSharedPart.remoteHosts), isEmpty);
      share.publish(DownloadTaskSharedPart.remoteHosts, owner, remote);
      expect(
        share
            .entriesOf(DownloadTaskSharedPart.remoteHosts)
            .map((DownloadTaskEntry e) => e.id),
        <String>['remote:host:7'],
      );
      // 别人的 dispose 不清这一份。
      share.clearOwner(DownloadTaskSharedPart.remoteHosts, Object());
      expect(share.entriesOf(DownloadTaskSharedPart.remoteHosts), hasLength(1));
      share.clearOwner(DownloadTaskSharedPart.remoteHosts, owner);
      expect(share.entriesOf(DownloadTaskSharedPart.remoteHosts), isEmpty);
    });

    testWidgets('下载页按同一份清单逐个套来源段，最内层收到全部来源的条目', (WidgetTester tester) async {
      final List<DownloadTaskSource> wrapped = <DownloadTaskSource>[];
      List<DownloadTaskEntry>? leafTasks;
      await tester.pumpWidget(
        nestDownloadTaskSources(
          wrap: (DownloadTaskSource source, DownloadTasksBuilder tasks) {
            wrapped.add(source);
            return Builder(
              builder: (BuildContext context) =>
                  tasks(context, <DownloadTaskEntry>[
                    _task(
                      source.name,
                      kind: DownloadTaskKind.video,
                      status: DownloadTaskStatus.active,
                    ),
                  ]),
            );
          },
          leaf: (BuildContext context, List<DownloadTaskEntry> tasks) {
            leafTasks = tasks;
            return const SizedBox.shrink();
          },
        ),
      );
      expect(wrapped, DownloadTaskSource.values);
      expect(
        leafTasks?.map((DownloadTaskEntry e) => e.id),
        DownloadTaskSource.values.map((DownloadTaskSource s) => s.name),
      );
    });

    test('页面与速览都按清单接线（守卫）', () {
      final String browse = _code(
        'lib/src/pages/implementations/browse_page.dart',
      );
      expect(browse, contains('nestDownloadTaskSources('));
      final String peek = _code(
        'lib/src/pages/implementations/home_nav_peek.dart',
      );
      expect(peek, contains('loadDownloadTaskSnapshot('));
      // 取数只经按清单问遍各来源的快照（视频任务表也在里面读），速览入口自己不再
      // 单读视频任务表。
      expect(peek, contains('collectDownloadTaskSnapshot('));
      final int start = peek.indexOf(
        'Future<AdaptiveNavPeekData> _loadDownloads(',
      );
      final String loadDownloads = peek.substring(
        start,
        peek.indexOf(
          'Future<List<DownloadTaskEntry>> loadDownloadTaskSnapshot(',
          start,
        ),
      );
      expect(loadDownloads, contains('loadDownloadTaskSnapshot('));
      expect(loadDownloads, isNot(contains('getVideoDownloadJobs')));
    });
  });

  group('游戏速览与游戏首页同一份可见口径与「继续」', () {
    AdaptiveNavPeekEntry entryOf(GalgameEntry g) =>
        AdaptiveNavPeekEntry.noCover(title: g.id, onOpen: () {});

    test('「隐藏成人向」：库页筛选、首页判据与速览一起藏', () {
      final GalgameEntry adult = _game('adult', lastPlayedMs: 30, nsfw: true);
      final GalgameEntry plain = _game('plain', lastPlayedMs: 10);
      expect(galgameHiddenByNsfwPref(adult, hideNsfw: true), isTrue);
      expect(galgameHiddenByNsfwPref(adult, hideNsfw: false), isFalse);
      expect(
        matchesGalgameFilters(adult, const GalgameLibraryView(hideNsfw: true)),
        isFalse,
      );
      expect(
        galgameShownOnHome(
          adult,
          hideNsfw: true,
          visibility: MediaVisibility.all,
        ),
        isFalse,
      );
      final NavPeekFeed hidden = navPeekGamesFeed(
        <GalgameEntry>[adult, plain],
        hideNsfw: true,
        visibility: MediaVisibility.all,
        runningExe: null,
        nowMs: 1000,
        entryOf: entryOf,
      );
      expect(hidden.resume?.entry.title, 'plain');
      expect(hidden.recent, isEmpty);
      final NavPeekFeed shown = navPeekGamesFeed(
        <GalgameEntry>[adult, plain],
        hideNsfw: false,
        visibility: MediaVisibility.all,
        runningExe: null,
        nowMs: 1000,
        entryOf: entryOf,
      );
      expect(shown.resume?.entry.title, 'adult');
    });

    test('正在运行的游戏是首块，从没玩过也算；按此刻计时', () {
      final GalgameEntry recent = _game(
        'recent',
        lastPlayedMs: 500,
        exePath: r'C:\Games\Recent\recent.exe',
      );
      final GalgameEntry running = _game(
        'running',
        exePath: r'C:\Games\New\new.exe',
      );
      final NavPeekFeed feed = navPeekGamesFeed(
        <GalgameEntry>[recent, running],
        hideNsfw: false,
        visibility: MediaVisibility.all,
        // 会话报的路径分隔符 / 大小写与库里不同，照样认出（与首页同一口径）。
        runningExe: 'c:/games/new/NEW.exe',
        nowMs: 9999,
        entryOf: entryOf,
      );
      expect(feed.resume?.entry.title, 'running');
      expect(feed.resume?.at, 9999);
      expect(feed.recent.map((NavPeekTimed e) => e.entry.title), <String>[
        'recent',
      ]);
      // 首页用的是同一个选取。
      expect(
        galgameHomeContinue(<GalgameEntry>[
          recent,
          running,
        ], runningExe: r'C:\Games\New\new.exe').hero?.id,
        'running',
      );
    });

    test('游戏首页与速览都走共享判据（守卫）', () {
      final String home = _code(
        'lib/src/pages/implementations/galgame_home_page.dart',
      );
      expect(home, contains('galgameShownOnHome('));
      expect(home, contains('galgameHomeContinue('));
      final String peek = _code(
        'lib/src/pages/implementations/home_nav_peek.dart',
      );
      expect(peek, contains('navPeekGamesFeed('));
    });
  });

  group('音乐速览的正在播放取播放项本身', () {
    test('服务器曲目（合成 uid、不在曲库表）照样出「继续」，副行同播放条', () {
      const MusicPlayItem item = MusicPlayItem(
        trackUid: 'srv:0123456789abcdef',
        path: 'https://music.example/stream/42',
        title: '夜に駆ける',
        artist: 'YOASOBI',
        album: 'THE BOOK',
        albumUid: 'srva:feedface',
        coverPath: 'https://music.example/cover/42',
      );
      final AdaptiveNavPeekEntry entry = navPeekNowPlayingEntry(
        item,
        cover: null,
        blurCover: false,
        onOpen: () {},
      );
      expect(entry.title, '夜に駆ける');
      expect(entry.subtitle, 'YOASOBI · THE BOOK');
      final AdaptiveNavPeekEntry bare = navPeekNowPlayingEntry(
        const MusicPlayItem(trackUid: 'plg:1', path: 'plugin://x', title: 'x'),
        cover: null,
        blurCover: false,
        onOpen: () {},
      );
      expect(bare.subtitle, isNull);
    });

    test('正在播放不再先查曲库表（守卫）', () {
      final String peek = _code(
        'lib/src/pages/implementations/home_nav_peek.dart',
      );
      expect(peek, contains(RegExp(r'navPeekNowPlayingEntry\(\s*current,')));
    });
  });
}
