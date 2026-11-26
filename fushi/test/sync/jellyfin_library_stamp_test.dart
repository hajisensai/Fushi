// Jellyfin / Emby library change stamp: decide whether the remote video list
// changed since the cached copy with a handful of `Limit=1` queries instead of
// re-enumerating every library (the slow part of opening the Video page).
//
// A small simulated server (MockClient) answers the stamp queries and the full
// enumeration from one mutable state, and every request is recorded, so the
// tests pin both the protocol shape and "unchanged = zero enumeration pages".

import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/persisted_remote_video_list.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/remote_video_list_store.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Server state. `savedAt` is each item's DateLastSaved (server clock).
class _Server {
  _Server();

  DateTime now = DateTime.utc(2026, 11, 25, 12);
  bool sendDate = true;
  bool honoursMinDateLastSaved = true;
  bool ignoresRecursive = false;

  /// A strict server / proxy that answers 400 to the stamp-only parameters.
  bool rejectsStampParameters = false;
  List<String> views = <String>['lib1'];

  final Map<String, _Item> items = <String, _Item>{
    'm1': _Item('Movie', DateTime.utc(2026, 1, 1)),
    'e1': _Item('Episode', DateTime.utc(2026, 1, 1)),
    'e2': _Item('Episode', DateTime.utc(2026, 1, 1)),
  };
  final List<Uri> requests = <Uri>[];

  /// Full-enumeration page requests (the expensive part).
  int get enumerationPages =>
      requests.where((Uri u) => u.queryParameters['Limit'] == '500').length;

  Iterable<Uri> get stampQueries =>
      requests.where((Uri u) => u.queryParameters['Limit'] == '1');

  Map<String, Object?> _json(String id, _Item item) => <String, Object?>{
    'Id': id,
    'Name': id,
    'Type': item.type,
    'UserData': <String, Object?>{
      'Played': item.played,
      'PlaybackPositionTicks': item.positionMs * 10000,
      if (item.lastPlayed != null)
        'LastPlayedDate': item.lastPlayed!.toIso8601String(),
    },
  };

  http.Response handle(http.Request req) {
    requests.add(req.url);
    final Map<String, String> q = req.url.queryParameters;
    if (rejectsStampParameters &&
        (q.containsKey('MinDateLastSaved') || q.containsKey('Filters'))) {
      return http.Response('bad request', 400);
    }
    Map<String, Object?> body;
    if (req.url.path.endsWith('/Views')) {
      body = <String, Object?>{
        'Items': <Object?>[
          for (final String v in views)
            <String, Object?>{'Id': v, 'Name': v, 'CollectionType': 'mixed'},
        ],
      };
    } else if (ignoresRecursive) {
      body = <String, Object?>{
        'Items': <Object?>[
          <String, Object?>{
            'Id': 'series',
            'Name': 'S',
            'Type': 'Series',
            'IsFolder': true,
          },
        ],
        'TotalRecordCount': 1,
      };
    } else {
      Iterable<MapEntry<String, _Item>> hits = items.entries;
      final String? type = q['IncludeItemTypes'];
      if (type != null) {
        hits = hits.where((MapEntry<String, _Item> e) => e.value.type == type);
      }
      if (q['Filters'] == 'IsPlayed') {
        hits = hits.where((MapEntry<String, _Item> e) => e.value.played);
      }
      final String? minSaved = q['MinDateLastSaved'];
      if (minSaved != null && honoursMinDateLastSaved) {
        final DateTime min = DateTime.parse(minSaved);
        hits = hits.where(
          (MapEntry<String, _Item> e) => !e.value.savedAt.isBefore(min),
        );
      }
      final List<MapEntry<String, _Item>> list = hits.toList();
      if (q['SortBy'] == 'DatePlayed') {
        list.sort((MapEntry<String, _Item> a, MapEntry<String, _Item> b) {
          final DateTime? x = a.value.lastPlayed;
          final DateTime? y = b.value.lastPlayed;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return y.compareTo(x);
        });
      }
      final int start = int.parse(q['StartIndex'] ?? '0');
      final int limit = int.parse(q['Limit'] ?? '100');
      body = <String, Object?>{
        'Items': <Object?>[
          for (final MapEntry<String, _Item> e in list.skip(start).take(limit))
            _json(e.key, e.value),
        ],
        'TotalRecordCount': list.length,
      };
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: <String, String>{
        'content-type': 'application/json',
        if (sendDate) 'date': HttpDate.format(now),
      },
    );
  }

