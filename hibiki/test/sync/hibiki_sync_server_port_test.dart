import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

void main() {
  group('isAddressInUseError', () {
    test('detects platform errno (98 Linux / 10048 Windows / 48 macOS)', () {
      expect(
        isAddressInUseError(const SocketException('bind failed',
            osError: OSError('Address already in use', 98))),
        isTrue,
      );
      expect(
        isAddressInUseError(const SocketException('bind failed',
            osError: OSError('Only one usage of each socket address', 10048))),
        isTrue,
      );
      expect(
        isAddressInUseError(const SocketException('bind failed',
            osError: OSError('Address already in use', 48))),
        isTrue,
      );
    });

    test('returns false for unrelated socket errors', () {
      expect(
        isAddressInUseError(const SocketException('Connection refused',
            osError: OSError('Connection refused', 111))),
        isFalse,
      );
    });

    test('falls back to the message when osError is absent', () {
      expect(
        isAddressInUseError(const SocketException('Address already in use')),
        isTrue,
      );
      expect(
        isAddressInUseError(const SocketException('Connection reset by peer')),
        isFalse,
      );
    });
  });

  test('start() throws SyncServerPortInUseException when the port is taken',
      () async {
    // Occupy a free port on loopback, then try to start the server on it.
    final ServerSocket blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => blocker.close());
    final int takenPort = blocker.port;

    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_srv_port_');
    addTearDown(() => dir.delete(recursive: true));

    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: dir.path,
      port: takenPort,
      token: 'tok',
      allowLan: false,
    );
    addTearDown(() => server.stop());

    await expectLater(
      server.start(),
      throwsA(isA<SyncServerPortInUseException>().having(
          (SyncServerPortInUseException e) => e.port, 'port', takenPort)),
    );
  });
}
