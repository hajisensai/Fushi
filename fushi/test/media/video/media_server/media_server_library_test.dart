import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/video_watched_marks.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/jellyfin_library_scope.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/updates/video_library_update_probe.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/strm_file.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi_engine/updates/update_feed_port.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../pages/media_server/fake_media_server_browser.dart';

/// 剧集带上剧名合集归属（与 Jellyfin / Plex 实现同口径），否则收养无从验证。
class _CollectionBrowser extends FakeMediaServerBrowser {
  _CollectionBrowser() : super(serverId: 'jellyfin:http://srv|u1');

  @override
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item) => RemoteVideoInfo(
    id: item.id,
    title: item.name,
    coverUrl: 'http://srv/Items/${item.id}/Images/Primary?api_key=SECRET',
    positionMs: 1234,
    collection: mediaServerCollectionOf(item),
  );
}

class _FakeConfig implements MediaServerConfig {
  _FakeConfig(this.browser);

  final MediaServerBrowser browser;

  @override
  MediaServerKind get kind => MediaServerKind.jellyfin;
  @override
  String get sourceId => browser.serverId;
  @override
  String get accountName => 'u1';
  @override
  List<String> get routeUrls => const <String>['http://srv'];
  @override
  String get effectiveServerUrl => 'http://srv';
  @override
  MediaServerConfig withActiveRoute(String url) => this;
  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
  @override
  MediaServerBrowser buildBrowser({http.Client? httpClient}) => browser;
}

class _RecordingPublisher implements UpdateFeedPublisher {
  final List<UpdateFeedDraft> drafts = <UpdateFeedDraft>[];

  @override
  Future<void> publishBatch(
    UpdateFeedKind kind,
    List<UpdateFeedDraft> batch,
  ) async {
    drafts.addAll(batch);
  }
}

MediaServerItem _episode(String id, int season, int number) => MediaServerItem(
  id: id,
  name: 'Ep $number',
  type: MediaServerItemType.episode,
  seriesId: 'show',
  seriesName: 'The Show',
  seasonNumber: season,
  episodeNumber: number,
);

