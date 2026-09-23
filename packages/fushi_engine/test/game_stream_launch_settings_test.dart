import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/sync/game_stream/game_stream_library.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';

Future<Response> _post(
  FushiRemoteGameStreamService service,
  String path,
  Map<String, Object?> body, {
  String peer = 'peer-a',
}) => service.handleRequest(
  Request('POST', Uri.parse('http://host$path'), body: jsonEncode(body)),
  'POST',
  path,
  peerIdentity: peer,
);

Future<Map<String, dynamic>> _json(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, dynamic>;

class _Library implements GameStreamLibraryHost {
  _Library({this.enabled = true});

  bool enabled;
  final List<String> launched = <String>[];
  Completer<void>? gate;
  Object? failWith;

  @override
  bool get launchEnabled => enabled;

  @override
  Future<List<GameStreamLibraryGame>> listGames() async =>
      const <GameStreamLibraryGame>[
        GameStreamLibraryGame(id: 'g1', title: 'Game One', hasCover: true),
        GameStreamLibraryGame(id: 'g2', title: 'Game Two', running: true),
      ];

  @override
  Future<GameStreamLibraryCover?> cover(String gameId) async => gameId == 'g1'
      ? GameStreamLibraryCover(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          contentType: 'image/png',
        )
      : null;

  @override
  Future<void> launch({
    required String launchId,
    required String gameId,
    required GameStreamVideoSettings settings,
  }) async {
    launched.add('$gameId@${settings.maxHeight}p${settings.maxFps}');
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
  }
}

void main() {
  group('GameStreamVideoSettings', () {
    test('clamps hostile values into the safe range', () {
      final GameStreamVideoSettings settings =
          GameStreamVideoSettings.fromJson(<String, Object?>{
            'maxHeight': 99999,
            'maxFps': 1000,
            'bitrateKbps': 1,
            'degradation': 'maintain-resolution',
            'codec': 'vp9',
            'inputFocus': 'foreground',
            'audio': false,
            'adaptiveBitrate': false,
          });
      expect(settings.maxHeight, GameStreamVideoSettings.maxHeightLimit);
      expect(settings.maxFps, GameStreamVideoSettings.maxFpsLimit);
      expect(settings.bitrateKbps, GameStreamVideoSettings.minBitrateKbps);
      expect(settings.degradation, GameStreamDegradation.maintainResolution);
      expect(settings.codec, GameStreamCodec.vp9);
      expect(settings.inputFocus, GameStreamInputFocus.foreground);
      expect(settings.audio, isFalse);
      expect(settings.adaptiveBitrate, isFalse);
      expect(GameStreamVideoSettings.fromJson(settings.toJson()), settings);
    });

    test('unknown values fall back to defaults instead of failing', () {
      final GameStreamVideoSettings settings = GameStreamVideoSettings.fromJson(
        <String, Object?>{'codec': 'h266', 'degradation': 'sideways'},
      );
      expect(settings.codec, GameStreamCodec.auto);
      expect(settings.degradation, GameStreamDegradation.balanced);
      expect(
        GameStreamVideoSettings.fromJson('not a map'),
        const GameStreamVideoSettings(),
      );
    });

    test('recommended bitrate follows resolution and frame rate', () {
      final int p720 = GameStreamVideoSettings.recommendedBitrateKbps(
        maxHeight: 720,
        maxFps: 30,
      );
      final int p1080x60 = GameStreamVideoSettings.recommendedBitrateKbps(
        maxHeight: 1080,
        maxFps: 60,
      );
      expect(p720, lessThan(p1080x60));
      expect(p1080x60, 20000);
      expect(const GameStreamVideoSettings(maxHeight: 1080).maxWidth, 1920);
    });
  });

  group('session features and pointer input', () {
    test('session round-trips features, game identity and settings', () {
      final GameStreamSession session = GameStreamSession.create(
        sessionId: 's1',
        now: DateTime.utc(2026, 9, 23),
        gameId: 'g1',
        gameTitle: 'Game One',
        features: GameStreamFeature.all,
        settings: const GameStreamVideoSettings(maxHeight: 720),
      );
      final GameStreamSession restored = GameStreamSession.fromJson(
        session.toJson(),
      );
      expect(restored.gameId, 'g1');
      expect(restored.gameTitle, 'Game One');
      expect(restored.supports(GameStreamFeature.wheel), isTrue);
      expect(restored.settings?.maxHeight, 720);
    });

    test('an old session without features supports nothing new', () {
      final Map<String, Object?> json = GameStreamSession.create(
        sessionId: 's1',
        now: DateTime.utc(2026, 9, 23),
      ).toJson()..remove('features');
      final GameStreamSession restored = GameStreamSession.fromJson(json);
      expect(restored.supports(GameStreamFeature.pointerButtons), isFalse);
      expect(restored.settings, isNull);
    });

    GameStreamInputEvent pointer({
      GameStreamInputAction action = GameStreamInputAction.down,
      String? button,
      double? dx,
      double? dy,
    }) => GameStreamInputEvent(
      sessionId: 's1',
      clientId: 'c1',
      sequence: 1,
      kind: GameStreamInputKind.pointer,
      action: action,
      timestampMs: 1,
      x: .5,
      y: .5,
      button: button,
      dx: dx,
      dy: dy,
    );

    test('pointer buttons and wheel deltas are validated', () {
      expect(pointer(button: 'right').button, 'right');
      expect(() => pointer(button: 'back'), throwsFormatException);
      final GameStreamInputEvent wheel = pointer(
        action: GameStreamInputAction.wheel,
        dy: 3,
      );
      expect(GameStreamInputEvent.fromJson(wheel.toJson()).dy, 3);
      expect(
        () => pointer(action: GameStreamInputAction.wheel, dy: 21),
        throwsFormatException,
      );
      expect(() => pointer(dx: 1), throwsFormatException);
      expect(
        () => GameStreamInputEvent(
          sessionId: 's1',
          clientId: 'c1',
          sequence: 1,
          kind: GameStreamInputKind.key,
          action: GameStreamInputAction.down,
          timestampMs: 1,
          key: 'A',
          dy: 1,
        ),
        throwsFormatException,
      );
    });
  });

  group('library and remote launch', () {
    late FushiRemoteGameStreamService service;
    late _Library library;
    int ids = 0;

    setUp(() {
      ids = 0;
      library = _Library();
      service = FushiRemoteGameStreamService(
        library: library,
        sessionIdGenerator: () => 'id${++ids}',
      );
    });

    tearDown(() => service.dispose());

    test('advertises remote launch only with a library', () {
      expect(service.features, contains(GameStreamFeature.remoteLaunch));
      final FushiRemoteGameStreamService bare = FushiRemoteGameStreamService();
      addTearDown(bare.dispose);
      expect(bare.features, isNot(contains(GameStreamFeature.remoteLaunch)));
      expect(bare.features, contains(GameStreamFeature.backgroundInput));
    });

    test('lists games and serves covers as base64', () async {
      final Map<String, dynamic> listing = await _json(
        await _post(service, '/api/game-stream/library', <String, Object?>{}),
      );
      expect(listing['launchEnabled'], isTrue);
      expect((listing['games'] as List).length, 2);
      final Map<String, dynamic> cover = await _json(
        await _post(
          service,
          '/api/game-stream/library/cover',
          <String, Object?>{'gameId': 'g1'},
        ),
      );
      expect(base64Decode(cover['data'] as String), <int>[1, 2, 3]);
      final Response missing = await _post(
        service,
        '/api/game-stream/library/cover',
        <String, Object?>{'gameId': 'g2'},
      );
      expect(missing.statusCode, 404);
    });

    test('library routes are 404 when the host has no library', () async {
      final FushiRemoteGameStreamService bare = FushiRemoteGameStreamService();
      addTearDown(bare.dispose);
      final Response response = await _post(
        bare,
        '/api/game-stream/library',
        <String, Object?>{},
      );
      expect(response.statusCode, 404);
    });

    test('launch is refused while the host owner has not enabled it', () async {
      library.enabled = false;
      final Response response = await _post(
        service,
        '/api/game-stream/launch',
        <String, Object?>{'clientId': 'c1', 'gameId': 'g1'},
      );
      expect(response.statusCode, 403);
      expect((await _json(response))['code'], GameStreamLaunchFailure.disabled);
      expect(library.launched, isEmpty);
    });

    test('launch passes settings, reports progress and reserves the session '
        'for the requesting peer', () async {
      library.gate = Completer<void>();
      final Response accepted =
          await _post(service, '/api/game-stream/launch', <String, Object?>{
            'clientId': 'c1',
            'gameId': 'g1',
            'settings': const GameStreamVideoSettings(
              maxHeight: 720,
              maxFps: 30,
            ).toJson(),
          });
      expect(accepted.statusCode, 202);
      final GameStreamLaunchStatus started = GameStreamLaunchStatus.fromJson(
        (await _json(accepted))['launch'],
      );
      expect(started.state, GameStreamLaunchState.starting);
      await Future<void>.delayed(Duration.zero);
      expect(library.launched, <String>['g1@720p30']);

      // Same requester, same game: idempotent. Another peer: busy.
      final Response again = await _post(
        service,
        '/api/game-stream/launch',
        <String, Object?>{'clientId': 'c1', 'gameId': 'g1'},
      );
      expect(again.statusCode, 200);
      final Response other = await _post(
        service,
        '/api/game-stream/launch',
        <String, Object?>{'clientId': 'c2', 'gameId': 'g2'},
        peer: 'peer-b',
      );
      expect(other.statusCode, 409);
      expect((await _json(other))['code'], GameStreamLaunchFailure.busy);

      // Host opens the session for this launch; it is reserved.
      final GameStreamSession session = service.createSession(
        windowId: 'hwnd:1',
        gameId: 'g1',
        launchId: started.launchId,
      );
      service.updateLaunch(
        started.launchId,
        state: GameStreamLaunchState.streaming,
        sessionId: session.sessionId,
      );
      library.gate!.complete();
      final GameStreamLaunchStatus status = GameStreamLaunchStatus.fromJson(
        (await _json(
          await _post(
            service,
            '/api/game-stream/launch/status',
            <String, Object?>{'launchId': started.launchId},
          ),
        ))['launch'],
      );
      expect(status.state, GameStreamLaunchState.streaming);
      expect(status.sessionId, session.sessionId);

      final Response stolen = await _post(
        service,
        '/api/game-stream/sessions/${session.sessionId}/join',
        <String, Object?>{'clientId': 'c2'},
        peer: 'peer-b',
      );
      expect(stolen.statusCode, 409);
      final Response joined = await _post(
        service,
        '/api/game-stream/sessions/${session.sessionId}/join',
        <String, Object?>{'clientId': 'c1'},
      );
      expect(joined.statusCode, 200);

      final Response foreignStatus = await _post(
        service,
        '/api/game-stream/launch/status',
        <String, Object?>{'launchId': started.launchId},
        peer: 'peer-b',
      );
      expect(foreignStatus.statusCode, 403);
    });

    test('a rejected launch surfaces its stable code', () async {
      library.failWith = const GameStreamLaunchRejected(
        GameStreamLaunchFailure.exeMissing,
      );
      final GameStreamLaunchStatus started = GameStreamLaunchStatus.fromJson(
        (await _json(
          await _post(service, '/api/game-stream/launch', <String, Object?>{
            'clientId': 'c1',
            'gameId': 'g1',
          }),
        ))['launch'],
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final GameStreamLaunchStatus status = service.launch!;
      expect(status.launchId, started.launchId);
      expect(status.state, GameStreamLaunchState.failed);
      expect(status.reason, GameStreamLaunchFailure.exeMissing);
    });

    test('stale launch updates never overwrite a terminal state', () async {
      final GameStreamLaunchStatus started = GameStreamLaunchStatus.fromJson(
        (await _json(
          await _post(service, '/api/game-stream/launch', <String, Object?>{
            'clientId': 'c1',
            'gameId': 'g1',
          }),
        ))['launch'],
      );
      service.updateLaunch(
        started.launchId,
        state: GameStreamLaunchState.failed,
        reason: GameStreamLaunchFailure.windowMissing,
      );
      service.updateLaunch(
        started.launchId,
        state: GameStreamLaunchState.streaming,
        sessionId: 'late',
      );
      expect(service.launch!.state, GameStreamLaunchState.failed);
      expect(service.launch!.sessionId, isNull);
    });
  });

  group('join settings and mine bodies', () {
    late FushiRemoteGameStreamService service;

    setUp(() {
      service = FushiRemoteGameStreamService(sessionIdGenerator: () => 's1');
    });

    tearDown(() => service.dispose());

    test('join forwards settings and reports what the host applied', () async {
      GameStreamVideoSettings? requested;
      service.onSettings = (GameStreamVideoSettings settings) async {
        requested = settings;
        return settings.copyWith(maxHeight: 720);
      };
      service.createSession();
      final Map<String, dynamic> body = await _json(
        await _post(
          service,
          '/api/game-stream/sessions/s1/join',
          <String, Object?>{
            'clientId': 'c1',
            'settings': const GameStreamVideoSettings(
              maxHeight: 1440,
              bitrateKbps: 30000,
            ).toJson(),
          },
        ),
      );
      expect(requested?.maxHeight, 1440);
      final GameStreamSession session = GameStreamSession.fromJson(
        body['session'],
      );
      expect(session.settings?.maxHeight, 720);
      expect(session.settings?.bitrateKbps, 30000);
    });

    test(
      'a multi-dictionary mine body larger than 512 KiB is accepted',
      () async {
        service.createSession();
        await _post(
          service,
          '/api/game-stream/sessions/s1/join',
          <String, Object?>{'clientId': 'c1'},
        );
        service.markConnected(sessionId: 's1', clientId: 'c1');
        service.publishText(
          GameStreamTextEvent(
            sessionId: 's1',
            lineId: 'l1',
            text: '台詞',
            timestampMs: 1,
          ),
        );
        Map<String, String>? minedFields;
        service.onMine = (GameStreamMineRequest request, _) async {
          minedFields = request.fields;
          return const GameStreamMineResult(ok: true);
        };
        final String glossary = List<String>.filled(700 * 1024, 'x').join();
        final Response response = await _post(
          service,
          '/api/game-stream/sessions/s1/mine',
          <String, Object?>{
            'version': kGameStreamWireVersion,
            'sessionId': 's1',
            'clientId': 'c1',
            'lineId': 'l1',
            'sentence': '台詞',
            'fields': <String, String>{
              'expression': '台詞',
              'glossary': glossary,
            },
          },
        );
        expect(response.statusCode, 200);
        expect(minedFields?['glossary']?.length, glossary.length);
      },
    );
  });
}
