// BUG-5520 (issue #4331): when the SSH transport dies mid-operation (Android
// aborts the socket), dartssh2 2.11.0 left every in-flight SFTP request waiting
// forever and threw `SSHStateError(Transport is closed)` as uncaught errors.
// The SFTP sync backend's op lock stayed held by the stuck request, so sync and
// the "Local vs remote" compare dialog spun until the app restarted.
//
// The fix is the dartssh2 patch in ci/patches/hosted/dartssh2-2.11.0/. These
// tests drive the patched library over a real SSHChannelController whose
// transport is "closed" (sending throws, as SSHTransport.sendPacket does), so
// any send after the transport is gone surfaces as an uncaught error and fails
// the test.

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';

/// One SFTP session over an in-memory channel. [transportClosed] makes every
/// send throw like a closed SSHTransport.
class _Session {
  _Session() {
    controller = SSHChannelController(
      localId: 0,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 1 << 20,
      remoteId: 0,
      remoteInitialWindowSize: 1 << 20,
      remoteMaximumPacketSize: 32768,
      sendMessage: _send,
    );
    sftp = SftpClient(controller.channel);
  }

  late final SSHChannelController controller;
  late final SftpClient sftp;
  bool transportClosed = false;

  /// Channel data messages sent to the "server" (SFTP packets).
  int dataMessagesSent = 0;

  void _send(SSHMessage message) {
    // Same throw as SSHTransport.sendPacket on a closed transport.
    // ignore: only_throw_errors
    if (transportClosed) throw SSHStateError('Transport is closed');
    if (message is SSH_Message_Channel_Data) dataMessagesSent++;
  }

  /// Server's SSH_FXP_VERSION 3 reply: completes the SFTP handshake.
  void replyVersion() {
    final ByteData packet = ByteData(9)
      ..setUint32(0, 5)
      ..setUint8(4, 2)
      ..setUint32(5, 3);
    controller.handleMessage(
      SSH_Message_Channel_Data(
        recipientChannel: 0,
        data: packet.buffer.asUint8List(),
      ),
    );
  }

  /// What SSHClient does for each channel once its transport has closed.
  void dropTransport() {
    transportClosed = true;
    controller.abandon();
  }
}

void main() {
  test(
    'pending request fails with SftpAbortError when the transport drops',
    () async {
      final _Session s = _Session()..replyVersion();
      await s.sftp.handshake;

      final Future<SftpFileAttrs> pending = s.sftp.stat('/remote/file');
      final Future<void> expectation = expectLater(
        pending,
        throwsA(isA<SftpAbortError>()),
      );
      await pumpEventQueue();
      s.dropTransport();

      await expectation.timeout(const Duration(seconds: 5));
      await s.controller.channel.done.timeout(const Duration(seconds: 5));
    },
  );

  test('pending handshake fails when the transport drops first', () async {
    final _Session s = _Session();
    final Future<void> expectation = expectLater(
      s.sftp.stat('/remote/file'),
      throwsA(isA<SftpAbortError>()),
    );
    await pumpEventQueue();
    s.dropTransport();
    await expectation.timeout(const Duration(seconds: 5));
  });

  test('request issued after the session closed fails at once', () async {
    final _Session s = _Session()..replyVersion();
    await s.sftp.handshake;
    s.dropTransport();
    await pumpEventQueue();

    await expectLater(
      s.sftp.stat('/remote/file').timeout(const Duration(seconds: 5)),
      throwsA(isA<SftpAbortError>()),
    );
  });

  test('close() after the channel ended is a no-op', () async {
    final _Session s = _Session()..replyVersion();
    await s.sftp.handshake;
    s.dropTransport();
    await pumpEventQueue();
    s.sftp.close();
  });

  test(
    'backend op fails retryable and releases the op lock for the next op',
    () async {
      final List<_Session> sessions = <_Session>[];
      final SftpSyncBackend backend = SftpSyncBackend.withConnection(() async {
        final _Session s = _Session()..replyVersion();
        sessions.add(s);
        return s.sftp;
      });

      final Future<List<AssetEntry>> first = backend.listChildren('/Fushi');
      final Future<void> firstFails = expectLater(
        first,
        throwsA(
          isA<SyncBackendError>().having(
            (SyncBackendError e) => e.isRetryable,
            'isRetryable',
            isTrue,
          ),
        ),
      );
      await pumpEventQueue();
      expect(sessions, hasLength(1));
      sessions.single.dropTransport();
      await firstFails.timeout(const Duration(seconds: 5));

      // The lock is free: the next op gets a fresh connection and sends its
      // request (init + opendir) instead of queueing behind a dead one.
      unawaited(backend.listChildren('/Fushi').then((_) {}, onError: (_) {}));
      await pumpEventQueue();
      expect(sessions, hasLength(2));
      expect(sessions[1].dataMessagesSent, greaterThanOrEqualTo(2));
      sessions[1].dropTransport();
    },
  );
}
