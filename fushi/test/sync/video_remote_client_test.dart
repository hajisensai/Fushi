import 'dart:convert';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late FushiDatabase database;
  late SyncRepository repository;
  const FushiClientUrl selected = FushiClientUrl(
    url: 'http://selected:8765',
    token: 'secret',
    hostId: 'selected',
  );
  setUp(() async {
    database = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    repository = SyncRepository(database);
    await repository.setFushiClientUrls(const <FushiClientUrl>[
      selected,
      FushiClientUrl(url: 'http://other:8765', token: 'other', hostId: 'other'),
    ]);
  });
  tearDown(() async {
    await database.close();
  });
  test(
    'remote rejection preserves host error and never reaches other device',
    () async {
      final List<String> reached = <String>[];
      final VideoRemoteClient client = VideoRemoteClient(
        repository: repository,
        peer: selected,
        httpClient: MockClient((http.Request request) async {
          reached.add(request.url.host);
          return http.Response(
            jsonEncode(<String, dynamic>{'error': 'stale_session'}),
            409,
          );
        }),
      );
      await expectLater(
        client.snapshot(),
        throwsA(
          isA<VideoRemoteError>()
              .having(
                (VideoRemoteError e) => e.message,
                'message',
                'stale_session',
              )
              .having((VideoRemoteError e) => e.statusCode, 'status', 409),
        ),
      );
      expect(reached, <String>['selected']);
      client.cancelPending();
    },
  );
  test(
    'poll sends revision and bounded wait with paired credentials',
    () async {
      final VideoRemoteClient client = VideoRemoteClient(
        repository: repository,
        peer: selected,
        httpClient: MockClient((http.Request request) async {
          expect(request.url.path, '/api/video-remote/events');
          expect(jsonDecode(request.body), <String, dynamic>{
            'afterRevision': 42,
            'waitMs': 25000,
          });
          expect(
            request.headers['Authorization'],
            'Basic ${base64Encode(utf8.encode('hibiki:secret'))}',
          );
          return http.Response('{"revision":43,"events":[]}', 200);
        }),
      );
      expect((await client.events(42))['revision'], 43);
      client.cancelPending();
    },
  );
  group('certificate pin', () {
    const FushiClientUrl pinnedPeer = FushiClientUrl(
      url: 'https://paired:8766',
      fingerprintSha256: 'AA:BB',
      token: 'secret',
      hostId: 'pinned-host',
    );
    Future<void> storeOnly(FushiClientUrl candidate) =>
        repository.setFushiClientUrls(<FushiClientUrl>[candidate]);

    test(
      'same host address with another pin is refused before sending',
      () async {
        await storeOnly(
          const FushiClientUrl(
            url: 'https://learned:8766',
            fingerprintSha256: 'cc:dd',
            token: 'secret',
            hostId: 'pinned-host',
            learned: true,
          ),
        );
        final List<String> pins = <String>[];
        final List<Uri> reached = <Uri>[];
        final VideoRemoteClient client = VideoRemoteClient(
          repository: repository,
          peer: pinnedPeer,
          httpClient: MockClient((http.Request request) async {
            reached.add(request.url);
            return http.Response('{}', 200);
          }),
          pinnedClientFactory: (String pin) {
            pins.add(pin);
            return MockClient((http.Request request) async {
              reached.add(request.url);
              return http.Response('{}', 200);
            });
          },
        );
        await expectLater(
          client.snapshot(),
          throwsA(
            isA<VideoRemoteError>().having(
              (VideoRemoteError e) => e.message,
              'message',
              VideoRemoteError.certificateMismatchCode,
            ),
          ),
        );
        expect(pins, isEmpty);
        expect(reached, isEmpty);
        expect(await client.supportsVideoRemote(), isNull);
        expect(reached, isEmpty);
        client.cancelPending();
      },
    );

    test('plaintext address of a pinned host is refused', () async {
      await storeOnly(
        const FushiClientUrl(
          url: 'http://downgrade:8765',
          token: 'secret',
          hostId: 'pinned-host',
        ),
      );
      final List<Uri> reached = <Uri>[];
      final VideoRemoteClient client = VideoRemoteClient(
        repository: repository,
        peer: pinnedPeer,
        httpClient: MockClient((http.Request request) async {
          reached.add(request.url);
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.snapshot(),
        throwsA(
          isA<VideoRemoteError>().having(
            (VideoRemoteError e) => e.message,
            'message',
            VideoRemoteError.certificateMismatchCode,
          ),
        ),
      );
      expect(reached, isEmpty);
      client.cancelPending();
    });

    test('address with the paired pin (any notation) is used', () async {
      await storeOnly(
        const FushiClientUrl(
          url: 'https://lan:8766',
          fingerprintSha256: 'aabb',
          token: 'secret',
          hostId: 'pinned-host',
          learned: true,
        ),
      );
      final List<String> pins = <String>[];
      final VideoRemoteClient client = VideoRemoteClient(
        repository: repository,
        peer: pinnedPeer,
        pinnedClientFactory: (String pin) {
          pins.add(pin);
          return MockClient((http.Request request) async {
            if (request.url.path == '/api/capabilities') {
              return http.Response('{"videoRemoteControlV1":true}', 200);
            }
            return http.Response('{"revision":7}', 200);
          });
        },
      );
      expect((await client.snapshot())['revision'], 7);
      expect(await client.supportsVideoRemote(), isTrue);
      expect(pins, everyElement('aabb'));
      client.cancelPending();
    });
  });

  test('capability probe reports a host without the remote as false', () async {
    final VideoRemoteClient client = VideoRemoteClient(
      repository: repository,
      peer: selected,
      httpClient: MockClient((http.Request request) async {
        expect(request.url.host, 'selected');
        expect(request.method, 'GET');
        return http.Response('{"liveLibrary":{}}', 200);
      }),
    );
    expect(await client.supportsVideoRemote(), isFalse);
    client.cancelPending();
  });

  test('subtitle chunks are cached per session and subtitle version', () async {
    final List<int> offsets = <int>[];
    int? failAt;
    final VideoRemoteClient client = VideoRemoteClient(
      repository: repository,
      peer: selected,
      httpClient: MockClient((http.Request request) async {
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        final int offset = body['offset'] as int;
        if (offset == failAt) {
          failAt = null;
          return http.Response('{"error":"requests_busy"}', 429);
        }
        offsets.add(offset);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'total': 5,
            'cues': <Map<String, dynamic>>[
              for (int i = offset; i < offset + 2 && i < 5; i++)
                <String, dynamic>{'id': 'v${body['subtitleVersion']}-$i'},
            ],
          }),
          200,
        );
      }),
    );
    Future<List<Map<String, dynamic>>?> load(int version) => client.subtitles(
      sessionId: 's',
      subtitleVersion: version,
      expectedTotal: 5,
      active: () => true,
      chunkSize: 2,
    );
    expect(await load(1), hasLength(5));
    expect(offsets, <int>[0, 2, 4]);
    expect((await load(1))!.map((Map<String, dynamic> c) => c['id']), <String>[
      'v1-0',
      'v1-1',
      'v1-2',
      'v1-3',
      'v1-4',
    ]);
    expect(offsets, <int>[
      0,
      2,
      4,
    ], reason: 'same version is served from cache');
    await load(2);
    expect(offsets, <int>[0, 2, 4, 0, 2, 4]);
    // A load interrupted mid-way resumes from the first missing chunk.
    offsets.clear();
    failAt = 2;
    await expectLater(load(3), throwsA(isA<VideoRemoteError>()));
    expect(await load(3), hasLength(5));
    expect(offsets, <int>[0, 2, 4]);
    client.cancelPending();
  });
}