  /// Something saved on the server "now" (add / metadata edit).
  void save(String id, _Item item) {
    items[id] = item..savedAt = now;
  }
}

class _Item {
  _Item(this.type, this.savedAt);

  final String type;
  DateTime savedAt;
  bool played = false;
  int positionMs = 0;
  DateTime? lastPlayed;
}

void main() {
  late _Server server;

  JellyfinVideoClient client({List<String> libraryIds = const <String>[]}) =>
      JellyfinVideoClient(
        api: JellyfinApi(
          serverUrl: 'http://jf:8096',
          accessToken: 'tok',
          client: MockClient((http.Request req) async => server.handle(req)),
        ),
        userId: 'u',
        libraryIds: libraryIds,
      );

  setUp(() {
    server = _Server();
    RemoteVideoListStore.debugReset();
    // Only the revalidation rule is under test here; persistence has its own file.
    RemoteVideoListStore.debugSetDirResolver(() async => null);
  });
  tearDown(() => RemoteVideoListStore.debugSetDirResolver(null));

  test('is persistable, scope = sorted library selection, no credentials', () {
    final JellyfinVideoClient c = client(libraryIds: <String>['b', 'a']);
    expect(c, isA<PersistableRemoteVideoSource>());
    expect(c.remoteVideoListScope, 'libraries=a,b');
    expect(c.remoteVideoListScope, isNot(contains('tok')));
    expect(remoteVideoListTtlOf(c), kPersistedRemoteVideoListTtl);
  });

  test(
    'stamp query shape: Limit=1 probes per library, anchor = Date - skew budget',
    () async {
      final String? stamp = await client().takeRemoteLibraryStamp();
      expect(stamp, isNotNull);

      final List<Map<String, String>> probes = <Map<String, String>>[
        for (final Uri u in server.stampQueries) u.queryParameters,
      ];
      expect(probes, hasLength(5));
      expect(
        probes.every((Map<String, String> q) => q['ParentId'] == 'lib1'),
        isTrue,
      );
      expect(
        probes.every((Map<String, String> q) => q['Recursive'] == 'true'),
        isTrue,
      );
      expect(
        probes
            .map((Map<String, String> q) => q['IncludeItemTypes'])
            .whereType<String>(),
        unorderedEquals(<String>['Movie', 'Episode']),
        reason: 'single-valued types (BUG-2254)',
      );
      expect(
        probes.where((Map<String, String> q) => q['Filters'] == 'IsPlayed'),
        hasLength(1),
      );
      expect(
        probes.where(
          (Map<String, String> q) =>
              q['SortBy'] == 'DatePlayed' && q['SortOrder'] == 'Descending',
        ),
        hasLength(1),
      );
      final Map<String, String> saved = probes.singleWhere(
        (Map<String, String> q) => q.containsKey('MinDateLastSaved'),
      );
      expect(
        DateTime.parse(saved['MinDateLastSaved']!),
        server.now.subtract(JellyfinVideoClient.kStampClockSkewBudget),
      );
      expect(server.enumerationPages, 0);
    },
  );

  test(
    'unchanged server: the check answers true with stamp queries only',
    () async {
      final JellyfinVideoClient c = client();
      final String stamp = (await c.takeRemoteLibraryStamp())!;
      server.now = server.now.add(const Duration(hours: 3));
      server.requests.clear();

      expect(await c.remoteLibraryUnchangedSince(stamp), isTrue);
      expect(server.enumerationPages, 0);
      expect(server.stampQueries, hasLength(5));
    },
  );

  group('changes are detected', () {
    late JellyfinVideoClient c;
    late String stamp;

    setUp(() async {
      c = client();
      stamp = (await c.takeRemoteLibraryStamp())!;
      server.now = server.now.add(const Duration(hours: 1));
    });

    test('add', () async {
      server.save('e3', _Item('Episode', server.now));
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test(
      'add with an old DateCreated-like save time is still caught by count',
      () async {
        server.items['e3'] = _Item('Episode', DateTime.utc(2020));
        expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
      },
    );

    test('delete', () async {
      server.items.remove('e2');
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test('delete + add in the same window', () async {
      server.items.remove('e2');
      server.save('e3', _Item('Episode', server.now));
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test('metadata edit (rename / rescrape) of an existing item', () async {
      server.items['e1']!.savedAt = server.now;
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test('marked played on another device', () async {
      server.items['m1']!
        ..played = true
        ..lastPlayed = server.now;
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test('playback progress on another device', () async {
      server.items['e1']!
        ..positionMs = 60000
        ..lastPlayed = server.now;
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test('a video library added to the server', () async {
      server.views = <String>['lib1', 'lib2'];
      expect(await c.remoteLibraryUnchangedSince(stamp), isFalse);
    });

    test('garbage stamp', () async {
      expect(await c.remoteLibraryUnchangedSince('not json'), isFalse);
      expect(await c.remoteLibraryUnchangedSince('{"anchor":"x"}'), isFalse);
    });
  });

  group('no trustworthy stamp -> null (always enumerate)', () {
    test('no Date header', () async {
      server.sendDate = false;
      expect(await client().takeRemoteLibraryStamp(), isNull);
    });

    test('server ignores MinDateLastSaved', () async {
      server.honoursMinDateLastSaved = false;
      expect(await client().takeRemoteLibraryStamp(), isNull);
    });

    test('server ignores Recursive (BUG-2567)', () async {
      server.ignoresRecursive = true;
      expect(await client().takeRemoteLibraryStamp(), isNull);
    });

    test('server rejects the stamp parameters (HTTP 400)', () async {
      server.rejectsStampParameters = true;
      final JellyfinVideoClient c = client();
      expect(await c.takeRemoteLibraryStamp(), isNull);
      expect(
        await c.remoteLibraryUnchangedSince(
          '{"anchor":0,"signature":"lib1:1:2:0:-"}',
        ),
        isFalse,
      );
      // The stamp is only a shortcut: the full list still loads.
      final List<RemoteVideoInfo> list = await RemoteVideoListStore.fetchList(
        source: c,
        forceRefresh: false,
        current: null,
      );
      expect(list, hasLength(3));
    });

    test(
      'library saved within the skew budget right before the stamp',
      () async {
        server.items['e1']!.savedAt = server.now.subtract(
          const Duration(minutes: 2),
        );
        expect(await client().takeRemoteLibraryStamp(), isNull);
      },
    );
  });

  group('with the store (end to end over the wire)', () {
    test(
      'unchanged server skips enumeration; changed / manual refresh enumerate',
      () async {
        final JellyfinVideoClient c = client();
        final List<RemoteVideoInfo> first =
            await RemoteVideoListStore.fetchList(
              source: c,
              forceRefresh: false,
              current: null,
            );
        expect(
          first.map((RemoteVideoInfo v) => v.id),
          unorderedEquals(<String>['m1', 'e1', 'e2']),
        );
        final int pagesAfterFirst = server.enumerationPages;
        expect(pagesAfterFirst, greaterThan(0));

        server.now = server.now.add(const Duration(hours: 1));
        final List<RemoteVideoInfo> second =
            await RemoteVideoListStore.fetchList(
              source: c,
              forceRefresh: false,
              current: first,
            );
        expect(identical(second, first), isTrue);
        expect(
          server.enumerationPages,
          pagesAfterFirst,
          reason: 'no re-enumeration',
        );

        server.save('e3', _Item('Episode', server.now));
        server.now = server.now.add(const Duration(hours: 1));
        final List<RemoteVideoInfo> third =
            await RemoteVideoListStore.fetchList(
              source: c,
              forceRefresh: false,
              current: second,
            );
        expect(third.map((RemoteVideoInfo v) => v.id), contains('e3'));
        final int pagesAfterChange = server.enumerationPages;
        expect(pagesAfterChange, greaterThan(pagesAfterFirst));

        server.now = server.now.add(const Duration(hours: 1));
        await RemoteVideoListStore.fetchList(
          source: c,
          forceRefresh: true,
          current: third,
        );
        expect(
          server.enumerationPages,
          greaterThan(pagesAfterChange),
          reason: 'manual refresh is always a full fetch (BUG-1891)',
        );
      },
    );
  });

  test('urlCredentials: image URLs strip to token-free paths and back', () {
    final JellyfinApi api = JellyfinApi(
      serverUrl: 'http://jf:8096',
      accessToken: 'tok',
    );
    final String url = api.imageUrl('item1', maxWidth: 400);
    final String? path = api.urlCredentials.strip(url);
    expect(path, '/Items/item1/Images/Primary?maxWidth=400&quality=90');
    expect(api.urlCredentials.authorize(path!), url);
    expect(
      api.subtitleDeliveryUrl('/Videos/1/Subtitles/2/Stream.srt'),
      'http://jf:8096/Videos/1/Subtitles/2/Stream.srt?api_key=tok',
    );
  });
}
