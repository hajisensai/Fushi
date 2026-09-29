import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('paired HTTP game-stream transport', () {
    const FushiClientUrl primary = FushiClientUrl(
      url: 'http://primary:8765',
      token: 'test-primary-token',
    );
    const FushiClientUrl secondary = FushiClientUrl(
      url: 'http://secondary:8765',
      token: 'test-secondary-token',
    );
    late FushiDatabase db;
    late SyncRepository repository;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repository = SyncRepository(db);
      await repository.setFushiClientUrls(<FushiClientUrl>[primary, secondary]);
    });
    tearDown(() => db.close());

    for (final ({int status, String body, String code}) failure
        in <({int status, String body, String code})>[
          (
            status: 409,
            body: jsonEncode(<String, Object?>{
              'version': 1,
              'code': 'session_conflict',
              'error': 'The session is no longer active',
            }),
            code: 'session_conflict',
          ),
          (
            status: 500,
            body: '<html>Server failed</html>',
            code: 'http_rejected',
          ),
          (status: 200, body: 'not JSON', code: 'invalid_response'),
        ]) {
      test('HTTP ${failure.status} preserves ${failure.code}', () async {
        final MockClient httpClient = MockClient(
          (http.Request request) async =>
              http.Response(failure.body, failure.status),
        );
        addTearDown(httpClient.close);
        final InterconnectGameStreamTransport transport =
            InterconnectGameStreamTransport(
              repo: repository,
              httpClient: httpClient,
            )..bindPeer(primary);

        await expectLater(
          _postStream(transport),
          throwsA(
            isA<GameStreamRequestError>()
                .having(
                  (GameStreamRequestError error) => error.statusCode,
                  'statusCode',
                  failure.status,
                )
                .having(
                  (GameStreamRequestError error) => error.code,
                  'code',
                  failure.code,
                ),
          ),
        );
      });
    }

    test('HTTP 401 retains SyncAuthError', () async {
      final MockClient httpClient = MockClient(
        (http.Request request) async => http.Response('rejected', 401),
      );
      addTearDown(httpClient.close);
      final InterconnectGameStreamTransport transport =
          InterconnectGameStreamTransport(
            repo: repository,
            httpClient: httpClient,
          )..bindPeer(primary);

      await expectLater(_postStream(transport), throwsA(isA<SyncAuthError>()));
    });

    test('a bound host rejection never falls back to another peer', () async {
      final List<String> hosts = <String>[];
      final MockClient httpClient = MockClient((http.Request request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'primary') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'version': 1,
              'code': 'session_conflict',
              'error': 'stopped',
            }),
            409,
          );
        }
        return http.Response('{"version":1,"sessions":[]}', 200);
      });
      addTearDown(httpClient.close);
      final InterconnectGameStreamTransport transport =
          InterconnectGameStreamTransport(
            repo: repository,
            httpClient: httpClient,
          )..bindPeer(primary);

      await expectLater(
        _postStream(transport),
        throwsA(isA<GameStreamRequestError>()),
      );
      expect(hosts, <String>['primary']);
      expect(transport.boundPeer?.url, primary.url);
    });

    test('unbound discovery can recover from 409 at the next peer', () async {
      final List<String> hosts = <String>[];
      final MockClient httpClient = MockClient((http.Request request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'primary') {
          return http.Response(
            '{"version":1,"code":"session_conflict","error":"stopped"}',
            409,
          );
        }
        return http.Response('{"version":1,"sessions":[]}', 200);
      });
      addTearDown(httpClient.close);
      final InterconnectGameStreamTransport transport =
          InterconnectGameStreamTransport(
            repo: repository,
            httpClient: httpClient,
          );

      final GameStreamPostResult response = await _postStream(transport);
      expect(hosts, <String>['primary', 'secondary']);
      expect(response.json, <String, Object?>{
        'version': 1,
        'sessions': <Object?>[],
      });
      expect(response.peer?.url, secondary.url);
    });

    test('network failure still differs from a host HTTP rejection', () async {
      final MockClient httpClient = MockClient((http.Request request) async {
        throw http.ClientException('unreachable', request.url);
      });
      addTearDown(httpClient.close);
      final InterconnectGameStreamTransport transport =
          InterconnectGameStreamTransport(
            repo: repository,
            httpClient: httpClient,
          )..bindPeer(primary);

      await expectLater(
        _postStream(transport),
        throwsA(isA<GameStreamUnreachableError>()),
      );
    });
  });

  test(
    'suffix lookup shows the host matched word and mines its source line',
    () async {
      final _DeferredLookup lookup = _DeferredLookup();
      final _FakeTransport transport = _FakeTransport();
      final GameStreamLookupController controller = GameStreamLookupController(
        lookupClient: lookup,
        streamClient: FushiGameStreamClient(transport: transport),
        clientId: 'android-a',
      );
      addTearDown(controller.dispose);
      controller.applyTextEvent(
        GameStreamTextEvent(
          sessionId: 's1',
          lineId: 'line-with-suffix',
          text: '😀 日本語と日本語',
          timestampMs: 1000,
        ),
      );
      final Future<void> pending = controller.lookup(
        '日本語と日本語',
        displayTerm: '日',
      );
      expect(lookup.terms, <String>['日本語と日本語']);
      expect(controller.selectedTerm, '日');
      final DictionarySearchResult matched = DictionarySearchResult(
        searchTerm: '日本語と日本語',
        bestLength: 3,
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'Host dictionary',
            word: '日本語',
            reading: 'にほんご',
            meaning: 'Japanese language',
          ),
        ],
      );
      lookup.pending.complete(matched);
      await pending;
      expect(controller.result, same(matched));
      expect(controller.selectedTerm, '日本語');
      await controller.mine(<String, String>{'expression': '日本語'});
      expect(transport.calls.single.path, '/api/game-stream/mine');
      expect(transport.calls.single.body['lineId'], 'line-with-suffix');
      expect(transport.calls.single.body['sentence'], '😀 日本語と日本語');
    },
  );

  test('lookup completion cannot attach an old result to a new line', () async {
    final _DeferredLookup lookup = _DeferredLookup();
    final _FakeTransport transport = _FakeTransport();
    final GameStreamLookupController controller = GameStreamLookupController(
      lookupClient: lookup,
      streamClient: FushiGameStreamClient(transport: transport),
      clientId: 'android-a',
    );
    addTearDown(controller.dispose);
    controller.applyTextEvent(
      GameStreamTextEvent(
        sessionId: 's1',
        lineId: 'line1',
        text: '古い文章',
        timestampMs: 1000,
      ),
    );
    final Future<void> pending = controller.lookup('文章');
    controller.applyTextEvent(
      GameStreamTextEvent(
        sessionId: 's1',
        lineId: 'line2',
        text: '新しい文章',
        timestampMs: 2000,
      ),
    );
    lookup.pending.complete(
      DictionarySearchResult(
        searchTerm: '文章',
        bestLength: 2,
        scrollPosition: 0,
        entries: <DictionaryEntry>[],
      ),
    );
    await pending;
    expect(controller.result, isNull);
    expect(controller.selectedTerm, isNull);
    expect(controller.searching, isFalse);
    expect(
      () => controller.mine(<String, String>{'term': '文章'}),
      throwsStateError,
    );
    expect(transport.calls, isEmpty);
  });

  test('late input acknowledgement after dispose is harmless', () async {
    final Completer<GameStreamInputAck?> pending =
        Completer<GameStreamInputAck?>();
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (_) => pending.future,
    );
    final Future<GameStreamInputAck?> sending = composer.key(
      key: 'Enter',
      action: GameStreamInputAction.down,
    );
    composer.dispose();
    pending.complete(const GameStreamInputAck(sequence: 1, accepted: true));
    expect((await sending)?.accepted, isTrue);
  });
  test(
    'client posts game-stream endpoints and decodes session responses',
    () async {
      final _FakeTransport transport = _FakeTransport();
      final FushiGameStreamClient client = FushiGameStreamClient(
        transport: transport,
      );

      final GameStreamSession session = GameStreamSession.create(
        sessionId: 's1',
        now: DateTime.utc(2026),
        windowId: 'hwnd:1',
      );
      transport.responses['/api/game-stream/sessions'] = <String, dynamic>{
        'sessions': <Map<String, Object?>>[session.toJson()],
      };
      transport.responses['/api/game-stream/join'] = <String, dynamic>{
        'session': session.toJson(),
      };

      expect(await client.listSessions(clientId: 'android-a'), hasLength(1));
      final GameStreamSession? joined = await client.join(
        sessionId: 's1',
        clientId: 'android-a',
        clientName: 'tablet',
      );

      expect(joined?.sessionId, 's1');
      expect(transport.calls.map((c) => c.path), <String>[
        '/api/game-stream/sessions',
        '/api/game-stream/join',
      ]);
      expect(transport.calls.last.body['clientName'], 'tablet');
    },
  );

  test('pointer mapper clamps to normalized video coordinates', () {
    const GameStreamPointerMapper mapper = GameStreamPointerMapper(
      Size(200, 100),
    );

    expect(mapper.normalize(const Offset(50, 75)), const Offset(0.25, 0.75));
    expect(mapper.normalize(const Offset(-10, 200)), const Offset(0, 1));
  });

  test('input composer assigns sequences and ignores stale ack', () async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      now: () => DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return GameStreamInputAck(sequence: event.sequence, accepted: true);
      },
    );

    await composer.pointer(
      action: GameStreamInputAction.down,
      normalized: const Offset(1.2, -0.2),
    );
    await composer.gamepad(
      button: GameStreamVirtualButton.confirm,
      action: GameStreamInputAction.up,
    );
    composer.applyAck(
      const GameStreamInputAck(
        sequence: 1,
        accepted: false,
        reason: 'duplicate',
      ),
    );

    expect(sent.map((e) => e.sequence), <int>[1, 2]);
    expect(sent.first.x, 1);
    expect(sent.first.y, 0);
    expect(sent.last.button, 'confirm');
    expect(composer.lastAcceptedSequence, 2);
    expect(composer.lastRejectedSequence, 0);
  });
}

Future<GameStreamPostResult> _postStream(
  InterconnectGameStreamTransport transport,
) => transport.post(
  path: '/api/game-stream/sessions',
  body: const <String, dynamic>{'clientId': 'test-android'},
  timeout: const Duration(seconds: 3),
);

class _DeferredLookup implements GameStreamDictionaryLookup {
  final List<String> terms = <String>[];
  final Completer<DictionarySearchResult?> pending =
      Completer<DictionarySearchResult?>();

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) {
    terms.add(term);
    return pending.future;
  }
}

class _FakeTransport implements GameStreamTransport {
  final Map<String, Map<String, dynamic>?> responses =
      <String, Map<String, dynamic>?>{};
  final List<({String path, Map<String, dynamic> body})> calls =
      <({String path, Map<String, dynamic> body})>[];

  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    calls.add((path: path, body: body));
    return GameStreamPostResult(json: responses[path]);
  }
}
