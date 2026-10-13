// Plex 心跳的播放态跟随本地暂停意图（与 jellyfin_paused_heartbeat_test 同一模型）。
//
// 播放页的断点落库是异步的：后台先暂停、延迟落库后才发的那条
// putRemoteVideoPosition 心跳若恒报 state=playing，PMS 会把用户刚暂停的条目重新
// 标成播放中。这里用 MockClient 走真实 PlexApi，按请求顺序断言 timeline 的 state。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PlexVideoClient _client(
  List<http.Request> requests, {
  Future<http.Response> Function(http.Request request)? respond,
}) => PlexVideoClient(
  api: PlexApi(
    serverUrl: 'http://pms.invalid:32400',
    token: 'test-token',
    clientInfo: const PlexClientInfo(
      clientIdentifier: 'client-uuid',
      platform: 'Windows',
    ),
    client: MockClient((http.Request request) async {
      expect(request.url.path, '/:/timeline');
      requests.add(request);
      if (respond != null) return respond(request);
      return http.Response('', 200);
    }),
  ),
  machineIdentifier: 'mid-1',
  accountId: '42',
  serverName: 'Home PMS',
);

String? _state(http.Request request) => request.url.queryParameters['state'];

String? _ratingKey(http.Request request) =>
    request.url.queryParameters['ratingKey'];

void main() {
  test('position heartbeat is playing before any explicit pause', () async {
    final List<http.Request> requests = <http.Request>[];
    final PlexVideoClient client = _client(requests);
    addTearDown(client.close);

    await client.putRemoteVideoPosition('ep-9', 360000, 1);

    expect(requests, hasLength(1));
    expect(_state(requests.single), 'playing');
    expect(requests.single.url.queryParameters['time'], '360000');
  });

  test('a position flush delayed behind pause must not tell PMS playback '
      'resumed', () async {
    final List<http.Request> requests = <http.Request>[];
    final PlexVideoClient client = _client(requests);
    addTearDown(client.close);
    final Completer<void> persistence = Completer<void>();

    // VideoFushiPage starts a prefs-backed position flush before issuing its
    // background pause; the write can finish after the immediate pause
    // notification, making this the actual transport call order.
    final Future<void> lateFlush = persistence.future.then(
      (_) => client.putRemoteVideoPosition('ep-9', 360000, 1),
    );
    await client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: true);
    persistence.complete();
    await lateFlush;

    expect(requests, hasLength(2));
    expect(_state(requests.first), 'paused');
    expect(requests.last.url.queryParameters['time'], '360000');
    expect(
      _state(requests.last),
      'paused',
      reason:
          'A background persistence flush is not an unpause; state=playing '
          'would re-mark the just-paused item as playing on PMS.',
    );
    expect(
      requests.where((http.Request r) => _state(r) == 'stopped'),
      isEmpty,
      reason: 'Pausing/backgrounding must not end the playback.',
    );
  });

  test(
    'explicit resume restores playing state for later position heartbeats',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final PlexVideoClient client = _client(requests);
      addTearDown(client.close);

      await client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: true);
      await client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: false);
      await client.putRemoteVideoPosition('ep-9', 361000, 2);

      expect(requests.map(_state), <String>['paused', 'playing', 'playing']);
    },
  );

  test('pause takes effect before its HTTP request finishes', () async {
    final List<http.Request> requests = <http.Request>[];
    final Completer<void> pauseReceived = Completer<void>();
    final Completer<http.Response> pauseResponse = Completer<http.Response>();
    final PlexVideoClient client = _client(
      requests,
      respond: (http.Request request) async {
        if (_state(request) == 'paused' && !pauseReceived.isCompleted) {
          pauseReceived.complete();
          return pauseResponse.future;
        }
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);

    final Future<void> pausing = client.setRemoteVideoPlaybackPaused(
      'ep-9',
      360000,
      paused: true,
    );
    await pauseReceived.future;
    await client.putRemoteVideoPosition('ep-9', 360000, 1);
    final List<http.Request> beforePauseResponse = List<http.Request>.of(
      requests,
    );
    pauseResponse.complete(http.Response('', 200));
    await pausing;

    expect(
      beforePauseResponse,
      hasLength(2),
      reason: 'The heartbeat must really be sent while pause is in flight.',
    );
    expect(beforePauseResponse.map(_state), <String>['paused', 'paused']);
  });

  test('failed pause report does not erase the local paused state', () async {
    final List<http.Request> requests = <http.Request>[];
    bool failedOnce = false;
    final PlexVideoClient client = _client(
      requests,
      respond: (http.Request request) async {
        if (_state(request) == 'paused' && !failedOnce) {
          failedOnce = true;
          return http.Response('Controlled pause-report failure', 500);
        }
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);

    await expectLater(
      client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: true),
      throwsA(isA<PlexApiException>()),
    );
    await client.putRemoteVideoPosition('ep-9', 360000, 1);

    expect(requests, hasLength(2));
    expect(
      _state(requests.last),
      'paused',
      reason: 'The later heartbeat should repair the failed pause report.',
    );
  });

  test(
    'Start clears a previous pause and reopens the heartbeat window',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final PlexVideoClient client = _client(requests);
      addTearDown(client.close);

      await client.startRemoteVideoPlayback('ep-9', 350000);
      await client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: true);
      await client.putRemoteVideoPosition('ep-9', 360000, 1);
      await client.startRemoteVideoPlayback('ep-9', 360000);
      await client.putRemoteVideoPosition('ep-9', 361000, 2);

      expect(
        requests.map(_state),
        <String>['playing', 'paused', 'paused', 'playing', 'playing'],
        reason:
            'Both heartbeat calls must send (throttle suppression is not a '
            'pass); only the new Start resets the pause intent.',
      );
    },
  );

  test('a delayed flush after Stop retains the last paused intent', () async {
    final List<http.Request> requests = <http.Request>[];
    final PlexVideoClient client = _client(requests);
    addTearDown(client.close);

    await client.startRemoteVideoPlayback('ep-9', 360000);
    await client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: true);

    // Route disposal can launch another position write while the exit flush
    // is still finishing its Stop report.
    final Completer<void> persistence = Completer<void>();
    final Future<void> lateFlush = persistence.future.then(
      (_) => client.putRemoteVideoPosition('ep-9', 360000, 1),
    );
    await client.stopRemoteVideoPlayback('ep-9', 360000);
    persistence.complete();
    await lateFlush;

    expect(
      requests.map(_state),
      <String>['playing', 'paused', 'stopped', 'paused'],
      reason:
          'Stopping is not a local unpause; a disposal flush must not report '
          'state=playing.',
    );
  });

  test(
    'pause state belongs to the item rather than leaking to another episode',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final PlexVideoClient client = _client(requests);
      addTearDown(client.close);

      await client.setRemoteVideoPlaybackPaused('ep-9', 360000, paused: true);
      await client.putRemoteVideoPosition('ep-10', 10000, 2);
      await client.putRemoteVideoPosition('ep-9', 360000, 3);

      expect(requests, hasLength(3));
      expect(_ratingKey(requests[1]), 'ep-10');
      expect(_state(requests[1]), 'playing');
      expect(_ratingKey(requests.last), 'ep-9');
      expect(_state(requests.last), 'paused');
    },
  );
}
