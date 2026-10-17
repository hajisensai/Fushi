import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _body(http.Request request) =>
    (jsonDecode(request.body) as Map).cast<String, Object?>();

JellyfinVideoClient _client(
  List<http.Request> requests, {
  Future<http.Response> Function(http.Request request)? respond,
}) => JellyfinVideoClient(
  api: JellyfinApi(
    serverUrl: 'https://media.invalid',
    accessToken: 'test-token',
    client: MockClient((http.Request request) async {
      requests.add(request);
      if (respond != null) return respond(request);
      return http.Response('', 204);
    }),
  ),
  userId: 'user',
);

/// Uses the real PlaybackInfo negotiation and FIFO session queue.
class _NegotiationServer {
  int issuedSessions = 0;

  Future<http.Response> respond(http.Request request) async {
    if (request.url.path == '/Users/user/Items/last') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'Id': 'last',
          'Name': 'Last episode',
          'Type': 'Episode',
          'MediaSources': <Object?>[
            <String, Object?>{
              'Id': 'source',
              'MediaStreams': <Object?>[
                <String, Object?>{'Type': 'Video', 'Index': 0},
              ],
            },
          ],
        }),
        200,
      );
    }
    if (request.url.path == '/Items/last/PlaybackInfo') {
      issuedSessions++;
      return http.Response(
        jsonEncode(<String, Object?>{
          'PlaySessionId': 'session-$issuedSessions',
          'MediaSources': <Object?>[
            <String, Object?>{
              'Id': 'source',
              'SupportsDirectPlay': true,
              'SupportsDirectStream': true,
            },
          ],
        }),
        200,
      );
    }
    if (const <String>{
      '/Sessions/Playing',
      '/Sessions/Playing/Progress',
      '/Sessions/Playing/Stopped',
    }.contains(request.url.path)) {
      expect(request.method, 'POST');
      return http.Response('', 204);
    }
    throw StateError('Unexpected request: ${request.method} ${request.url}');
  }
}

