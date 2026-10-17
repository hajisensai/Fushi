import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/game_stream_session_opener.dart';
import 'package:fushi/src/sync/game_stream_client.dart';

class _RejectingTransport implements GameStreamTransport {
  _RejectingTransport(this.error);

  final Exception error;
  final List<String> paths = <String>[];

  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    paths.add(path);
    throw error;
  }
}

/// Leaving tells the host to stop. A host that no longer has the session (it
/// ended the stream itself, or its server restarted) is already in the state
/// leaving asks for; reporting "could not tell the host" there was a false
/// alarm. Every other rejection still surfaces.
void main() {
  test(
    'a host that no longer knows the session is a completed leave',
    () async {
      final _RejectingTransport transport = _RejectingTransport(
        const GameStreamRequestError(
          statusCode: 404,
          code: 'session_not_found',
        ),
      );

      await leaveGameStreamOnHost(
        FushiGameStreamClient(transport: transport),
        'session',
        'phone',
      );

      expect(transport.paths, <String>['/api/game-stream/stop']);
    },
  );

  test('other host rejections still fail the leave', () async {
    final _RejectingTransport transport = _RejectingTransport(
      const GameStreamRequestError(statusCode: 403, code: 'unauthorized_peer'),
    );

    await expectLater(
      leaveGameStreamOnHost(
        FushiGameStreamClient(transport: transport),
        'session',
        'phone',
      ),
      throwsA(isA<GameStreamRequestError>()),
    );
  });

  test('an unreachable host still fails the leave', () async {
    final _RejectingTransport transport = _RejectingTransport(
      const GameStreamUnreachableError('LAN unavailable'),
    );

    await expectLater(
      leaveGameStreamOnHost(
        FushiGameStreamClient(transport: transport),
        'session',
        'phone',
      ),
      throwsA(isA<GameStreamUnreachableError>()),
    );
  });
}
