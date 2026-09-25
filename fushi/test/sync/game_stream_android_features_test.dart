import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/game_stream_host.dart';
import 'package:fushi/src/sync/game_stream_library_host.dart';
import 'package:fushi/src/sync/game_stream_mining.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_library.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';

void main() {
  group('host mine fields', () {
    test('accepts every popup.js text field so remote cards match local', () {
      final Map<String, String> fields = gameStreamHostMineFields(
        <String, String>{
          'expression': '食べる',
          'reading': 'たべる',
          'furiganaPlain': '食[た]べる',
          'glossary': '<ol><li>to eat</li></ol>',
          'glossaryFirst': 'to eat',
          'singleGlossaries': '{}',
          'pitchPositions': '2',
          'pitchCategories': 'nakadaka',
          'frequenciesHtml': '<ul></ul>',
          'freqHarmonicRank': '120',
          'dictionaryMedia': '[]',
          'selectedDictionary': 'JMdict',
          'audio': 'https://example.com/taberu.mp3',
          // Never from the phone: the host owns sentence, deck and notes.
          'sentence': 'forged',
          'deck': 'Other',
          'noteId': '1',
        },
      );
      expect(
        fields.keys,
        containsAll(<String>[
          'reading',
          'furiganaPlain',
          'pitchPositions',
          'frequenciesHtml',
          'dictionaryMedia',
          'audio',
        ]),
      );
      expect(fields.containsKey('sentence'), isFalse);
      expect(fields.containsKey('deck'), isFalse);
      expect(fields.containsKey('noteId'), isFalse);
    });

    test('drops phone-local audio paths and maps the legacy term field', () {
      final Map<String, String> fields = gameStreamHostMineFields(
        <String, String>{
          'term': '見る',
          'audio': '/data/user/0/app.fushi.reader/cache/a.mp3',
        },
      );
      expect(fields['expression'], '見る');
      expect(fields.containsKey('audio'), isFalse);
      expect(
        gameStreamHostMineFields(<String, String>{
          'audio': 'data:audio/mpeg;base64,AAAA',
        })['audio'],
        startsWith('data:audio/'),
      );
    });
  });

  group('host encoder helpers', () {
    test('rejection reason comes from the runner message', () {
      expect(
        gameStreamInputRejectionReason(
          PlatformException(
            code: 'input_rejected',
            message: 'unsupported_native_pointer',
          ),
        ),
        'unsupported_native_pointer',
      );
      expect(
        gameStreamInputRejectionReason(
          PlatformException(code: 'input_rejected', message: 'C:\\secret path'),
        ),
        'input_rejected',
      );
    });

    test('resolution scale only ever shrinks', () {
      expect(
        gameStreamResolutionScale(captureHeight: 1080, maxHeight: 720),
        1.5,
      );
      expect(gameStreamResolutionScale(captureHeight: 720, maxHeight: 1080), 1);
    });

    test('adaptive bitrate window leaves adaptation to congestion control', () {
      expect(gameStreamBitrateWindow(targetBps: 20000000, adaptive: true), (
        min: 1000000,
        start: 10000000,
        max: 20000000,
      ));
      // A target below the 1 Mbps floor never produces min > max.
      expect(gameStreamBitrateWindow(targetBps: 500000, adaptive: true), (
        min: 500000,
        start: 500000,
        max: 500000,
      ));
    });

    test('fixed bitrate pins floor, start and ceiling to the target', () {
      expect(gameStreamBitrateWindow(targetBps: 20000000, adaptive: false), (
        min: 20000000,
        start: 20000000,
        max: 20000000,
      ));
    });

    group('answer SDP bitrate tuning', () {
      const String answer =
          'v=0\r\n'
          'o=- 1 2 IN IP4 127.0.0.1\r\n'
          's=-\r\n'
          't=0 0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=rtpmap:111 opus/48000/2\r\n'
          'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103\r\n'
          'a=rtpmap:96 VP8/90000\r\n'
          'a=rtcp-fb:96 nack pli\r\n'
          'a=rtpmap:97 rtx/90000\r\n'
          'a=fmtp:97 apt=96\r\n'
          'a=rtpmap:102 H264/90000\r\n'
          'a=fmtp:102 level-asymmetry-allowed=1;'
          'packetization-mode=1;x-google-start-bitrate=300;'
          'x-google-max-bitrate=2000\r\n'
          'a=rtpmap:103 rtx/90000\r\n'
          'a=fmtp:103 apt=102\r\n'
          'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
          'a=sctp-port:5000\r\n';

      final String tuned = gameStreamTuneVideoSdp(answer, startKbps: 10000);
      const String rates = 'x-google-start-bitrate=10000';

      test('adds an fmtp line to a codec that has none (VP8)', () {
        expect(
          tuned,
          contains('a=rtpmap:96 VP8/90000\r\na=fmtp:96 $rates\r\n'),
        );
      });

      test('replaces an existing rate and keeps codec parameters', () {
        expect(
          tuned,
          contains(
            'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;'
            '$rates\r\n',
          ),
        );
        expect(tuned, isNot(contains('x-google-start-bitrate=300')));
        // A pinned ceiling would outlive a later setParameters raise.
        expect(tuned, isNot(contains('x-google-max-bitrate')));
      });

      test('leaves rtx, audio and data sections untouched', () {
        expect(tuned, contains('a=fmtp:97 apt=96\r\n'));
        expect(tuned, contains('a=fmtp:103 apt=102\r\n'));
        expect(tuned, contains('a=fmtp:111 minptime=10;useinbandfec=1\r\n'));
        expect(tuned, endsWith('a=sctp-port:5000\r\n'));
        expect(RegExp('x-google-start-bitrate').allMatches(tuned).length, 2);
      });

      test('is idempotent', () {
        expect(gameStreamTuneVideoSdp(tuned, startKbps: 10000), tuned);
      });
    });
  });

  group('receiver codec and stats', () {
    RTCRtpCodecCapability codec(String mime) =>
        RTCRtpCodecCapability(mimeType: mime, clockRate: 90000);

    test('preferred codec moves first and keeps the others', () {
      final List<RTCRtpCodecCapability> ordered =
          gameStreamPreferredCodecs(<RTCRtpCodecCapability>[
            codec('video/VP8'),
            codec('video/rtx'),
            codec('video/H264'),
            codec('video/H264'),
          ], GameStreamCodec.h264)!;
      expect(
        ordered.map((RTCRtpCodecCapability c) => c.mimeType).toList(),
        <String>['video/H264', 'video/H264', 'video/VP8', 'video/rtx'],
      );
      expect(
        gameStreamPreferredCodecs(<RTCRtpCodecCapability>[
          codec('video/VP8'),
        ], GameStreamCodec.av1),
        isNull,
        reason: 'An unsupported codec falls back to negotiation',
      );
    });

    test('stats sample derives size, fps, codec, loss and bitrate', () {
      final List<StatsReport> reports = <StatsReport>[
        StatsReport('in', 'inbound-rtp', 0, <dynamic, dynamic>{
          'kind': 'video',
          'frameWidth': 1280,
          'frameHeight': 720,
          'framesPerSecond': 59.7,
          'bytesReceived': 2000000,
          'packetsLost': 1,
          'packetsReceived': 99,
          'codecId': 'c1',
          'decoderImplementation': 'MediaCodec',
        }),
        StatsReport('c1', 'codec', 0, <dynamic, dynamic>{
          'mimeType': 'video/H264',
        }),
        StatsReport('p', 'candidate-pair', 0, <dynamic, dynamic>{
          'state': 'succeeded',
          'nominated': true,
          'currentRoundTripTime': .012,
        }),
      ];
      final GameStreamStatsSample first = GameStreamStatsSample.fromReports(
        reports,
      );
      expect(first.width, 1280);
      expect(first.codec, 'H264');
      expect(first.decoder, 'MediaCodec');
      expect(first.roundTripMs, 12);
      expect(first.lossPercent, closeTo(1, 1e-9));
      expect(first.bitrateKbps, isNull, reason: 'needs two samples');
      final GameStreamStatsSample earlier = GameStreamStatsSample(
        timestampMs: first.timestampMs - 1000,
        bytesReceived: 1000000,
      );
      // Pin the clock: the JIT between two wall-clock samples on a loaded
      // runner stretched the one-second window by over 100 ms.
      final GameStreamStatsSample second = GameStreamStatsSample.fromReports(
        reports,
        previous: earlier,
        nowMs: first.timestampMs,
      );
      expect(second.bitrateKbps, 8000);
    });
  });

  group('library host', () {
    late FushiRemoteGameStreamService service;
    late ValueNotifier<GalHookSessionState> hook;
    late Directory temp;

    setUp(() {
      service = FushiRemoteGameStreamService(sessionIdGenerator: () => 'sid');
      hook = ValueNotifier<GalHookSessionState>(const GalHookSessionState());
      temp = Directory.systemTemp.createTempSync('gs-library');
    });

    tearDown(() {
      service.dispose();
      hook.dispose();
      temp.deleteSync(recursive: true);
    });

    GalgameEntry game(String id, {String? cover}) => GalgameEntry(
      id: id,
      name: 'Game $id',
      exePath: '${temp.path}${Platform.pathSeparator}$id.exe',
      workdir: temp.path,
      coverPath: cover,
      addedAt: DateTime(2026),
    );

    FushiGameStreamLibraryHost host({
      required List<GalgameEntry> games,
      GameStreamGameLauncher? launch,
      GameStreamSessionStarter? start,
      Duration windowTimeout = const Duration(seconds: 5),
    }) => FushiGameStreamLibraryHost(
      loadGames: () async => games,
      isLaunchEnabled: () => true,
      service: service,
      startStream:
          start ??
          ({
            required int hwnd,
            required GameStreamVideoSettings settings,
            required String gameId,
            required String gameTitle,
            required String launchId,
          }) async => service.createSession(
            windowId: 'hwnd:$hwnd',
            gameId: gameId,
            launchId: launchId,
          ),
      launchGame: launch,
      readHookState: () => hook.value,
      hookChanges: hook,
      windowTimeout: windowTimeout,
    );

    test(
      'lists games without host paths and serves only image covers',
      () async {
        final File png = File('${temp.path}${Platform.pathSeparator}c.png')
          ..writeAsBytesSync(<int>[137, 80, 78, 71]);
        final File text = File('${temp.path}${Platform.pathSeparator}c.txt')
          ..writeAsStringSync('secret');
        final FushiGameStreamLibraryHost library = host(
          games: <GalgameEntry>[
            game('a', cover: png.path),
            game('b', cover: text.path),
          ],
        );
        final List<GameStreamLibraryGame> listed = await library.listGames();
        expect(listed.map((GameStreamLibraryGame g) => g.hasCover), <bool>[
          true,
          false,
        ]);
        expect(
          listed.first.toJson().values.whereType<String>().any(
            (String v) => v.contains(temp.path),
          ),
          isFalse,
        );
        expect((await library.cover('a'))?.contentType, 'image/png');
        expect(await library.cover('b'), isNull);
      },
    );

    test(
      'launch starts the game, waits for its window and streams',
      () async {
        final List<String> launched = <String>[];
        final GalgameEntry entry = game('a');
        final FushiGameStreamLibraryHost library = host(
          games: <GalgameEntry>[entry],
          launch: (GalgameEntry g) async {
            launched.add(g.id);
            // The Hook session binds the window a little later.
            scheduleMicrotask(() {
              hook.value = GalHookSessionState(
                phase: GalHookSessionPhase.running,
                launchExe: g.exePath,
                boundWindow: const ExternalWindowInfo(hwnd: 42, title: 'A'),
              );
            });
          },
        );
        service.library = library;
        // Seed the launch record the HTTP route would create.
        final Completer<void> done = Completer<void>();
        unawaited(
          library
              .launch(
                launchId: 'L1',
                gameId: 'a',
                settings: const GameStreamVideoSettings(),
              )
              .whenComplete(done.complete),
        );
        await done.future;
        expect(launched, <String>['a']);
        expect(service.session?.windowId, 'hwnd:42');
        expect(service.session?.gameId, 'a');
      },
      skip: !Platform.isWindows ? 'Remote launch is Windows-only' : false,
    );

    test(
      'a window that never appears fails with window_missing',
      () async {
        final FushiGameStreamLibraryHost library = host(
          games: <GalgameEntry>[game('a')],
          launch: (GalgameEntry g) async {},
          windowTimeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          library.launch(
            launchId: 'L1',
            gameId: 'a',
            settings: const GameStreamVideoSettings(),
          ),
          throwsA(
            isA<GameStreamLaunchRejected>().having(
              (GameStreamLaunchRejected e) => e.code,
              'code',
              GameStreamLaunchFailure.windowMissing,
            ),
          ),
        );
      },
      skip: !Platform.isWindows ? 'Remote launch is Windows-only' : false,
    );

    test(
      'a local session on another game is busy, never torn down remotely',
      () async {
        // 主机主人正在本地玩 b：远端点 a 若照常启动，launchGame 会先拆掉 b 的
        // 文本 Hook、制卡与学习计时。
        hook.value = GalHookSessionState(
          phase: GalHookSessionPhase.running,
          launchExe: game('b').exePath,
          boundWindow: const ExternalWindowInfo(hwnd: 7, title: 'B'),
        );
        final FushiGameStreamLibraryHost library = host(
          games: <GalgameEntry>[game('a'), game('b')],
          launch: (GalgameEntry g) => fail('must not launch over a session'),
        );
        await expectLater(
          library.launch(
            launchId: 'L1',
            gameId: 'a',
            settings: const GameStreamVideoSettings(),
          ),
          throwsA(
            isA<GameStreamLaunchRejected>().having(
              (GameStreamLaunchRejected e) => e.code,
              'code',
              GameStreamLaunchFailure.busy,
            ),
          ),
        );
      },
      skip: !Platform.isWindows ? 'Remote launch is Windows-only' : false,
    );

    test('an unknown game id is rejected before anything starts', () async {
      final FushiGameStreamLibraryHost library = host(
        games: <GalgameEntry>[game('a')],
        launch: (GalgameEntry g) => fail('must not launch'),
      );
      await expectLater(
        library.launch(
          launchId: 'L1',
          gameId: 'zzz',
          settings: const GameStreamVideoSettings(),
        ),
        throwsA(isA<GameStreamLaunchRejected>()),
      );
    });
  });
}
