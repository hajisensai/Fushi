// RemoteVideoListStore: the media-server remote video list persisted to disk
// (stale-while-revalidate) and the "did the server change?" short-circuit.
//
// Pins: token-free round trip (cover URLs re-signed with the route / token of
// the moment), corrupt / old-format / other-scope files ignored and rewritten,
// logout pruning, cold start serving the persisted list before the network,
// and the revalidation rules (unchanged stamp -> no enumeration, changed /
// no stamp / manual refresh -> full enumeration).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/persisted_remote_video_list.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/remote_video_list_store.dart';
import 'package:fushi/src/sync/server_url_credentials.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;

void main() {
  late Directory dir;
  late RemoteLibraryCache cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_remote_video_list');
    RemoteVideoListStore.debugReset();
    RemoteVideoListStore.debugSetDirResolver(() async => dir);
    cache = RemoteLibraryCache();
  });

  tearDown(() async {
    // fetchList 的落盘不等（unawaited）：删目录前先等它写完。
    await RemoteVideoListStore.debugFlushWrites();
    RemoteVideoListStore.debugSetDirResolver(null);
    RemoteVideoListStore.debugReset();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File fileOf(_FakeSource source) => File(
    '${dir.path}${Platform.pathSeparator}'
    '${RemoteVideoListStore.fileNameFor(source.remoteLibrarySourceId)}',
  );

  Future<void> persist(
    _FakeSource source,
    List<RemoteVideoInfo> videos, {
    String? stamp,
  }) async {
    await RemoteVideoListStore.save(
      source: source,
      videos: videos,
      stamp: stamp,
    );
    await RemoteVideoListStore.debugFlushWrites();
  }

  group('round trip', () {
    test(
      'no token on disk; covers re-signed with the current route and token',
      () async {
        final _FakeSource source = _FakeSource(
          credentials: const ServerUrlCredentials(
            baseUrl: 'http://jf-lan:8096',
            token: 'SECRET-TOKEN-1',
          ),
        );
        final RemoteVideoInfo episode = RemoteVideoInfo(
          id: 'ep1',
          title: 'Show S01E01 Pilot',
          hasSubtitle: true,
          durationMs: 1440000,
          hasCover: true,
          coverUrl:
              'http://jf-lan:8096/Items/ep1/Images/Primary?maxWidth=400&quality=90&api_key=SECRET-TOKEN-1',
          seriesCoverUrl:
              'http://jf-lan:8096/Items/s1/Images/Primary?maxWidth=400&quality=90&api_key=SECRET-TOKEN-1',
          workBackdropItemId: 's1',
          workLogoItemId: 's1-logo',
          completedAt: 1700000000000,
          positionMs: 5000,
          positionUpdatedAtMs: 1700000000000,
          collection: const RemoteCollectionMembership(
            collectionName: 'Show',
            collectionType: 'playlist',
            sortIndex: 10001,
          ),
        );
        await persist(source, <RemoteVideoInfo>[episode], stamp: 'stamp-1');

        final String raw = fileOf(source).readAsStringSync();
        expect(raw, isNot(contains('SECRET-TOKEN-1')));
        expect(raw, isNot(contains('api_key')));
        expect(
          raw,
          isNot(contains('http://jf-lan:8096/Items')),
          reason: 'route not baked into the cover URLs',
        );

        // Re-login (new token) and a route switch since the list was saved.
        source.credentials = const ServerUrlCredentials(
          baseUrl: 'https://jf.example:8920',
          token: 'SECRET-TOKEN-2',
        );
        final List<RemoteVideoInfo>? loaded = await RemoteVideoListStore.load(
          source,
        );
        expect(loaded, hasLength(1));
        final RemoteVideoInfo back = loaded!.single;
        expect(
          back.coverUrl,
          'https://jf.example:8920/Items/ep1/Images/Primary?maxWidth=400&quality=90&api_key=SECRET-TOKEN-2',
        );
        expect(
          back.seriesCoverUrl,
          'https://jf.example:8920/Items/s1/Images/Primary?maxWidth=400&quality=90&api_key=SECRET-TOKEN-2',
        );
        // Work-level art ids (client-only, BUG-5614) survive as-is.
        expect(back.workBackdropItemId, 's1');
        expect(back.workLogoItemId, 's1-logo');
        // Every other field survives unchanged.
        final Map<String, Object?> want = episode.toJson()..remove('coverUrl');
        final Map<String, Object?> got = back.toJson()..remove('coverUrl');
        expect(jsonEncode(got), jsonEncode(want));
      },
    );

    test(
      'a cover URL that is not on the current route is dropped, not persisted',
      () async {
        final _FakeSource source = _FakeSource();
        await persist(source, const <RemoteVideoInfo>[
          RemoteVideoInfo(
            id: 'm1',
            title: 'Movie',
            hasCover: true,
            coverUrl: 'http://other-host/img.jpg?api_key=LEAK',
          ),
        ]);
        expect(fileOf(source).readAsStringSync(), isNot(contains('LEAK')));
        final RemoteVideoInfo back = (await RemoteVideoListStore.load(
          source,
        ))!.single;
        expect(back.coverUrl, isNull);
        expect(back.hasCover, isTrue);
      },
    );

    test('ServerUrlCredentials.strip is the exact inverse of authorize', () {
      const ServerUrlCredentials c = ServerUrlCredentials(
        baseUrl: 'http://nas:8096/jellyfin',
        token: 'tok',
      );
      const String url =
          'http://nas:8096/jellyfin/Items/x/Images/Backdrop?maxWidth=1280&quality=90&api_key=tok';
      expect(c.strip(url), '/Items/x/Images/Backdrop?maxWidth=1280&quality=90');
      expect(c.authorize(c.strip(url)!), url);
      expect(c.strip('http://nas:8096/Items/x?API_KEY=tok'), isNull);
      expect(
        const ServerUrlCredentials(
          baseUrl: 'http://nas:8096',
          token: 'tok',
        ).strip('http://nas:8096/Items/x?API_KEY=tok'),
        '/Items/x',
        reason: 'credential key matched case-insensitively',
      );
    });
  });

  group('invalid files are ignored, never thrown, and rewritten', () {
    test('corrupt JSON', () async {
      final _FakeSource source = _FakeSource();
      dir.createSync(recursive: true);
      fileOf(source).writeAsStringSync('{"format": 1, "videos": [ {"id": ');
      expect(await RemoteVideoListStore.load(source), isNull);

      await persist(source, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'a', title: 'A'),
      ]);
      expect(
        (await RemoteVideoListStore.load(source))!.single.id,
        'a',
        reason: 'the next save overwrites the broken file',
      );
    });

    test('wrong shape / unknown format version / other source id', () async {
      final _FakeSource source = _FakeSource();
      await persist(source, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'a', title: 'A'),
      ]);
      final Map<String, Object?> good =
          jsonDecode(fileOf(source).readAsStringSync()) as Map<String, Object?>;

      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{
          ...good,
          'format': RemoteVideoListStore.formatVersion + 1,
        },
        <String, Object?>{...good, 'sourceId': 'jellyfin:http://other|u'},
        <String, Object?>{...good, 'videos': 'nope'},
        <String, Object?>{
          ...good,
          'videos': <Object?>[42],
        },
      ]) {
        fileOf(source).writeAsStringSync(jsonEncode(bad));
        expect(await RemoteVideoListStore.load(source), isNull, reason: '$bad');
      }
      fileOf(source).writeAsStringSync('[1, 2, 3]');
      expect(await RemoteVideoListStore.load(source), isNull);
    });

    test('library-scope change invalidates the persisted list', () async {
      final _FakeSource source = _FakeSource(scope: 'libraries=a');
      await persist(source, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'a', title: 'A'),
      ]);
      source.scope = 'libraries=a,b';
      expect(await RemoteVideoListStore.load(source), isNull);
    });

    test(
      'no cache directory (pure unit test without path_provider) = no-op',
      () async {
        RemoteVideoListStore.debugSetDirResolver(() async => null);
        final _FakeSource source = _FakeSource();
        await persist(source, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'a', title: 'A'),
        ]);
        expect(await RemoteVideoListStore.load(source), isNull);
      },
    );
  });

  test(
    'logout: retainSources deletes other sources and drops their late writes',
    () async {
      final _FakeSource kept = _FakeSource(sourceId: 'jellyfin:http://a|u1');
      final _FakeSource gone = _FakeSource(sourceId: 'jellyfin:http://b|u2');
      await persist(kept, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'k', title: 'K'),
      ]);
      await persist(gone, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'g', title: 'G'),
      ]);

      await RemoteVideoListStore.retainSources(<String>[
        kept.remoteLibrarySourceId,
      ]);

      expect(fileOf(kept).existsSync(), isTrue);
      expect(fileOf(gone).existsSync(), isFalse);
      // An enumeration that was still running at logout finishes afterwards.
      await persist(gone, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'g', title: 'G'),
      ]);
      expect(fileOf(gone).existsSync(), isFalse);
      expect(await RemoteVideoListStore.load(gone), isNull);
    },
  );

  group('revalidation (fetchList)', () {
    test(
      'unchanged stamp: hands back the same list object, no enumeration',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1']);
        final List<RemoteVideoInfo> first =
            await RemoteVideoListStore.fetchList(
              source: source,
              forceRefresh: false,
              current: null,
            );
        expect(source.listCalls, 1);
        source.unchanged = true;

        final List<RemoteVideoInfo> again =
            await RemoteVideoListStore.fetchList(
              source: source,
              forceRefresh: false,
              current: first,
            );
        expect(identical(again, first), isTrue);
        expect(source.checkedStamps, <String>['s1']);
        expect(source.listCalls, 1, reason: 'no re-enumeration when unchanged');
      },
    );

    test(
      'changed: full enumeration with a new stamp taken before it',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1', 's2']);
        final List<RemoteVideoInfo> first =
            await RemoteVideoListStore.fetchList(
              source: source,
              forceRefresh: false,
              current: null,
            );
        source.unchanged = false;
        final List<RemoteVideoInfo> second =
            await RemoteVideoListStore.fetchList(
              source: source,
              forceRefresh: false,
              current: first,
            );
        expect(identical(second, first), isFalse);
        expect(source.listCalls, 2);
        expect(source.events, <String>[
          'stamp',
          'list',
          'check:s1',
          'stamp',
          'list',
        ]);
      },
    );

    test(
      'manual refresh always enumerates, even when the server says unchanged',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1', 's2']);
        final List<RemoteVideoInfo> first =
            await RemoteVideoListStore.fetchList(
              source: source,
              forceRefresh: false,
              current: null,
            );
        source.unchanged = true;
        await RemoteVideoListStore.fetchList(
          source: source,
          forceRefresh: true,
          current: first,
        );
        expect(
          source.checkedStamps,
          isEmpty,
          reason: 'BUG-1891: manual = full',
        );
        expect(source.listCalls, 2);
      },
    );

    test(
      'a list that did not come with a stamp is always re-enumerated',
      () async {
        final _FakeSource source = _FakeSource()..unchanged = true;
        await RemoteVideoListStore.fetchList(
          source: source,
          forceRefresh: false,
          current: const <RemoteVideoInfo>[
            RemoteVideoInfo(id: 'x', title: 'X'),
          ],
        );
        expect(source.checkedStamps, isEmpty);
        expect(source.listCalls, 1);
      },
    );

    test(
      'a new app build keeps showing the list but drops its stamp',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1', 's2']);
        RemoteVideoListStore.debugSetBuildVersion('1.0.0-debug.1');
        await RemoteVideoListStore.fetchList(
          source: source,
          forceRefresh: false,
          current: null,
        );
        await RemoteVideoListStore.debugFlushWrites();

        RemoteVideoListStore.debugSetBuildVersion('1.0.0-debug.2');
        final List<RemoteVideoInfo>? loaded = await RemoteVideoListStore.load(
          source,
        );
        expect(loaded, isNotNull);
        source.unchanged = true;
        await RemoteVideoListStore.fetchList(
          source: source,
          forceRefresh: false,
          current: loaded,
        );
        expect(
          source.checkedStamps,
          isEmpty,
          reason: 'stamp bound to the build',
        );
        expect(source.listCalls, 2);
      },
    );

    test('the persisted stamp is used after a restart', () async {
      final _FakeSource source = _FakeSource(stamps: <String>['s1']);
      await RemoteVideoListStore.fetchList(
        source: source,
        forceRefresh: false,
        current: null,
      );
      await RemoteVideoListStore.debugFlushWrites();

      final List<RemoteVideoInfo>? loaded = await RemoteVideoListStore.load(
        source,
      );
      source.unchanged = true;
      final List<RemoteVideoInfo> again = await RemoteVideoListStore.fetchList(
        source: source,
        forceRefresh: false,
        current: loaded,
      );
      expect(identical(again, loaded), isTrue);
      expect(source.checkedStamps, <String>['s1']);
      expect(source.listCalls, 1);
    });
  });

  group('read (cold start, stale-while-revalidate)', () {
    test(
      'serves the persisted list before the network completes, then swaps',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1', 's2']);
        await persist(source, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'old', title: 'Old'),
        ], stamp: 's1');
        final Completer<bool> check = Completer<bool>();
        source.check = (_) => check.future;

        final RemoteLibraryRead<List<RemoteVideoInfo>> read =
            await PersistedRemoteVideoList.read(
              cache: cache,
              source: source,
              forceRefresh: false,
            );
        expect(read.stale!.single.id, 'old');
        expect(source.checkedStamps, <String>['s1'], reason: 'revalidating');
        expect(source.listCalls, 0);
        expect(
          cache.isFresh(
            source.remoteLibrarySourceId,
            RemoteLibraryCacheKeys.videos,
          ),
          isFalse,
          reason: 'the persisted list is marked stale',
        );

        source.nextList = const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'new', title: 'New'),
        ];
        check.complete(false);
        expect((await read.fresh).single.id, 'new');
        expect(
          cache.isFresh(
            source.remoteLibrarySourceId,
            RemoteLibraryCacheKeys.videos,
            ttl: kPersistedRemoteVideoListTtl,
          ),
          isTrue,
        );
      },
    );

    test(
      'unchanged server: fresh completes with the very same persisted object',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1'])
          ..unchanged = true;
        await persist(source, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'old', title: 'Old'),
        ], stamp: 's1');
        final RemoteLibraryRead<List<RemoteVideoInfo>> read =
            await PersistedRemoteVideoList.read(
              cache: cache,
              source: source,
              forceRefresh: false,
            );
        expect(identical(await read.fresh, read.stale), isTrue);
        expect(source.listCalls, 0);

        // Inside the TTL the next read is a plain memory hit (no stale, no check).
        final RemoteLibraryRead<List<RemoteVideoInfo>> next =
            await PersistedRemoteVideoList.read(
              cache: cache,
              source: source,
              forceRefresh: false,
            );
        expect(next.stale, isNull);
        expect(identical(await next.fresh, read.stale), isTrue);
        expect(source.checkedStamps, <String>['s1']);
      },
    );

    test(
      'manual refresh does not serve the stale list and enumerates',
      () async {
        final _FakeSource source = _FakeSource(stamps: <String>['s1', 's2'])
          ..unchanged = true;
        await persist(source, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'old', title: 'Old'),
        ], stamp: 's1');
        final RemoteLibraryRead<List<RemoteVideoInfo>> read =
            await PersistedRemoteVideoList.read(
              cache: cache,
              source: source,
              forceRefresh: true,
            );
        expect(read.stale, isNull);
        await read.fresh;
        expect(source.listCalls, 1);
        expect(source.checkedStamps, isEmpty);
      },
    );

    test(
      'auto-list off: peek shows the persisted list without any request',
      () async {
        final _FakeSource source = _FakeSource();
        await persist(source, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'old', title: 'Old'),
        ]);
        final List<RemoteVideoInfo>? peeked =
            await PersistedRemoteVideoList.peek(cache: cache, source: source);
        expect(peeked!.single.id, 'old');
        expect(source.events, isEmpty);
      },
    );

    test('a value already in memory wins over the disk copy', () async {
      final _FakeSource source = _FakeSource();
      await persist(source, const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'disk', title: 'Disk'),
      ]);
      cache.seed<List<RemoteVideoInfo>>(
        sourceId: source.remoteLibrarySourceId,
        key: RemoteLibraryCacheKeys.videos,
        value: const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'mem', title: 'Mem'),
        ],
      );
      expect(
        (await PersistedRemoteVideoList.peek(
          cache: cache,
          source: source,
        ))!.single.id,
        'mem',
      );
    });
  });
}

