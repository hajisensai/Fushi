// BUG-5277：侧栏「首页」悬停速览与首页 dashboard「继续」区是同一份编排
// [composeHomeContinue]（来源 / 门控 / 去重 / 折叠 / 排序）。此前速览只混本地书 /
// 漫画 / 视频 / 游戏，缺互联 host 远端书、自配服务器条目，游戏不按合集折叠，远端
// 视频合集也不与本地同名合集去重。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_continue_compose.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_derived.dart'
    show HomeDashboardVideoIndex;
import 'package:fushi/src/pages/implementations/home_nav_peek.dart'
    show planHomeNavPeek;
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart'
    show RemoteContinueCandidate;
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart'
    show ServerContinueCandidate, ServerContinueSource;
import 'package:fushi_core/fushi_core.dart' show MediaKind, VideoBookRow;

MediaItem _book(String key, String title, {required int position}) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
  title: title,
  mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
  mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
  position: position,
  duration: 100,
  canDelete: false,
  // 不走书名 override 存储（纯函数测试不装偏好）。
  canEdit: false,
);

VideoBookRow _video(
  String uid, {
  String? title,
  int positionMs = 0,
  DateTime? completedAt,
}) => VideoBookRow(
  bookUid: uid,
  title: title ?? uid,
  videoPath: '/videos/$uid.mkv',
  lastPositionMs: positionMs,
  currentEpisode: 0,
  delayMs: 0,
  completedAt: completedAt,
);

GalgameEntry _game(String id, {required int lastPlayedMs}) => GalgameEntry(
  id: id,
  name: id,
  exePath: 'C:/$id/$id.exe',
  workdir: 'C:/$id',
  addedAt: DateTime(2026),
  lastPlayedMs: lastPlayedMs,
);

ServerContinueCandidate _server(
  ServerContinueSource source,
  String id, {
  required int recentMs,
  String? collectionName,
}) => ServerContinueCandidate(
  source: source,
  serverId: 'srv',
  serverName: 'MyServer',
  itemId: id,
  title: id,
  collectionName: collectionName,
  recentMs: recentMs,
  open: (_) async {},
);

HomeContinueInputs _inputs({
  List<MediaItem> books = const <MediaItem>[],
  Map<String, int> lastReadByUid = const <String, int>{},
  List<VideoBookRow> videos = const <VideoBookRow>[],
  Map<String, int> watchAt = const <String, int>{},
  List<GalgameEntry> games = const <GalgameEntry>[],
  Map<String, int> primary = const <String, int>{},
  Map<int, String> names = const <int, String>{},
  List<RemoteContinueCandidate> remote = const <RemoteContinueCandidate>[],
  List<ServerContinueCandidate> server = const <ServerContinueCandidate>[],
  bool mediaServerGate = false,
  bool audiobookshelfGate = false,
  Set<ModuleId> disabled = const <ModuleId>{},
}) => HomeContinueInputs(
  books: books,
  lastReadByUid: lastReadByUid,
  epubUidByKey: const <String, String>{},
  completedBookKeys: const <String>{},
  collectionEpubUidByKey: const <String, String>{},
  primaryCollectionByEntry: primary,
  memberSortIndex: const <String, int>{},
  collectionNamesById: names,
  videoIndex: HomeDashboardVideoIndex.build(
    videos: videos,
    primaryCollectionByEntry: primary,
    memberSortIndex: const <String, int>{},
  ),
  videoWatchAtByUid: watchAt,
  videoDurationMsOf: (_) => null,
  games: games,
  remote: remote,
  server: server,
  mediaServerGate: mediaServerGate,
  audiobookshelfGate: audiobookshelfGate,
  isModuleEnabled: (ModuleId m) => !disabled.contains(m),
);

List<String> _titles(Iterable<HomeContinueUnit> units) => <String>[
  for (final HomeContinueUnit u in units) u.displayTitle,
];