void main() {
  test('position heartbeat is playing before any explicit pause', () async {
    final List<http.Request> requests = <http.Request>[];
    final JellyfinVideoClient client = _client(requests);
    addTearDown(client.close);

    await client.putRemoteVideoPosition('last', 360000, 1);

    expect(requests.single.url.path, '/Sessions/Playing/Progress');
    expect(_body(requests.single)['IsPaused'], isFalse);
    expect(_body(requests.single)['PositionTicks'], 360000 * kTicksPerMs);
  });

  test('a position flush delayed behind pause must not tell the server playback '
      'resumed', () async {
    final List<http.Request> requests = <http.Request>[];
    final JellyfinVideoClient client = _client(requests);
    addTearDown(client.close);
    final Completer<void> persistence = Completer<void>();

    // VideoFushiPage starts a DB-backed position flush before issuing its
    // background pause. The DB writes can finish after the immediate pause
    // notification, making this the actual transport call order.
    final Future<void> lateFlush = persistence.future.then(
      (_) => client.putRemoteVideoPosition('last', 360000, 1),
    );
    await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);
    persistence.complete();
    await lateFlush;

    expect(requests, hasLength(2));
    expect(_body(requests.first)['EventName'], 'pause');
    expect(_body(requests.first)['IsPaused'], isTrue);
    expect(requests.last.url.path, '/Sessions/Playing/Progress');
    expect(_body(requests.last)['EventName'], 'timeupdate');
    expect(_body(requests.last)['PositionTicks'], 360000 * kTicksPerMs);
    expect(
      _body(requests.last)['IsPaused'],
      isTrue,
      reason:
          'A background persistence flush is not an unpause. Otherwise a '
          'disconnected Jellyfin session can extrapolate beyond this position.',
    );
    expect(
      requests.where(
        (http.Request request) =>
            request.url.path == '/Sessions/Playing/Stopped',
      ),
      isEmpty,
      reason: 'Pausing/backgrounding must preserve the resumable session.',
    );
  });

  test(
    'explicit resume restores playing state for later position heartbeats',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final JellyfinVideoClient client = _client(requests);
      addTearDown(client.close);

      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);
      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: false);
      await client.putRemoteVideoPosition('last', 361000, 2);

      expect(requests, hasLength(3));
      expect(_body(requests[1])['EventName'], 'unpause');
      expect(_body(requests.last)['EventName'], 'timeupdate');
      expect(_body(requests.last)['IsPaused'], isFalse);
    },
  );

  test('pause takes effect before its HTTP request finishes', () async {
    final List<http.Request> requests = <http.Request>[];
    final Completer<void> pauseReceived = Completer<void>();
    final Completer<http.Response> pauseResponse = Completer<http.Response>();
    final JellyfinVideoClient client = _client(
      requests,
      respond: (http.Request request) async {
        if (_body(request)['EventName'] == 'pause') {
          pauseReceived.complete();
          return pauseResponse.future;
        }
        return http.Response('', 204);
      },
    );
    addTearDown(client.close);

    final Future<void> pausing = client.setRemoteVideoPlaybackPaused(
      'last',
      360000,
      paused: true,
    );
    await pauseReceived.future;
    await client.putRemoteVideoPosition('last', 360000, 1);
    final List<http.Request> beforePauseResponse = List<http.Request>.of(
      requests,
    );
    pauseResponse.complete(http.Response('', 204));
    await pausing;

    expect(
      beforePauseResponse,
      hasLength(2),
      reason: 'The heartbeat must really be sent while pause is in flight.',
    );
    expect(_body(beforePauseResponse.first)['EventName'], 'pause');
    expect(_body(beforePauseResponse.last)['EventName'], 'timeupdate');
    expect(_body(beforePauseResponse.last)['IsPaused'], isTrue);
  });

  test('failed pause report does not erase the local paused state', () async {
    final List<http.Request> requests = <http.Request>[];
    final JellyfinVideoClient client = _client(
      requests,
      respond: (http.Request request) async =>
          _body(request)['EventName'] == 'pause'
          ? http.Response('Controlled pause-report failure', 500)
          : http.Response('', 204),
    );
    addTearDown(client.close);

    await expectLater(
      client.setRemoteVideoPlaybackPaused('last', 360000, paused: true),
      throwsA(isA<JellyfinApiException>()),
    );
    await client.putRemoteVideoPosition('last', 360000, 1);

    expect(requests, hasLength(2));
    expect(_body(requests.first)['EventName'], 'pause');
    expect(_body(requests.last)['EventName'], 'timeupdate');
    expect(
      _body(requests.last)['IsPaused'],
      isTrue,
      reason: 'The later heartbeat should repair the failed pause report.',
    );
  });

  test(
    'Start clears previous pause even without a negotiated session',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final JellyfinVideoClient client = _client(requests);
      addTearDown(client.close);

      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);
      await client.startRemoteVideoPlayback('last', 360000);
      expect(
        requests,
        hasLength(1),
        reason: 'The no-session Start path deliberately makes no HTTP request.',
      );
      await client.putRemoteVideoPosition('last', 361000, 1);

      expect(requests, hasLength(2));
      expect(_body(requests.last)['EventName'], 'timeupdate');
      expect(
        _body(requests.last)['IsPaused'],
        isFalse,
        reason:
            'Local Start state must reset before the no-session early return.',
      );
    },
  );

  test(
    'a newly negotiated same-item Start resets pause and heartbeat throttle',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final _NegotiationServer server = _NegotiationServer();
      final JellyfinVideoClient client = _client(
        requests,
        respond: server.respond,
      );
      addTearDown(client.close);

      await client.remoteVideoStreamUrls('last');
      await client.startRemoteVideoPlayback('last', 360000);
      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);
      await client.putRemoteVideoPosition('last', 360000, 1);
      await client.remoteVideoStreamUrls('last');
      await client.startRemoteVideoPlayback('last', 360000);
      await client.putRemoteVideoPosition('last', 361000, 2);

      expect(server.issuedSessions, 2);
      expect(requests, hasLength(9));
      final List<Map<String, Object?>> heartbeats = requests
          .where(
            (http.Request request) =>
                request.url.path == '/Sessions/Playing/Progress',
          )
          .map(_body)
          .where(
            (Map<String, Object?> body) => body['EventName'] == 'timeupdate',
          )
          .toList();
      expect(
        heartbeats,
        hasLength(2),
        reason:
            'Both heartbeat calls must send; throttle suppression is not a pass.',
      );
      expect(heartbeats.first['PlaySessionId'], 'session-1');
      expect(heartbeats.first['IsPaused'], isTrue);
      expect(heartbeats.last['PlaySessionId'], 'session-2');
      expect(heartbeats.last['IsPaused'], isFalse);
    },
  );

  test(
    'a late FIFO Stop for the old session preserves the newer session pause',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final _NegotiationServer server = _NegotiationServer();
      final JellyfinVideoClient client = _client(
        requests,
        respond: server.respond,
      );
      addTearDown(client.close);

      await client.remoteVideoStreamUrls('last');
      await client.startRemoteVideoPlayback('last', 350000);
      await client.remoteVideoStreamUrls('last');
      await client.startRemoteVideoPlayback('last', 360000);
      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);
      await client.stopRemoteVideoPlayback('last', 350000);
      await client.putRemoteVideoPosition('last', 360000, 1);

      expect(server.issuedSessions, 2);
      expect(requests, hasLength(9));
      final http.Request stopped = requests.singleWhere(
        (http.Request request) =>
            request.url.path == '/Sessions/Playing/Stopped',
      );
      expect(_body(stopped)['PlaySessionId'], 'session-1');
      expect(client.debugActiveSession('last')?.playSessionId, 'session-2');
      expect(_body(requests.last)['EventName'], 'timeupdate');
      expect(_body(requests.last)['PlaySessionId'], 'session-2');
      expect(
        _body(requests.last)['IsPaused'],
        isTrue,
        reason:
            'Stopping an older FIFO session is not a resume of the current one.',
      );
    },
  );

  test(
    'a delayed flush after the final Stop retains the last paused intent',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final _NegotiationServer server = _NegotiationServer();
      final JellyfinVideoClient client = _client(
        requests,
        respond: server.respond,
      );
      addTearDown(client.close);

      await client.remoteVideoStreamUrls('last');
      await client.startRemoteVideoPlayback('last', 360000);
      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);

      // Route disposal can launch another DB-backed position write while the
      // primary exit flush is still finishing its Stop report.
      final Completer<void> persistence = Completer<void>();
      final Future<void> lateFlush = persistence.future.then(
        (_) => client.putRemoteVideoPosition('last', 360000, 1),
      );
      await client.stopRemoteVideoPlayback('last', 360000);
      expect(client.debugActiveSession('last'), isNull);
      persistence.complete();
      await lateFlush;

      expect(server.issuedSessions, 1);
      expect(requests, hasLength(6));
      final http.Request stopped = requests.singleWhere(
        (http.Request request) =>
            request.url.path == '/Sessions/Playing/Stopped',
      );
      expect(_body(stopped)['PlaySessionId'], 'session-1');
      expect(requests.last.url.path, '/Sessions/Playing/Progress');
      expect(_body(requests.last)['EventName'], 'timeupdate');
      expect(_body(requests.last)['PositionTicks'], 360000 * kTicksPerMs);
      expect(_body(requests.last).containsKey('PlaySessionId'), isFalse);
      expect(
        _body(requests.last)['IsPaused'],
        isTrue,
        reason:
            'Emptying the session queue is not a local unpause; a disposal '
            'flush must not restart server-side playback extrapolation.',
      );
    },
  );

  test(
    'pause state belongs to the item rather than leaking to another episode',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final JellyfinVideoClient client = _client(requests);
      addTearDown(client.close);

      await client.setRemoteVideoPlaybackPaused('last', 360000, paused: true);
      await client.putRemoteVideoPosition('other', 10000, 2);
      await client.putRemoteVideoPosition('last', 360000, 3);

      expect(requests, hasLength(3));
      expect(_body(requests[1])['ItemId'], 'other');
      expect(_body(requests[1])['IsPaused'], isFalse);
      expect(_body(requests.last)['ItemId'], 'last');
      expect(_body(requests.last)['IsPaused'], isTrue);
    },
  );
}
