import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki_anki/src/ankiconnect/ankiconnect_service.dart';

// HBK-AUDIT-051: the AnkiConnect network IPC layer was untested — only model
// JSON round-trips were covered. These tests exercise the real request shaping
// (endpoint, JSON body, action/version=6 protocol envelope), response parsing,
// and error mapping. The service issues requests through package:http's
// top-level functions, so we intercept them with `runWithClient` + a
// `MockClient` (no real socket is opened) and record each request for assertion.

void main() {
  /// Runs [body] against an [AnkiConnectService] whose HTTP calls are served by
  /// a MockClient returning [status] + a JSON envelope `{result, error}` (or
  /// [rawBody] verbatim). Every issued request is appended to [sink].
  Future<T> withMock<T>(
    Future<T> Function(AnkiConnectService service) body, {
    required List<http.Request> sink,
    int status = 200,
    Object? result,
    Object? error,
    String? rawBody,
  }) {
    final String responseBody = rawBody ??
        jsonEncode(<String, Object?>{'result': result, 'error': error});
    final client = MockClient((http.Request request) async {
      sink.add(request);
      return http.Response(
        responseBody,
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    return body(
        AnkiConnectService(host: '127.0.0.1', port: 8765, client: client));
  }

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;

  group('local media path capability', () {
    test('recognizes localhost and IPv4/IPv6 loopback', () {
      expect(ankiConnectHostIsLoopback('localhost'), isTrue);
      expect(ankiConnectHostIsLoopback('127.0.0.1'), isTrue);
      expect(ankiConnectHostIsLoopback('::1'), isTrue);
      expect(ankiConnectHostIsLoopback('[::1]'), isTrue);
    });

    test('does not expose local paths to a remote AnkiConnect host', () {
      expect(ankiConnectHostIsLoopback('192.0.2.10'), isFalse);
      expect(ankiConnectHostIsLoopback('anki.example.com'), isFalse);
    });
  });

  group('request envelope', () {
    test('posts to the configured host/port over http', () async {
      final issued = <http.Request>[];
      await withMock((s) => s.getDeckNames(),
          sink: issued, result: const <String>[]);

      expect(issued.single.method, 'POST');
      final Uri url = issued.single.url;
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, 8765);
    });

    test('preserves an explicitly configured HTTPS endpoint', () async {
      final issued = <http.Request>[];
      final client = MockClient((http.Request request) async {
        issued.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{
            'result': const <String>[],
            'error': null,
          }),
          200,
        );
      });
      final service = AnkiConnectService(
        host: 'anki.example.com',
        port: 443,
        useHttps: true,
        client: client,
      );

      await service.getDeckNames();

      expect(issued.single.url.scheme, 'https');
      expect(issued.single.url.host, 'anki.example.com');
      expect(issued.single.url.port, 443);
    });

    test('requests use a short connection to avoid stale pooled sockets',
        () async {
      final issued = <http.Request>[];
      await withMock((s) => s.getDeckNames(),
          sink: issued, result: const <String>[]);

      expect(issued.single.headers['Connection'], 'close');
    });

    test('every call carries action + version 6', () async {
      final issued = <http.Request>[];
      await withMock((s) => s.getModelNames(),
          sink: issued, result: const <String>[]);

      final body = bodyOf(issued.single);
      expect(body['action'], 'modelNames');
      expect(body['version'], 6);
    });

    test('omits params when none are supplied', () async {
      final issued = <http.Request>[];
      await withMock((s) => s.getDeckNames(),
          sink: issued, result: const <String>[]);
      expect(bodyOf(issued.single).containsKey('params'), isFalse);
    });

    test('includes params when supplied', () async {
      final issued = <http.Request>[];
      await withMock((s) => s.getModelFields('Basic'),
          sink: issued, result: const <String>[]);
      final body = bodyOf(issued.single);
      expect(body['action'], 'modelFieldNames');
      expect(body['params'], <String, dynamic>{'modelName': 'Basic'});
    });
  });

  group('result parsing', () {
    test('getDeckNames returns the result list as strings', () async {
      final issued = <http.Request>[];
      final decks = await withMock((s) => s.getDeckNames(),
          sink: issued, result: <String>['Default', '日本語']);
      expect(decks, <String>['Default', '日本語']);
    });

    test('getModelFields returns the field list', () async {
      final issued = <http.Request>[];
      final fields = await withMock((s) => s.getModelFields('Basic'),
          sink: issued, result: <String>['Front', 'Back', 'Reading']);
      expect(fields, <String>['Front', 'Back', 'Reading']);
    });

    test('a list-typed action throws when the result is not a list', () async {
      final issued = <http.Request>[];
      expect(
        () => withMock((s) => s.getDeckNames(),
            sink: issued, result: 'not a list'),
        throwsA(isA<AnkiConnectException>()),
      );
    });
  });

  group('error mapping', () {
    test('non-200 HTTP status throws AnkiConnectException', () async {
      final issued = <http.Request>[];
      expect(
        () => withMock((s) => s.getDeckNames(),
            sink: issued, status: 500, result: null),
        throwsA(isA<AnkiConnectException>()
            .having((e) => e.message, 'message', contains('500'))),
      );
    });

    test('a non-null error field throws AnkiConnectException with its text',
        () async {
      final issued = <http.Request>[];
      expect(
        () => withMock((s) => s.getModelNames(),
            sink: issued, error: 'collection is not available'),
        throwsA(isA<AnkiConnectException>().having(
            (e) => e.message, 'message', 'collection is not available')),
      );
    });

    test('a non-JSON body throws AnkiConnectException', () async {
      final issued = <http.Request>[];
      expect(
        () => withMock((s) => s.getDeckNames(),
            sink: issued, rawBody: 'not json at all'),
        throwsA(isA<AnkiConnectException>()),
      );
    });

    test('checkConnection returns null when version succeeds', () async {
      final issued = <http.Request>[];
      expect(
        await withMock((s) => s.checkConnection(), sink: issued, result: 6),
        isNull,
      );
    });

    test('checkConnection surfaces the AnkiConnect error message', () async {
      // checkConnection wraps any non-socket/timeout/client failure (including
      // an AnkiConnect `error` field) as a "Cannot connect" message rather than
      // returning the raw text, but the underlying message is still included.
      final issued = <http.Request>[];
      final String? message = await withMock((s) => s.checkConnection(),
          sink: issued, error: 'unauthorized');
      expect(message, isNotNull);
      expect(message, contains('unauthorized'));
    });

    test('isAvailable is false when the server errors', () async {
      final issued = <http.Request>[];
      expect(
        await withMock((s) => s.isAvailable(), sink: issued, status: 500),
        isFalse,
      );
    });

    test('isAvailable is true when version succeeds', () async {
      final issued = <http.Request>[];
      expect(
        await withMock((s) => s.isAvailable(), sink: issued, result: 6),
        isTrue,
      );
    });
  });

  group('isDuplicate query shaping', () {
    test('builds a deck/field scoped findNotes query', () async {
      final issued = <http.Request>[];
      await withMock(
        (s) => s.isDuplicate(
            deckName: 'Mining', fieldName: 'Expression', fieldValue: '勉強'),
        sink: issued,
        result: const <int>[],
      );
      final body = bodyOf(issued.single);
      expect(body['action'], 'findNotes');
      expect((body['params'] as Map)['query'], 'deck:"Mining" "Expression:勉強"');
    });

    test('escapes double quotes in the field value', () async {
      final issued = <http.Request>[];
      await withMock(
        (s) => s.isDuplicate(
            deckName: 'Mining', fieldName: 'Expression', fieldValue: 'a"b'),
        sink: issued,
        result: const <int>[],
      );
      expect((bodyOf(issued.single)['params'] as Map)['query'],
          r'deck:"Mining" "Expression:a\"b"');
    });

    test('returns true when findNotes returns matches', () async {
      final issued = <http.Request>[];
      final dup = await withMock(
        (s) => s.isDuplicate(deckName: 'D', fieldName: 'F', fieldValue: 'v'),
        sink: issued,
        result: <int>[1, 2, 3],
      );
      expect(dup, isTrue);
    });

    test('returns false when findNotes returns no matches', () async {
      final issued = <http.Request>[];
      final dup = await withMock(
        (s) => s.isDuplicate(deckName: 'D', fieldName: 'F', fieldValue: 'v'),
        sink: issued,
        result: const <int>[],
      );
      expect(dup, isFalse);
    });
  });

  group('addNote payload', () {
    test('wraps the note with deck/model/fields/tags and dup option', () async {
      final issued = <http.Request>[];
      final id = await withMock(
        (s) => s.addNote(
          deckName: 'Mining',
          modelName: 'Lapis',
          fields: <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'},
          tags: <String>['hibiki', 'mined'],
          allowDuplicate: true,
        ),
        sink: issued,
        result: 1234567890,
      );

      expect(id, 1234567890);
      final body = bodyOf(issued.single);
      expect(body['action'], 'addNote');
      final note = (body['params'] as Map)['note'] as Map;
      expect(note['deckName'], 'Mining');
      expect(note['modelName'], 'Lapis');
      expect(note['fields'],
          <String, dynamic>{'Expression': '勉強', 'Reading': 'べんきょう'});
      expect(note['tags'], <String>['hibiki', 'mined']);
      expect(note['options'], <String, dynamic>{
        'allowDuplicate': true,
        'duplicateScope': 'deck',
        'duplicateScopeOptions': <String, dynamic>{
          'deckName': 'Mining',
          'checkChildren': true,
          'checkAllModels': true,
        },
      });
    });

    test('defaults allowDuplicate to false', () async {
      final issued = <http.Request>[];
      await withMock(
        (s) => s.addNote(
          deckName: 'D',
          modelName: 'M',
          fields: const <String, String>{'F': 'v'},
        ),
        sink: issued,
        result: 1,
      );
      final note = (bodyOf(issued.single)['params'] as Map)['note'] as Map;
      expect(note['options'], <String, dynamic>{
        'allowDuplicate': false,
        'duplicateScope': 'deck',
        'duplicateScopeOptions': <String, dynamic>{
          'deckName': 'D',
          'checkChildren': true,
          'checkAllModels': true,
        },
      });
    });

    test('throws when addNote returns a null id with no error', () async {
      final issued = <http.Request>[];
      expect(
        () => withMock(
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
          sink: issued,
          result: null,
        ),
        throwsA(isA<AnkiConnectException>()),
      );
    });

    test('propagates an AnkiConnect error from addNote', () async {
      final issued = <http.Request>[];
      expect(
        () => withMock(
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
          sink: issued,
          error: 'cannot create note because it is a duplicate',
        ),
        throwsA(isA<AnkiConnectDuplicateException>()),
      );
    });
  });

  group('storeMediaFile payload', () {
    test('sends filename + base64 data', () async {
      final issued = <http.Request>[];
      await withMock(
        (s) => s.storeMediaFile(filename: 'hibiki_audio_abc.mp3', data: 'QUJD'),
        sink: issued,
        result: 'hibiki_audio_abc.mp3',
      );
      final body = bodyOf(issued.single);
      expect(body['action'], 'storeMediaFile');
      final params = body['params'] as Map;
      expect(params['filename'], 'hibiki_audio_abc.mp3');
      expect(params['data'], 'QUJD');
    });

    test('mediaFileExists uses an exact-name getMediaFilesNames query',
        () async {
      final issued = <http.Request>[];
      final bool exists = await withMock(
        (s) => s.mediaFileExists('hibiki_cover_abc.gif'),
        sink: issued,
        result: <String>[
          'hibiki_cover_abc.gif',
          'hibiki_cover_abc.gif.bak',
        ],
      );
      final body = bodyOf(issued.single);
      expect(body['action'], 'getMediaFilesNames');
      expect((body['params'] as Map)['pattern'], 'hibiki_cover_abc.gif');
      expect(exists, isTrue);
    });

    test('mediaFileExists does not accept a neighbouring glob result',
        () async {
      final bool exists = await withMock(
        (s) => s.mediaFileExists('hibiki_cover_abc.gif'),
        sink: <http.Request>[],
        result: <String>['hibiki_cover_abc.gif.bak'],
      );
      expect(exists, isFalse);
    });
  });

  group('api key', () {
    // AnkiConnect with `apiKey` configured rejects keyless requests with
    // "valid api key must be provided"; the service must thread the key into
    // every request body, and omit it entirely when none is configured.
    Future<Map<String, dynamic>> bodyWithApiKey(String apiKey) async {
      final issued = <http.Request>[];
      final client = MockClient((http.Request request) async {
        issued.add(request);
        return http.Response(
          jsonEncode(
              <String, Object?>{'result': const <String>[], 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      await AnkiConnectService(
              host: '127.0.0.1', port: 8765, apiKey: apiKey, client: client)
          .getDeckNames();
      return jsonDecode(issued.single.body) as Map<String, dynamic>;
    }

    test('includes the key field when an api key is configured', () async {
      final body = await bodyWithApiKey('s3cr3t');
      expect(body['key'], 's3cr3t');
    });

    test('omits the key field when no api key is configured', () async {
      final body = await bodyWithApiKey('');
      expect(body.containsKey('key'), isFalse);
    });
  });

  group('stale keep-alive connection', () {
    // BUG-065: AnkiConnect's minimal HTTP server closes idle keep-alive
    // connections. The persistent http.Client can hand a request a dead pooled
    // connection; the first use fails with a connection-drop error (Windows
    // errno=10053 "Write failed", POSIX "Connection reset"/"Broken pipe"), so
    // the user sees an instant failure instead of the 10s timeout. The symptom
    // was an instant "Cannot connect to AnkiConnect: ClientException with
    // SocketException: Write failed" on the *second* request of a fetch (the
    // first `version` probe succeeded). We retry idempotent actions once on a
    // fresh connection. BUG-091: addNote/createModel retry only on a
    // *pre-delivery write failure* ("Write failed"/"Broken pipe" — the request
    // never left the client, so no dup), but NOT on a response-phase reset
    // (which could have happened after Anki processed the request).

    /// A MockClient whose handler throws [exception] for the first [failTimes]
    /// attempts, then serves [okResult], counting every attempt.
    ({http.Client client, List<int> attempts}) flakyClient({
      required int failTimes,
      required Object exception,
      Object? okResult = const <String>['Default'],
    }) {
      final attempts = <int>[];
      final client = MockClient((http.Request request) async {
        attempts.add(1);
        if (attempts.length <= failTimes) {
          throw exception;
        }
        return http.Response(
          jsonEncode(<String, Object?>{'result': okResult, 'error': null}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      return (client: client, attempts: attempts);
    }

    Future<T> run<T>(
        http.Client client, Future<T> Function(AnkiConnectService) body) {
      return body(
          AnkiConnectService(host: '127.0.0.1', port: 8765, client: client));
    }

    test('default transport tags a failed connection before HTTP delivery',
        () async {
      final ServerSocket reservation =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int closedPort = reservation.port;
      await reservation.close();
      final AnkiConnectService service = AnkiConnectService(
        host: InternetAddress.loopbackIPv4.address,
        port: closedPort,
        timeout: const Duration(seconds: 1),
        connectionTimeout: const Duration(milliseconds: 200),
      );

      await expectLater(
        service.addNote(
          deckName: 'D',
          modelName: 'M',
          fields: const <String, String>{'F': 'v'},
        ),
        throwsA(
          isA<AnkiConnectPreDeliveryException>().having(
            (AnkiConnectPreDeliveryException e) => e.cause,
            'cause',
            isA<SocketException>(),
          ),
        ),
      );
    });

    test('retries on errno-coded connection drop (osError path)', () async {
      // Mirrors package:http's _ClientSocketException: implements both
      // ClientException and SocketException, so the service reads osError. The
      // message is deliberately opaque to prove the errno (not the text) drives
      // the decision.
      final f = flakyClient(
        failTimes: 1,
        exception: _FakeClientSocketException(
          'opaque message',
          osError: const OSError('Connection aborted', 10053),
        ),
      );
      final decks = await run(f.client, (s) => s.getDeckNames());
      expect(f.attempts.length, 2, reason: 'initial attempt + one retry');
      expect(decks, <String>['Default']);
    });

    test('retries on message-only connection drop (text fallback)', () async {
      // A plain ClientException with no osError must still be recognised by its
      // message ("Write failed" — Windows errno=10053).
      final f = flakyClient(
        failTimes: 1,
        exception: http.ClientException(
            'ClientException with SocketException: Write failed '
            '(OS Error: ..., errno = 10053), address = localhost, port = 4392'),
      );
      final decks = await run(f.client, (s) => s.getDeckNames());
      expect(f.attempts.length, 2);
      expect(decks, <String>['Default']);
    });

    test('retries a "Connection reset" drop for idempotent reads', () async {
      final f = flakyClient(
        failTimes: 1,
        exception: http.ClientException('Connection reset by peer'),
      );
      final decks = await run(f.client, (s) => s.getDeckNames());
      expect(f.attempts.length, 2);
      expect(decks, <String>['Default']);
    });

    test('gives up after exactly one retry (does not loop)', () async {
      final f = flakyClient(
        failTimes: 99,
        exception: http.ClientException('Write failed (errno = 10053)'),
      );
      await expectLater(
        run(f.client, (s) => s.getDeckNames()),
        throwsA(isA<http.ClientException>()),
      );
      expect(f.attempts.length, 2,
          reason: 'initial + one retry, then surfaces');
    });

    test('does NOT retry a non-connection-drop client error', () async {
      // "Connection closed before full header" / unrelated failures are not
      // connection drops; a retry would not help, so surface immediately.
      final f = flakyClient(
        failTimes: 99,
        exception: http.ClientException(
            'Connection closed before full header was received'),
      );
      await expectLater(
        run(f.client, (s) => s.getDeckNames()),
        throwsA(isA<http.ClientException>()),
      );
      expect(f.attempts.length, 1);
    });

    test('retries addNote on a transport-tagged pre-delivery failure',
        () async {
      // A phase-aware transport may tag a failure before it starts the request
      // stream. The tag, not "Write failed" text or errno, makes one retry safe.
      final f = flakyClient(
        failTimes: 1,
        exception: AnkiConnectPreDeliveryException(
          'write failed before the request started',
          Uri.parse('http://127.0.0.1:8765'),
          const SocketException('Write failed'),
        ),
        okResult: 555,
      );
      final int? id = await run(
        f.client,
        (s) => s.addNote(
          deckName: 'D',
          modelName: 'M',
          fields: const <String, String>{'F': 'v'},
        ),
      );
      expect(f.attempts.length, 2, reason: 'initial write fails + one retry');
      expect(id, 555);
    });

    test('pre-delivery connection timeout retries safely, then surfaces',
        () async {
      final f = flakyClient(
        failTimes: 99,
        exception: AnkiConnectPreDeliveryException(
          'connection establishment timed out',
          Uri.parse('http://127.0.0.1:8765'),
          TimeoutException('connect deadline exceeded'),
        ),
      );
      await expectLater(
        run(
          f.client,
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
        ),
        throwsA(
          isA<AnkiConnectPreDeliveryException>().having(
            (AnkiConnectPreDeliveryException e) => e.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
      expect(
        f.attempts.length,
        2,
        reason: 'connect timeout is pre-delivery, so one retry is safe',
      );
    });

    test('delivery-ambiguous addNote timeout is commit-unknown, no retry',
        () async {
      final f = flakyClient(
        failTimes: 99,
        exception: TimeoutException('response deadline exceeded'),
      );
      await expectLater(
        run(
          f.client,
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
        ),
        throwsA(
          isA<AnkiConnectCommitUnknownException>()
              .having((e) => e.action, 'action', 'addNote')
              .having(
                (e) => e.cause,
                'cause',
                isA<TimeoutException>(),
              ),
        ),
      );
      expect(
        f.attempts.length,
        1,
        reason: 'an overall response timeout may follow a committed addNote',
      );
    });

    test('delivered-body socket timeout is commit-unknown despite connect text',
        () async {
      final _DrainThenSocketTimeoutClient client =
          _DrainThenSocketTimeoutClient();
      await expectLater(
        run(
          client,
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
        ),
        throwsA(
          isA<AnkiConnectCommitUnknownException>()
              .having((e) => e.action, 'action', 'addNote')
              .having(
                (e) => e.cause,
                'cause',
                isA<_FakeClientSocketException>(),
              ),
        ),
      );
      expect(
        client.attempts,
        1,
        reason: 'public socket type/text/errno cannot prove pre-delivery',
      );
    });

    test('delivered-body plain ClientException text is commit-unknown',
        () async {
      final _DrainThenPlainClientTimeoutClient client =
          _DrainThenPlainClientTimeoutClient();
      await expectLater(
        run(
          client,
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
        ),
        throwsA(
          isA<AnkiConnectCommitUnknownException>()
              .having((e) => e.action, 'action', 'addNote')
              .having(
                (e) => e.cause,
                'cause',
                isA<http.ClientException>(),
              ),
        ),
      );
      expect(
        client.attempts,
        1,
        reason: 'ClientException text cannot prove a connect-phase failure',
      );
    });

    test('delivered-body bare SocketException is commit-unknown', () async {
      final _DrainThenBareSocketTimeoutClient client =
          _DrainThenBareSocketTimeoutClient();
      await expectLater(
        run(
          client,
          (s) => s.addNote(
            deckName: 'D',
            modelName: 'M',
            fields: const <String, String>{'F': 'v'},
          ),
        ),
        throwsA(
          isA<AnkiConnectCommitUnknownException>()
              .having((e) => e.action, 'action', 'addNote')
              .having(
                (e) => e.cause,
                'cause',
                isA<SocketException>(),
              ),
        ),
      );
      expect(
        client.attempts,
        1,
        reason: 'a bare socket type/text/errno cannot prove pre-delivery',
      );
    });

    final List<(String, Object)> taggedRetryResponseFailures =
        <(String, Object)>[
      (
        'bare SocketException',
        const SocketException(
          'Connection timed out',
          osError: OSError('Connection timed out', 10060),
        ),
      ),
      ('bare TimeoutException', TimeoutException('response deadline exceeded')),
      (
        'plain ClientException with connect text',
        http.ClientException('Connection timed out'),
      ),
      (
        'ClientException+SocketException with connect text and errno',
        _FakeClientSocketException(
          'Connection timed out',
          osError: const OSError('Connection timed out', 10060),
        ),
      ),
    ];
    for (final (String label, Object failure) in taggedRetryResponseFailures) {
      test('tagged first failure then $label is commit-unknown', () async {
        final _TaggedThenAmbiguousFailureClient client =
            _TaggedThenAmbiguousFailureClient(failure);
        await expectLater(
          run(
            client,
            (s) => s.addNote(
              deckName: 'D',
              modelName: 'M',
              fields: const <String, String>{'F': 'v'},
            ),
          ),
          throwsA(
            isA<AnkiConnectCommitUnknownException>()
                .having((e) => e.action, 'action', 'addNote')
                .having((e) => e.cause, 'cause', same(failure)),
          ),
        );
        expect(
          client.attempts,
          2,
          reason: 'only the tagged first failure is safe to retry',
        );
      });
    }

    test(
        'classifies response-phase addNote reset as unknown commit without retry',
        () async {
      // A "Connection reset" without a write signature could mean the write
      // succeeded and Anki already created the note before the read dropped —
      // re-sending could duplicate. Must not retry; callers need to reconcile
      // against Anki instead of treating this as an ordinary failure.
      final f = flakyClient(
        failTimes: 99,
        exception: http.ClientException('Connection reset by peer'),
      );
      await expectLater(
        run(
            f.client,
            (s) => s.addNote(
                  deckName: 'D',
                  modelName: 'M',
                  fields: const <String, String>{'F': 'v'},
                )),
        throwsA(isA<AnkiConnectCommitUnknownException>()
            .having((e) => e.action, 'action', 'addNote')),
      );
      expect(f.attempts.length, 1,
          reason: 'response-phase drop on addNote is never blindly retried');
    });

    test('retries the idempotent storeMediaFile on a connection drop',
        () async {
      // storeMediaFile overwrites by filename — re-sending is harmless, so it
      // is retried like the read actions.
      final f = flakyClient(
        failTimes: 1,
        exception: http.ClientException('Broken pipe'),
        okResult: 'hibiki_audio_abc.mp3',
      );
      await run(
          f.client,
          (s) =>
              s.storeMediaFile(filename: 'hibiki_audio_abc.mp3', data: 'QUJD'));
      expect(f.attempts.length, 2);
    });
  });
}

/// Stand-in for package:http's private `_ClientSocketException`, which
/// implements both [http.ClientException] and [SocketException] (so callers can
/// read [osError]). Used to exercise the errno-based retry decision.
class _FakeClientSocketException
    implements http.ClientException, SocketException {
  _FakeClientSocketException(this.message, {this.osError});

  @override
  final String message;
  @override
  final OSError? osError;
  @override
  final Uri? uri = null;
  @override
  final InternetAddress? address = null;
  @override
  final int? port = null;

  @override
  String toString() => 'ClientException with SocketException: $message'
      '${osError != null ? ' ($osError)' : ''}';
}

class _DrainThenSocketTimeoutClient extends http.BaseClient {
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts += 1;
    await request.finalize().drain<void>();
    throw _FakeClientSocketException(
      'Connection timed out',
      osError: const OSError('Connection timed out', 10060),
    );
  }
}

class _DrainThenPlainClientTimeoutClient extends http.BaseClient {
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts += 1;
    await request.finalize().drain<void>();
    throw http.ClientException('Connection timed out', request.url);
  }
}

class _DrainThenBareSocketTimeoutClient extends http.BaseClient {
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts += 1;
    await request.finalize().drain<void>();
    throw const SocketException(
      'Connection timed out',
      osError: OSError('Connection timed out', 10060),
    );
  }
}

class _TaggedThenAmbiguousFailureClient extends http.BaseClient {
  _TaggedThenAmbiguousFailureClient(this.secondFailure);

  final Object secondFailure;
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts += 1;
    if (attempts == 1) {
      throw AnkiConnectPreDeliveryException(
        'connection failed before request delivery',
        request.url,
        TimeoutException('connect deadline exceeded'),
      );
    }
    await request.finalize().drain<void>();
    throw secondFailure;
  }
}