void main() {
  test('互联 host 的远端书进「继续」，与本地条目按最近时刻混排', () {
    final List<HomeContinueUnit> units = composeHomeContinue(
      _inputs(
        books: <MediaItem>[_book('local', '本地书', position: 40)],
        lastReadByUid: const <String, int>{'local': 100},
        remote: const <RemoteContinueCandidate>[
          RemoteContinueCandidate(
            kind: MediaKind.epub,
            id: 'host-book',
            title: '远端书',
            recentMs: 500,
            percent: 30,
          ),
        ],
      ),
    );
    expect(_titles(units), <String>['远端书', '本地书']);
    expect(units.first, isA<HomeContinueRemoteUnit>());
    expect(units.first.module, ModuleId.books);
  });

  test('Jellyfin 条目受「混排」门控：门开着进且按时刻排在最前，门关着不进', () {
    final List<ServerContinueCandidate> server = <ServerContinueCandidate>[
      _server(
        ServerContinueSource.mediaServer,
        'ep3',
        recentMs: 900,
        collectionName: '某剧',
      ),
    ];
    final List<HomeContinueUnit> on = composeHomeContinue(
      _inputs(
        videos: <VideoBookRow>[_video('v1', positionMs: 1000)],
        watchAt: const <String, int>{'v1': 200},
        server: server,
        mediaServerGate: true,
      ),
    );
    expect(_titles(on), <String>['某剧', 'v1']);
    expect(on.first, isA<HomeContinueServerUnit>());
    expect(on.first.module, ModuleId.video);

    final List<HomeContinueUnit> off = composeHomeContinue(
      _inputs(
        videos: <VideoBookRow>[_video('v1', positionMs: 1000)],
        watchAt: const <String, int>{'v1': 200},
        server: server,
      ),
    );
    expect(_titles(off), <String>['v1']);
  });

  test('Audiobookshelf 条目只在它自己的门开着时进（媒体服务器的门管不到它）', () {
    final List<ServerContinueCandidate> server = <ServerContinueCandidate>[
      _server(ServerContinueSource.audiobookshelf, 'abs-book', recentMs: 10),
    ];
    expect(
      composeHomeContinue(_inputs(server: server, mediaServerGate: true)),
      isEmpty,
    );
    final List<HomeContinueUnit> on = composeHomeContinue(
      _inputs(server: server, audiobookshelfGate: true),
    );
    expect(_titles(on), <String>['abs-book']);
    expect(on.single.module, ModuleId.books);
    // 书模块关着：ABS 条目随书模块出局。
    expect(
      composeHomeContinue(
        _inputs(
          server: server,
          audiobookshelfGate: true,
          disabled: <ModuleId>{ModuleId.books},
        ),
      ),
      isEmpty,
    );
  });

  test('游戏按主合集折叠：一个合集一张卡，标题取合集名、续玩目标是最近玩的那部', () {
    final List<HomeContinueUnit> units = composeHomeContinue(
      _inputs(
        games: <GalgameEntry>[
          _game('g1', lastPlayedMs: 100),
          _game('g2', lastPlayedMs: 300),
          _game('solo', lastPlayedMs: 200),
          _game('never', lastPlayedMs: 0),
        ],
        primary: <String, int>{
          MediaKind.game.compositeKey('g1'): 7,
          MediaKind.game.compositeKey('g2'): 7,
        },
        names: const <int, String>{7: '某系列'},
      ),
    );
    expect(_titles(units), <String>['某系列', 'solo']);
    final HomeContinueGameUnit series = units.first as HomeContinueGameUnit;
    expect(series.game.id, 'g2');
    expect(series.collectionName, '某系列');
  });

  test('远端视频合集与本地同名合集去重（本地那张卡代表这个合集）', () {
    final List<HomeContinueUnit> units = composeHomeContinue(
      _inputs(
        videos: <VideoBookRow>[
          _video('e1', completedAt: DateTime(2026)),
          _video('e2'),
        ],
        primary: <String, int>{
          MediaKind.video.compositeKey('e1'): 3,
          MediaKind.video.compositeKey('e2'): 3,
        },
        names: const <int, String>{3: '进击的巨人'},
        watchAt: const <String, int>{'e1': 100},
        remote: const <RemoteContinueCandidate>[
          RemoteContinueCandidate(
            kind: MediaKind.video,
            id: 'host-e3',
            title: 'E3',
            recentMs: 999,
            collectionName: '进击的巨人',
          ),
          RemoteContinueCandidate(
            kind: MediaKind.video,
            id: 'host-other',
            title: 'O1',
            recentMs: 50,
            collectionName: '别的剧',
          ),
        ],
      ),
    );
    expect(_titles(units), <String>['进击的巨人', '别的剧']);
    final HomeContinueVideoUnit local = units.first as HomeContinueVideoUnit;
    // 合集 Next-Up：E1 看完 → 续播 E2（第 2 集）。
    expect(local.row.bookUid, 'e2');
    expect(local.collectionEpisode, 2);
  });

  test('关掉的模块先出局再取前 N 条', () {
    final List<HomeContinueUnit> units = composeHomeContinue(
      _inputs(
        games: <GalgameEntry>[
          for (int i = 0; i < 12; i++) _game('g$i', lastPlayedMs: 1000 + i),
        ],
        books: <MediaItem>[_book('b', '书', position: 10)],
        lastReadByUid: const <String, int>{'b': 1},
        disabled: <ModuleId>{ModuleId.games},
      ),
    );
    expect(_titles(units), <String>['书']);
  });

  test('首页速览与 dashboard「继续」同一份结果、同一顺序：「继续」= 第一张，「最近」= 接下来四张', () {
    final List<HomeContinueUnit> dashboard = composeHomeContinue(
      _inputs(
        books: <MediaItem>[_book('b', '在读', position: 10)],
        lastReadByUid: const <String, int>{'b': 400},
        videos: <VideoBookRow>[_video('v', positionMs: 5)],
        watchAt: const <String, int>{'v': 300},
        games: <GalgameEntry>[
          _game('g1', lastPlayedMs: 200),
          _game('g2', lastPlayedMs: 100),
        ],
        remote: const <RemoteContinueCandidate>[
          RemoteContinueCandidate(
            kind: MediaKind.epub,
            id: 'r',
            title: '远端',
            recentMs: 600,
            percent: 5,
          ),
        ],
        server: <ServerContinueCandidate>[
          _server(ServerContinueSource.mediaServer, 'jf', recentMs: 50),
        ],
        mediaServerGate: true,
      ),
    );
    expect(_titles(dashboard), <String>['远端', '在读', 'v', 'g1', 'g2', 'jf']);
    final ({HomeContinueUnit? resume, List<HomeContinueUnit> recent}) peek =
        planHomeNavPeek(dashboard);
    expect(
      _titles(<HomeContinueUnit>[?peek.resume, ...peek.recent]),
      _titles(dashboard.take(5)),
    );
    expect(planHomeNavPeek(const <HomeContinueUnit>[]).resume, isNull);
  });

  test('dashboard 与首页速览都经 composeHomeContinue 编排，不各写一套', () {
    String body(String path, String signature) {
      final String source = File(path).readAsStringSync();
      final int start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '$path 缺 $signature');
      final int end = source.indexOf('\n  }\n', start);
      return source.substring(start, end < 0 ? source.length : end);
    }

    expect(
      body(
        'lib/src/pages/implementations/home_dashboard_page.dart',
        'List<_ContinueEntry> _computeContinueEntries(',
      ),
      contains('composeHomeContinue('),
    );
    final String peek = File(
      'lib/src/pages/implementations/home_nav_peek.dart',
    ).readAsStringSync();
    final int loadHome = peek.indexOf('Future<AdaptiveNavPeekData> _loadHome(');
    expect(loadHome, isNonNegative);
    final String loadHomeBody = peek.substring(
      loadHome,
      peek.indexOf('\n}\n', loadHome),
    );
    expect(loadHomeBody, contains('composeHomeContinue('));
    expect(loadHomeBody, contains('planHomeNavPeek('));
    // 远端 / 服务器两路只读首页取好的进程级结果，悬停不发网络请求。
    expect(loadHomeBody, contains('RemoteContinueFeed.of('));
    expect(loadHomeBody, contains('ServerContinueFeed.of(db).current'));
    expect(loadHomeBody, isNot(contains('ServerContinueFeed.of(db).load')));
  });
}
