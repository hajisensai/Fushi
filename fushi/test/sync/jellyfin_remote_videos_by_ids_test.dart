// RemoteVideoLookup on Jellyfin / Emby: look up remote videos by id without
// enumerating the library (the "Same work" card poster, and later opening a
// collection). Pins the request shape at the protocol layer (MockClient):
// `Ids` comma list, chunked, no IncludeItemTypes; only playable leaves come
// back, in the requested order, mapped like the library list.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<Uri> seen;

  /// Server: every requested id exists as an episode of series `s1` with a
  /// series poster, except `missing` (gone from the server) and `series-x`
  /// (a Series container, not a playable leaf).
  JellyfinVideoClient client() => JellyfinVideoClient(
    api: JellyfinApi(
      serverUrl: 'http://jf:8096',
      accessToken: 'tok',
      client: MockClient((http.Request req) async {
        seen.add(req.url);
        final List<String> ids =
            req.url.queryParameters['Ids']?.split(',') ?? const <String>[];
        final List<Map<String, Object?>> items = <Map<String, Object?>>[
          // Server order differs from the request order on purpose.
          for (final String id in ids.reversed)
            if (id == 'series-x')
              <String, Object?>{'Id': id, 'Name': 'Show', 'Type': 'Series'}
            else if (id != 'missing')
              <String, Object?>{
                'Id': id,
                'Name': 'Episode $id',
                'Type': 'Episode',
                'SeriesId': 's1',
                'SeriesName': 'Show',
                'SeriesPrimaryImageTag': 'tag',
                'ImageTags': <String, Object?>{'Primary': 'ep'},
              },
        ];
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': items,
            'TotalRecordCount': items.length,
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    ),
    userId: 'u',
  );

  setUp(() => seen = <Uri>[]);

  test('is a RemoteVideoLookup', () {
    expect(client(), isA<RemoteVideoLookup>());
  });

  test(
    'one Ids request; playable leaves only, request order, missing skipped',
    () async {
      final List<RemoteVideoInfo> found = await client().remoteVideosByIds(
        <String>['e2', 'missing', 'series-x', 'e1', 'e2', ''],
      );

      expect(seen, hasLength(1));
      final Map<String, String> q = seen.single.queryParameters;
      expect(seen.single.path, '/Users/u/Items');
      expect(q['Ids'], 'e2,missing,series-x,e1', reason: 'deduped, no blanks');
      expect(q['Limit'], '4');
      expect(q['Recursive'], 'true');
      expect(
        q.containsKey('IncludeItemTypes'),
        isFalse,
        reason: 'filtering by Ids, not by type (BUG-2254)',
      );
      expect(
        q.containsKey('ParentId'),
        isFalse,
        reason: 'look up across every library the user can see',
      );

      expect(found.map((RemoteVideoInfo v) => v.id), <String>['e2', 'e1']);
      // Same mapping as the library list: the series poster is there.
      expect(found.first.seriesCoverUrl, contains('/Items/s1/Images/Primary'));
      expect(found.first.coverUrl, contains('/Items/e2/Images/Primary'));
    },
  );

  test('chunks long id lists into requests of 100', () async {
    final List<String> ids = <String>[for (int i = 0; i < 250; i++) 'e$i'];
    final List<RemoteVideoInfo> found = await client().remoteVideosByIds(ids);

    expect(
      seen.map((Uri u) => u.queryParameters['Ids']!.split(',').length),
      <int>[100, 100, 50],
    );
    expect(found.map((RemoteVideoInfo v) => v.id), ids);
  });

  test('no ids: no request', () async {
    expect(await client().remoteVideosByIds(const <String>[]), isEmpty);
    expect(seen, isEmpty);
  });
}