void main() {
  const MediaServerItem series = MediaServerItem(
    id: 'show',
    name: 'The Show',
    type: MediaServerItemType.series,
  );

  late Directory root;
  late EnginePaths previousPaths;
  late FushiDatabase database;
  late VideoBookRepository repository;
  late MediaServerVideoLibrary library;
  late _CollectionBrowser browser;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-ms-library-');
    previousPaths = enginePaths;
    enginePaths = FixedEnginePaths(
      documents: Directory(p.join(root.path, 'documents')),
      support: Directory(p.join(root.path, 'support')),
      temp: Directory(p.join(root.path, 'temp')),
    );
    VideoCoverMutationGate.debugResetForTesting();
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = VideoBookRepository(database);
    library = MediaServerVideoLibrary(
      database: database,
      repository: repository,
    );
    browser = _CollectionBrowser();
    // 整部剧（不带 SeasonId）跨两季。
    browser.episodes['show|'] = <MediaServerItem>[
      _episode('e1', 1, 1),
      _episode('e2', 1, 2),
      _episode('e3', 2, 1),
    ];
    browser.details['show'] = series;
  });

  tearDown(() async {
    await database.close();
    enginePaths = previousPaths;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('path scheme counts as network-only and as a stream book', () {
    final String path = mediaServerVideoPath(itemId: 'e1', label: 'A: B?');
    expect(path, startsWith('media-server://e1/'));
    expect(isMediaServerVideoPath(path), isTrue);
    expect(isMediaServerVideoPath('  MEDIA-SERVER://x/y'), isTrue);
    expect(isMediaServerVideoPath('anime-source://x/y'), isFalse);
    expect(isNetworkOnlyVideoPath(path), isTrue);
  });

  test('spec round-trips and never stores the tokenised cover URL or the '
      'stale resume point', () {
    final MediaServerBookSpec spec = MediaServerBookSpec(
      serverId: 'srv',
      info: browser.toRemoteVideoInfo(_episode('e1', 1, 1)),
      workId: 'show',
    );
    final String raw = spec.encode();
    expect(raw, isNot(contains('SECRET')));
    expect(raw, isNot(contains('1234')));
    final MediaServerBookSpec back = MediaServerBookSpec.tryParse(raw)!;
    expect(back.serverId, 'srv');
    expect(back.itemId, 'e1');
    expect(back.workId, 'show');
    expect(back.info.collection?.collectionName, 'The Show');
    expect(MediaServerBookSpec.tryParse('{"kind":"anime-source"}'), isNull);
    expect(MediaServerBookSpec.tryParse('not json'), isNull);
  });

  test('add series: one stream row per episode across all seasons, adopted '
      'into the series playlist; re-adding only fills new episodes; remove '
      'deletes the rows', () async {
    expect((await library.statusOf(browser, series)).inLibrary, isFalse);
    expect(await library.addToLibrary(browser, series), 3);

    final VideoBookRow row = (await repository.getByBookUid('e2'))!;
    expect(isMediaServerVideoPath(row.videoPath), isTrue);
    expect(isStreamVideoBook(row), isTrue);
    final MediaCollectionRow collection = (await database
        .getMediaCollectionByNaturalKey('The Show', 'playlist'))!;
    expect(await database.getCollectionItems(collection.id), hasLength(3));
    expect((await library.statusOf(browser, series)).online, <String>{
      'e1',
      'e2',
      'e3',
    });

    expect(await library.addToLibrary(browser, series), 0);
    browser.episodes['show|'] = <MediaServerItem>[
      ...browser.episodes['show|']!,
      _episode('e4', 2, 2),
    ];
    final List<RemoteVideoInfo> added = await library.addMissing(
      browser,
      series,
    );
    expect(added.map((RemoteVideoInfo i) => i.id), <String>['e4']);

    expect(await library.removeFromLibrary(browser, series), 4);
    expect(await repository.getByBookUid('e1'), isNull);
    expect((await library.statusOf(browser, series)).inLibrary, isFalse);
  });

  test('「在库」只认本地行：整库混排关着时不连服务器、不另存加入项清单；在库的集'
      '标已看回写那台服务器', () async {
    expect(await library.addToLibrary(browser, series), 3);
    expect((await library.statusOf(browser, series)).inLibrary, isTrue);

    final PreferencesRepository prefs = PreferencesRepository(database);
    await prefs.loadFromDb();
    expect(prefs.jellyfinShowInLibrary, isFalse);
    expect(
      await resolveJellyfinLibraryClient(
        prefs: prefs,
        syncRepo: SyncRepository(database),
      ),
      isNull,
      reason: '加入媒体库的条目是本地行，不靠第二份「加入项」清单去列服务器',
    );
    expect(await database.getPref('jellyfin_library_items'), isNull);

    final _PlayedRecorder server = _PlayedRecorder();
    final List<String> resolved = <String>[];
    final WatchedMarkResult result = await setVideosWatched(
      db: database,
      watched: true,
      localUids: <String>['e1', 'e2'],
      mediaServerMarker: (String serverId) async {
        resolved.add(serverId);
        return server;
      },
    );
    expect(result.localChanged, 2);
    expect(server.calls, unorderedEquals(<String>['e1:true', 'e2:true']));
    expect(resolved.toSet(), <String>{browser.serverId});
  });

  test('lib 里不再有第二份「在库」真相源（jellyfin_library_items）', () {
    final List<String> hits = <String>[
      for (final FileSystemEntity e in Directory(
        'lib',
      ).listSync(recursive: true))
        if (e is File &&
            e.path.endsWith('.dart') &&
            e.readAsStringSync().contains('jellyfin_library_items'))
          e.path,
    ];
    expect(hits, isEmpty);
  });

  test('movie is one row keyed by itself and is not a series work', () async {
    const MediaServerItem movie = MediaServerItem(
      id: 'm1',
      name: 'A Movie',
      type: MediaServerItemType.movie,
    );
    expect(await library.addToLibrary(browser, movie), 1);
    expect((await library.statusOf(browser, movie)).online, <String>{'m1'});
    expect(await library.seriesWorksInLibrary(), isEmpty);
  });

  test('launch rebuilds the client from the signed-in server and uses the '
      'series rows in the playlist as members', () async {
    await library.addToLibrary(browser, series);
    final MediaCollectionRow collection = (await database
        .getMediaCollectionByNaturalKey('The Show', 'playlist'))!;
    final VideoBookRow row = (await repository.getByBookUid('e2'))!;
    final launch = await buildMediaServerLaunch(
      row: row,
      database: database,
      repository: repository,
      loadConfigs: () async => <MediaServerConfig>[_FakeConfig(browser)],
      playlistCollectionId: collection.id,
    );
    expect(identical(launch.client, browser.playbackClient), isTrue);
    expect(launch.members.map((RemoteVideoInfo i) => i.id), <String>[
      'e1',
      'e2',
      'e3',
    ]);
    expect(launch.startIndex, 1);
    expect(launch.info.id, 'e2');

    await expectLater(
      buildMediaServerLaunch(
        row: row,
        database: database,
        repository: repository,
        loadConfigs: () async => const <MediaServerConfig>[],
      ),
      throwsA(isA<MediaServerLaunchUnavailable>()),
    );
  });

  test('background probe fills new episodes of in-library series and '
      'publishes them as video-episode updates', () async {
    await library.addToLibrary(browser, series);
    final _RecordingPublisher feed = _RecordingPublisher();
    Future<List<MediaServerConfig>> configs() async => <MediaServerConfig>[
      _FakeConfig(browser),
    ];

    expect(
      await runVideoLibraryUpdateProbe(
        database: database,
        feed: feed,
        loadMediaServers: configs,
      ),
      0,
    );
    expect(feed.drafts, isEmpty);

    browser.episodes['show|'] = <MediaServerItem>[
      ...browser.episodes['show|']!,
      _episode('e4', 2, 2),
    ];
    expect(
      await runVideoLibraryUpdateProbe(
        database: database,
        feed: feed,
        loadMediaServers: configs,
      ),
      1,
    );
    expect(await repository.getByBookUid('e4'), isNotNull);
    final UpdateFeedDraft draft = feed.drafts.single;
    expect(draft.kind, UpdateFeedKind.videoEpisode);
    expect(draft.title, 'The Show');
    final Map<String, Object?> detail =
        jsonDecode(draft.detailJson!) as Map<String, Object?>;
    expect(detail['bookUid'], 'e4');
    expect(detail['collectionId'], isA<int>());

    // 服务器登出：查不了就跳过，不报错也不删行。
    expect(
      await runVideoLibraryUpdateProbe(
        database: database,
        feed: feed,
        loadMediaServers: () async => const <MediaServerConfig>[],
      ),
      0,
    );
    expect(await repository.getByBookUid('e1'), isNotNull);
  });
}

class _PlayedRecorder implements RemoteVideoPlayedMark {
  final List<String> calls = <String>[];

  @override
  Future<void> setRemoteVideoPlayed(String id, {required bool played}) async {
    calls.add('$id:$played');
  }
}
