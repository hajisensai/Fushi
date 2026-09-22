import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';

void main() {
  group('game-stream wire', () {
    test('round trips session, signal, input and text', () {
      final DateTime now = DateTime.utc(2026, 9, 22, 3, 0);
      final GameStreamSession session = GameStreamSession.create(
        sessionId: 's1',
        now: now,
        windowId: 'hwnd:10',
      );
      final GameStreamSession restored = GameStreamSession.fromJson(
        session.toJson(),
      );
      expect(restored.sessionId, 's1');
      expect(restored.state, GameStreamSessionState.waiting);
      expect(restored.windowId, 'hwnd:10');

      final GameStreamSignal signal = GameStreamSignal(
        sessionId: 's1',
        senderId: 'phone',
        senderRole: GameStreamPeerRole.client,
        type: GameStreamSignalType.iceCandidate,
        sequence: 2,
        payload: <String, Object?>{
          'candidate': 'candidate:1',
          'sdpMLineIndex': 0,
        },
      );
      expect(
        GameStreamSignal.fromJson(signal.toJson()).payload['candidate'],
        'candidate:1',
      );

      final GameStreamInputEvent input = GameStreamInputEvent(
        sessionId: 's1',
        clientId: 'phone',
        sequence: 4,
        kind: GameStreamInputKind.pointer,
        action: GameStreamInputAction.move,
        timestampMs: 123,
        x: .5,
        y: 1,
      );
      expect(GameStreamInputEvent.fromJson(input.toJson()).y, 1);

      final GameStreamTextEvent line = GameStreamTextEvent(
        sessionId: 's1',
        lineId: 'line-1',
        text: 'こんにちは',
        timestampMs: 123,
        thread: 'main',
        audioResourceId: 'voice-1',
      );
      expect(GameStreamTextEvent.fromJson(line.toJson()).lineId, 'line-1');
    });

    test(
      'rejects unsupported version, malformed values and unsafe pointer',
      () {
        expect(
          () => GameStreamSession.fromJson(<String, Object?>{'version': 99}),
          throwsFormatException,
        );
        expect(
          () => GameStreamInputEvent.fromJson(<String, Object?>{
            'version': 1,
            'sessionId': 's',
            'clientId': 'c',
            'sequence': 1,
            'kind': 'pointer',
            'action': 'down',
            'timestampMs': 1,
            'x': 1.1,
            'y': 0,
          }),
          throwsFormatException,
        );
        expect(
          () => GameStreamSignal.fromJson(<String, Object?>{
            'version': 1,
            'sessionId': 's',
            'senderId': 'c',
            'senderRole': 'client',
            'type': 'offer',
            'sequence': 0,
            'payload': <Object?, Object?>{1: 'bad'},
          }),
          throwsFormatException,
        );
        expect(() => decodeGameStreamJsonObject('[]'), throwsFormatException);
      },
    );

    test('requires kind-specific input fields', () {
      expect(
        () => GameStreamInputEvent(
          sessionId: 's',
          clientId: 'c',
          sequence: 1,
          kind: GameStreamInputKind.key,
          action: GameStreamInputAction.down,
          timestampMs: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => GameStreamInputEvent(
          sessionId: 's',
          clientId: 'c',
          sequence: 1,
          kind: GameStreamInputKind.gamepad,
          action: GameStreamInputAction.move,
          timestampMs: 1,
          button: 'a',
        ),
        throwsFormatException,
      );
    });
  });

  group('game-stream service', () {
    late DateTime now;
    late FushiRemoteGameStreamService service;

    GameStreamInputEvent input(int sequence) => GameStreamInputEvent(
      sessionId: 's1',
      clientId: 'phone',
      sequence: sequence,
      kind: GameStreamInputKind.key,
      action: GameStreamInputAction.down,
      timestampMs: 1,
      key: 'Enter',
    );

    setUp(() {
      now = DateTime.utc(2026, 9, 22);
      service = FushiRemoteGameStreamService(
        now: () => now,
        sessionIdGenerator: () => 's1',
        onInput: (_, __) async {},
        onMine: (request, line) async => GameStreamMineResult(
          ok: true,
          message: '${request.lineId}:${line.text}',
        ),
      );
    });

    tearDown(() async => service.dispose());

    test('host text does not keep an abandoned session alive', () {
      service.createSession();
      service.joinSession(sessionId: 's1', clientId: 'phone');
      service.markConnected(sessionId: 's1');
      now = now.add(const Duration(minutes: 9));
      service.publishText(
        GameStreamTextEvent(
          sessionId: 's1',
          lineId: 'line',
          text: '続き',
          timestampMs: 1,
        ),
      );
      now = now.add(const Duration(minutes: 2));
      service.pruneExpired();
      expect(service.session?.reason, 'expired');
    });

    test('target rejection preserves actionable platform reason', () async {
      service.createSession();
      service.joinSession(sessionId: 's1', clientId: 'phone');
      service.markConnected(sessionId: 's1');
      service.onInput = (_, __) async {
        throw const GameStreamInputRejected('window_not_foreground');
      };
      final GameStreamInputAck ack = await service.handleInput(input(1));
      expect(ack.accepted, isFalse);
      expect(ack.reason, 'window_not_foreground');
    });

    test('oversized signaling body is rejected before decoding', () async {
      service.createSession();
      final Response response = await service.handleRequest(
        Request(
          'POST',
          Uri.parse('http://host/api/game-stream/join'),
          body: jsonEncode(<String, Object?>{
            'sessionId': 's1',
            'clientId': List<String>.filled(600000, 'a').join(),
          }),
        ),
        'POST',
        '/api/game-stream/join',
        peerIdentity: 'peer',
      );
      expect(response.statusCode, 400);
      expect(service.session?.state, GameStreamSessionState.waiting);
    });

    test('enforces one client and explicit lifecycle', () async {
      final GameStreamSession created = service.createSession(windowId: 'w');
      expect(created.state, GameStreamSessionState.waiting);
      service.joinSession(sessionId: 's1', clientId: 'phone');
      expect(
        () => service.joinSession(sessionId: 's1', clientId: 'other'),
        throwsStateError,
      );
      service.markConnected(sessionId: 's1', clientId: 'phone');
      expect(service.session!.state, GameStreamSessionState.connected);
      service.stop(sessionId: 's1', reason: 'user');
      expect(service.session!.state, GameStreamSessionState.stopped);
      expect(() => service.createSession(), returnsNormally);
    });

    test('returns ACK and rejects duplicate/out-of-order input', () async {
      service.createSession();
      service.joinSession(sessionId: 's1', clientId: 'phone');
      service.markConnected(sessionId: 's1', clientId: 'phone');
      expect((await service.handleInput(input(1))).accepted, isTrue);
      final GameStreamInputAck duplicate = await service.handleInput(input(1));
      expect(duplicate.accepted, isFalse);
      expect(duplicate.reason, 'duplicate');
      final GameStreamInputAck old = await service.handleInput(input(0));
      expect(old.reason, 'out_of_order');
    });

    test(
      'accepts sequence zero and returns a NACK when input handler fails',
      () async {
        service = FushiRemoteGameStreamService(
          now: () => now,
          sessionIdGenerator: () => 's1',
          onInput: (_, __) async => throw StateError('native rejected'),
        );
        service.createSession();
        service.joinSession(sessionId: 's1', clientId: 'phone');
        service.markConnected(sessionId: 's1', clientId: 'phone');
        final GameStreamInputAck ack = await service.handleInput(input(0));
        expect(ack.accepted, isFalse);
        expect(ack.reason, 'input_handler_failed');
        expect(
          (await service.handleInput(input(0))).reason,
          'input_handler_failed',
        );
      },
    );

    test('same client join is idempotent after connected', () {
      service.createSession();
      service.joinSession(sessionId: 's1', clientId: 'phone');
      service.markConnected(sessionId: 's1', clientId: 'phone');
      service.joinSession(sessionId: 's1', clientId: 'phone');
      expect(service.session!.state, GameStreamSessionState.connected);
    });

    test('terminal sessions are not listed and reject host signals', () {
      service.createSession();
      service.stop(sessionId: 's1');
      expect(service.sessions, isEmpty);
      expect(
        () => service.markConnected(sessionId: 's1', clientId: 'phone'),
        throwsStateError,
      );
      expect(
        () => service.publishSignal(
          GameStreamSignal(
            sessionId: 's1',
            senderId: 'host',
            senderRole: GameStreamPeerRole.host,
            type: GameStreamSignalType.bye,
            sequence: 0,
            payload: <String, Object?>{},
          ),
        ),
        throwsStateError,
      );
    });

    test('host signal buffer is bounded', () {
      service.createSession();
      for (int i = 0; i < 300; i++) {
        service.publishSignal(
          GameStreamSignal(
            sessionId: 's1',
            senderId: 'host',
            senderRole: GameStreamPeerRole.host,
            type: GameStreamSignalType.iceCandidate,
            sequence: i,
            payload: <String, Object?>{},
          ),
        );
      }
      expect(service.signalsFromClient(), isEmpty);
      expect(service.session!.updatedAt, now);
    });

    test('text callback receives every line beyond retained history', () async {
      final List<GameStreamTextEvent> received = <GameStreamTextEvent>[];
      service.onText = (GameStreamTextEvent event) async {
        received.add(event);
      };
      service.createSession();
      for (int i = 0; i < 200; i++) {
        service.publishText(
          GameStreamTextEvent(
            sessionId: 's1',
            lineId: 'line-$i',
            text: 'text-$i',
            timestampMs: i + 1,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(200));
      expect(service.textEvents, hasLength(128));
    });

    test('binds mining requests to known lineId', () async {
      service.createSession();
      service.joinSession(sessionId: 's1', clientId: 'phone');
      service.markConnected(sessionId: 's1', clientId: 'phone');
      service.publishText(
        GameStreamTextEvent(
          sessionId: 's1',
          lineId: 'line-1',
          text: 'line text',
          timestampMs: 1,
        ),
      );
      final GameStreamMineResult result = await service.mine(
        GameStreamMineRequest(
          sessionId: 's1',
          clientId: 'phone',
          lineId: 'line-1',
          fields: <String, String>{'expression': 'line'},
          sentence: 'line text',
        ),
      );
      expect(result.ok, isTrue);
      expect(
        () => service.mine(
          GameStreamMineRequest(
            sessionId: 's1',
            clientId: 'phone',
            lineId: 'old-line',
            fields: <String, String>{},
            sentence: 'line text',
          ),
        ),
        throwsFormatException,
      );
    });

    test(
      'HTTP mine keeps stale-line FormatException as structured 409',
      () async {
        service.createSession();
        await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/sessions/s1/join'),
            body: jsonEncode(<String, Object?>{'clientId': 'phone'}),
          ),
          'POST',
          '/api/game-stream/sessions/s1/join',
        );
        service.markConnected(sessionId: 's1', clientId: 'phone');
        final Response response = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/sessions/s1/mine'),
            body: jsonEncode(<String, Object?>{
              'version': kGameStreamWireVersion,
              'sessionId': 's1',
              'clientId': 'phone',
              'lineId': 'missing-line',
              'fields': <String, String>{'expression': 'line'},
              'sentence': 'line text',
            }),
          ),
          'POST',
          '/api/game-stream/sessions/s1/mine',
        );
        final Map<String, dynamic> body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(response.statusCode, 409);
        expect(body['code'], 'session_conflict');
        expect(body['error'], 'Unknown or stale game-stream line');
      },
    );

    test(
      'HTTP mine logs handler exceptions and returns sanitized 500',
      () async {
        final _RecordingEngineLogSink logs = _RecordingEngineLogSink();
        final EngineLogSink previousLog = engineLog;
        engineLog = logs;
        addTearDown(() => engineLog = previousLog);
        service.onMine = (_, __) async {
          throw StateError('anki secret failure detail');
        };
        service.createSession();
        await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/sessions/s1/join'),
            body: jsonEncode(<String, Object?>{'clientId': 'phone'}),
          ),
          'POST',
          '/api/game-stream/sessions/s1/join',
        );
        service.markConnected(sessionId: 's1', clientId: 'phone');
        service.publishText(
          GameStreamTextEvent(
            sessionId: 's1',
            lineId: 'line-1',
            text: 'line text',
            timestampMs: 1,
          ),
        );

        final Response response = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/sessions/s1/mine'),
            body: jsonEncode(<String, Object?>{
              'version': kGameStreamWireVersion,
              'sessionId': 's1',
              'clientId': 'phone',
              'lineId': 'line-1',
              'fields': <String, String>{'expression': 'line'},
              'sentence': 'line text',
            }),
          ),
          'POST',
          '/api/game-stream/sessions/s1/mine',
        );
        final String rawBody = await response.readAsString();
        final Map<String, dynamic> body =
            jsonDecode(rawBody) as Map<String, dynamic>;

        expect(response.statusCode, 500);
        expect(body['version'], kGameStreamWireVersion);
        expect(body['code'], 'stream_error');
        expect(body['error'], 'Game stream mine handler failed');
        expect(rawBody, isNot(contains('anki secret failure detail')));
        expect(logs.entries, hasLength(1));
        expect(logs.entries.single.source, 'GameStream.mine');
        expect(
          logs.entries.single.error.toString(),
          contains('anki secret failure detail'),
        );
        expect(logs.entries.single.stack, isNotNull);
      },
    );

    test(
      'HTTP mine short alias accepts non-ASCII sentence and empty fields',
      () async {
        GameStreamMineRequest? observedRequest;
        GameStreamTextEvent? observedLine;
        service.onMine = (request, line) async {
          observedRequest = request;
          observedLine = line;
          return GameStreamMineResult(
            ok: true,
            message: '${request.fields['expression']}:${line.lineId}',
          );
        };
        service.createSession();
        await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/join'),
            body: jsonEncode(<String, Object?>{
              'sessionId': 's1',
              'clientId': 'android-lan-qa',
              'clientName': 'Android QA',
            }),
          ),
          'POST',
          '/api/game-stream/join',
          peerIdentity: 'paired-peer',
        );
        service.markConnected(sessionId: 's1', clientId: 'android-lan-qa');
        const String sentence = 'ただ……私のこと忘れないでって……';
        service.publishText(
          GameStreamTextEvent(
            sessionId: 's1',
            lineId: 'line-nonascii',
            text: sentence,
            timestampMs: 1,
            audioResourceId: 'voice.xwma',
          ),
        );
        final String prettyBody = const JsonEncoder.withIndent('  ').convert(
          <String, Object?>{
            'version': kGameStreamWireVersion,
            'sessionId': 's1',
            'clientId': 'android-lan-qa',
            'lineId': 'line-nonascii',
            'fields': <String, String>{
              'expression': '私',
              'reading': '',
              'glossary': 'synthetic definition',
            },
            'sentence': sentence,
          },
        );
        final Response response = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/mine'),
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
              // The alias path reparses and re-encodes the body before
              // dispatching to the canonical route. Preserve an original
              // Content-Length shape here so the test covers that rewrite.
              'content-length': utf8.encode(prettyBody).length.toString(),
            },
            body: prettyBody,
          ),
          'POST',
          '/api/game-stream/mine',
          peerIdentity: 'paired-peer',
        );
        final Map<String, dynamic> body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;

        expect(response.statusCode, 200);
        expect(body['result'], <String, Object?>{
          'version': kGameStreamWireVersion,
          'ok': true,
          'message': '私:line-nonascii',
        });
        expect(observedRequest, isNotNull);
        expect(observedRequest!.sessionId, 's1');
        expect(observedRequest!.clientId, 'android-lan-qa');
        expect(observedRequest!.lineId, 'line-nonascii');
        expect(observedRequest!.sentence, sentence);
        expect(observedRequest!.fields, <String, String>{
          'expression': '私',
          'reading': '',
          'glossary': 'synthetic definition',
        });
        expect(observedLine?.text, sentence);
      },
    );

    test('expires idle sessions', () {
      service = FushiRemoteGameStreamService(
        now: () => now,
        sessionIdGenerator: () => 's1',
        sessionTtl: const Duration(seconds: 1),
      );
      service.createSession();
      now = now.add(const Duration(seconds: 2));
      service.pruneExpired();
      expect(service.session!.state, GameStreamSessionState.stopped);
      expect(service.session!.reason, 'expired');
    });

    test(
      'HTTP aliases preserve peer authorization and session state',
      () async {
        service.createSession();
        final Response joined = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/join'),
            body: jsonEncode(<String, Object?>{
              'sessionId': 's1',
              'clientId': 'phone',
            }),
          ),
          'POST',
          '/api/game-stream/join',
          peerIdentity: 'paired-peer',
        );
        expect(joined.statusCode, 200);
        expect(service.session!.clientId, 'phone');

        final Response rejected = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/stop'),
            body: jsonEncode(<String, Object?>{
              'sessionId': 's1',
              'clientId': 'phone',
            }),
          ),
          'POST',
          '/api/game-stream/stop',
          peerIdentity: 'other-peer',
        );
        expect(rejected.statusCode, 403);
      },
    );

    test(
      'HTTP signal rejects malformed types and mismatched session',
      () async {
        service.createSession();
        final Response joined = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/join'),
            body: jsonEncode(<String, Object?>{
              'sessionId': 's1',
              'clientId': 'phone',
            }),
          ),
          'POST',
          '/api/game-stream/join',
          peerIdentity: 'paired-peer',
        );
        expect(joined.statusCode, 200);
        final Map<String, Object?> signal = <String, Object?>{
          'version': kGameStreamWireVersion,
          'sessionId': 'other',
          'senderId': 'phone',
          'senderRole': 'client',
          'type': 'iceCandidate',
          'sequence': 0,
          'payload': <String, Object?>{},
        };
        final Response mismatch = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/sessions/s1/signal'),
            body: jsonEncode(<String, Object?>{
              'clientId': 'phone',
              'signal': signal,
            }),
          ),
          'POST',
          '/api/game-stream/sessions/s1/signal',
          peerIdentity: 'paired-peer',
        );
        expect(mismatch.statusCode, 400);
        final Response malformed = await service.handleRequest(
          Request(
            'POST',
            Uri.parse('http://host/api/game-stream/sessions/s1/signal'),
            body: jsonEncode(<String, Object?>{'clientId': 42}),
          ),
          'POST',
          '/api/game-stream/sessions/s1/signal',
          peerIdentity: 'paired-peer',
        );
        expect(malformed.statusCode, 403);
      },
    );

    test('HTTP rejects unknown peer signal and prunes idle sessions', () async {
      service = FushiRemoteGameStreamService(
        now: () => now,
        sessionIdGenerator: () => 's1',
        sessionTtl: const Duration(seconds: 1),
      );
      service.createSession();
      final Response joined = await service.handleRequest(
        Request(
          'POST',
          Uri.parse('http://host/api/game-stream/join'),
          body: jsonEncode(<String, Object?>{
            'sessionId': 's1',
            'clientId': 'phone',
          }),
        ),
        'POST',
        '/api/game-stream/join',
        peerIdentity: 'paired-peer',
      );
      expect(joined.statusCode, 200);
      final Response wrongPeer = await service.handleRequest(
        Request(
          'POST',
          Uri.parse('http://host/api/game-stream/sessions/s1/signal'),
          body: jsonEncode(<String, Object?>{'clientId': 'phone'}),
        ),
        'POST',
        '/api/game-stream/sessions/s1/signal',
        peerIdentity: 'other-peer',
      );
      expect(wrongPeer.statusCode, 403);
      now = now.add(const Duration(seconds: 2));
      final Response listed = await service.handleRequest(
        Request('GET', Uri.parse('http://host/api/game-stream/sessions')),
        'GET',
        '/api/game-stream/sessions',
      );
      expect(listed.statusCode, 200);
      expect(service.session!.state, GameStreamSessionState.stopped);
      expect(service.session!.reason, 'expired');
      expect(await listed.readAsString(), contains('"sessions":[]'));
    });
  });
}

class _RecordingEngineLogSink implements EngineLogSink {
  final List<({String source, Object error, StackTrace? stack})> entries =
      <({String source, Object error, StackTrace? stack})>[];

  @override
  void log(String source, Object error, [StackTrace? stack]) {
    entries.add((source: source, error: error, stack: stack));
  }

  @override
  void logDiagnostic(String source, Object info) {}

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) {
    log(source, error, stack);
  }
}
