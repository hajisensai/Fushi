import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:fushi_engine/sync/video_remote_session_core.dart';

void main() {
  test(
    'exclusive lease expires and awaits cleanup before another owner',
    () async {
      DateTime now = DateTime(2026);
      final Completer<void> cleanup = Completer<void>();
      String? expired;
      final VideoRemoteSessionCore core = VideoRemoteSessionCore(
        now: () => now,
        onLeaseExpired: (String peer) async {
          expired = peer;
          await cleanup.future;
        },
      );
      addTearDown(core.dispose);
      await core.acquire('one');
      await expectLater(
        core.acquire('two'),
        throwsA(isA<VideoRemoteException>()),
      );
      now = now.add(const Duration(seconds: 36));
      final Future<void> acquire = core.acquire('two');
      await Future<void>.delayed(Duration.zero);
      expect(expired, 'one');
      expect(core.owner, isNull);
      cleanup.complete();
      await acquire;
      expect(core.owner, 'two');
      await expectLater(
        core.assertOwner('one'),
        throwsA(isA<VideoRemoteException>()),
      );
    },
  );

  test(
    'journal wakes long poll and requests reset when history is lost',
    () async {
      final VideoRemoteSessionCore core = VideoRemoteSessionCore(
        historyLimit: 2,
      );
      addTearDown(core.dispose);
      final Future<Map<String, Object?>> pending = core.events(0);
      core.publish('position', <String, Object?>{'positionMs': 200});
      final Map<String, Object?> first = await pending;
      expect(first['revision'], 1);
      expect((first['events']! as List).length, 1);
      core.publish('pause', <String, Object?>{});
      core.publish('seek', <String, Object?>{});
      expect((await core.events(0, waitMs: 0))['reset'], true);
      expect((await core.events(1, waitMs: 0))['reset'], false);
      expect((await core.events(4, waitMs: 0))['reset'], true);
    },
  );

  test(
    'a disposed core cannot reacquire after awaited expiry cleanup',
    () async {
      DateTime now = DateTime(2026);
      final Completer<void> cleanupStarted = Completer<void>();
      final Completer<void> cleanup = Completer<void>();
      final VideoRemoteSessionCore core = VideoRemoteSessionCore(
        now: () => now,
        onLeaseExpired: (String _) async {
          cleanupStarted.complete();
          await cleanup.future;
        },
      );
      addTearDown(core.dispose);
      await core.acquire('one');
      now = now.add(const Duration(seconds: 36));
      final Future<void> rejected = expectLater(
        core.acquire('two'),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'remote_closed',
          ),
        ),
      );
      await cleanupStarted.future;
      core.dispose();
      cleanup.complete();
      await rejected;
      expect(core.owner, isNull);
    },
  );

  test(
    'duplicate in-flight mining returns same result; payload conflicts fail',
    () async {
      final VideoRemoteSessionCore core = VideoRemoteSessionCore(
        requestLimit: 2,
      );
      addTearDown(core.dispose);
      final Completer<Map<String, Object?>> completion =
          Completer<Map<String, Object?>>();
      int writes = 0;
      Future<Map<String, Object?>> action() {
        writes++;
        return completion.future;
      }

      final Future<Map<String, Object?>> first = core.runIdempotent(
        'one',
        'request',
        action,
        fingerprint: 'mine:sentence1',
      );
      final Future<Map<String, Object?>> second = core.runIdempotent(
        'one',
        'request',
        action,
        fingerprint: 'mine:sentence1',
      );
      expect(identical(first, second), true);
      expect(writes, 1);
      expect(
        () => core.runIdempotent(
          'one',
          'request',
          action,
          fingerprint: 'mine:sentence2',
        ),
        throwsA(isA<VideoRemoteException>()),
      );
      completion.complete(<String, Object?>{'noteId': 12});
      expect((await second)['noteId'], 12);
    },
  );

  test('internal failures are not replayed; protocol failures are', () async {
    final VideoRemoteSessionCore core = VideoRemoteSessionCore();
    addTearDown(core.dispose);
    int runs = 0;
    Future<Map<String, Object?>> broken() async {
      runs++;
      throw StateError('adapter bug');
    }

    await expectLater(
      core.runIdempotent('one', 'broken', broken, fingerprint: 'a'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      core.runIdempotent('one', 'broken', broken, fingerprint: 'a'),
      throwsA(isA<StateError>()),
    );
    expect(runs, 2, reason: 'an internal fault must not be cached');

    int rejected = 0;
    Future<Map<String, Object?>> stale() async {
      rejected++;
      throw const VideoRemoteException(409, 'session_changed');
    }

    for (int i = 0; i < 2; i++) {
      await expectLater(
        core.runIdempotent('one', 'stale', stale, fingerprint: 'b'),
        throwsA(isA<VideoRemoteException>()),
      );
    }
    expect(rejected, 1, reason: 'a protocol answer is replayed by id');
  });

  test(
    'HTTP uses paired credential identity and rejects forged/legacy identities',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'video-remote-engine',
      );
      final _RecordingService service = _RecordingService();
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: temp.path,
        port: 0,
        token: 'legacy',
        videoRemoteService: service,
      );
      server.pairedPeerTokensProvider = () async => <String>{'paired'};
      await server.start();
      final HttpClient client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.stop();
        temp.deleteSync(recursive: true);
      });
      Future<(int, String)> send(
        String path, {
        String? token,
        String method = 'POST',
        String body = '{"peerId":"forged"}',
      }) async {
        final HttpClientRequest request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$path'),
        );
        if (token != null) {
          request.headers.set(
            'authorization',
            'Basic ${base64Encode(utf8.encode('forged:$token'))}',
          );
        }
        if (method == 'POST') request.write(body);
        final HttpClientResponse response = await request.close();
        return (response.statusCode, await utf8.decoder.bind(response).join());
      }

      expect((await send('/api/video-remote/snapshot')).$1, 401);
      expect(
        (await send('/api/video-remote/snapshot', token: 'legacy')).$1,
        403,
      );
      expect(
        (await send('/api/video-remote/snapshot', token: 'paired')).$1,
        200,
      );
      expect(service.peer, sha256.convert(utf8.encode('paired')).toString());
      expect(
        (await send(
          '/api/video-remote/snapshot',
          token: 'paired',
          body: '[]',
        )).$1,
        400,
      );
      expect(
        (await send('/api/video-remote/unknown', token: 'paired')).$1,
        404,
      );
      final (int status, String raw) = await send(
        '/api/capabilities',
        token: 'paired',
        method: 'GET',
      );
      expect(status, 200);
      expect((jsonDecode(raw) as Map)['videoRemoteControlV1'], true);
      service.failure = const VideoRemoteException(409, 'stale_session');
      final (int failureStatus, String failureBody) = await send(
        '/api/video-remote/command',
        token: 'paired',
      );
      expect(failureStatus, 409);
      expect((jsonDecode(failureBody) as Map)['error'], 'stale_session');
      service.failure = null;
      service.crash = StateError('adapter bug');
      final (int crashStatus, String crashBody) = await send(
        '/api/video-remote/command',
        token: 'paired',
      );
      expect(crashStatus, 500);
      expect((jsonDecode(crashBody) as Map)['error'], videoRemoteInternalError);
      expect(crashBody, isNot(contains('adapter bug')));
      service.crash = null;
      server.pairedPeerTokensProvider = () async => <String>{};
      server.invalidatePeerTokenCache();
      expect(
        (await send('/api/video-remote/snapshot', token: 'paired')).$1,
        401,
      );
    },
  );
}

final class _RecordingService implements VideoRemoteService {
  String? peer;
  VideoRemoteException? failure;
  Error? crash;
  @override
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) async {
    peer = peerId;
    if (failure != null) throw failure!;
    if (crash != null) throw crash!;
    return <String, Object?>{'available': false};
  }
}
