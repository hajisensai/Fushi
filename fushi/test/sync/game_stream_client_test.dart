import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

void main() {
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

class _FakeTransport implements GameStreamTransport {
  final Map<String, Map<String, dynamic>?> responses =
      <String, Map<String, dynamic>?>{};
  final List<({String path, Map<String, dynamic> body})> calls =
      <({String path, Map<String, dynamic> body})>[];

  @override
  Future<Map<String, dynamic>?> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    calls.add((path: path, body: body));
    return responses[path];
  }
}