class _FakeSource implements PersistableRemoteVideoSource {
  _FakeSource({
    this.sourceId = 'jellyfin:http://jf-lan:8096|u1',
    this.scope = 'libraries=',
    this.credentials = const ServerUrlCredentials(
      baseUrl: 'http://jf-lan:8096',
      token: 'tok',
    ),
    List<String> stamps = const <String>[],
  }) : _stamps = List<String>.of(stamps);

  final String sourceId;
  String scope;
  ServerUrlCredentials credentials;
  final List<String> _stamps;
  bool unchanged = false;
  Future<bool> Function(String stamp)? check;
  List<RemoteVideoInfo>? nextList;
  int listCalls = 0;
  final List<String> checkedStamps = <String>[];
  final List<String> events = <String>[];

  @override
  String get remoteLibrarySourceId => sourceId;

  @override
  String get remoteVideoListScope => scope;

  @override
  ServerUrlCredentials get remoteVideoUrlCredentials => credentials;

  @override
  Future<String?> takeRemoteLibraryStamp() async {
    events.add('stamp');
    return _stamps.isEmpty ? null : _stamps.removeAt(0);
  }

  @override
  Future<bool> remoteLibraryUnchangedSince(String stamp) {
    events.add('check:$stamp');
    checkedStamps.add(stamp);
    return check?.call(stamp) ?? Future<bool>.value(unchanged);
  }

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    events.add('list');
    listCalls++;
    return nextList ??
        <RemoteVideoInfo>[RemoteVideoInfo(id: 'v$listCalls', title: 'V')];
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) => throw UnimplementedError();
}
