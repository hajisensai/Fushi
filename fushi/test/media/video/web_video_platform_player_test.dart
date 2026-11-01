// 网页视频的 media_kit 播放器后端：页面上报 → player.state / stream；动作 → 页面 JS；
// 以及最关键的一条——原生的 Video + MaterialDesktopVideoControls 能原封不动地跑在它上面
// （VideoController 走外部渲染分支，不碰 mpv 句柄）。

import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi/src/media/video/web_video_platform_player.dart';

WebVideoPlaybackState _state({
  int pos = 0,
  int dur = 600000,
  bool paused = false,
  double rate = 1,
  int w = 3840,
  int h = 2160,
  String href = 'https://www.netflix.com/watch/1',
}) => parseWebVideoStatePayload(<String, Object?>{
  'type': 'state',
  'href': href,
  'videoKey': 'nf-1',
  'hasVideo': true,
  't': pos,
  'paused': paused,
  'dur': dur,
  'vw': w,
  'vh': h,
  'rate': rate,
  'fs': false,
  'title': 't',
})!;

void main() {
  group('WebVideoPlatformPlayer', () {
    late List<String> js;
    late WebVideoPlatformPlayer platform;

    setUp(() {
      js = <String>[];
      platform = WebVideoPlatformPlayer(
        evaluate: (String s) async => js.add(s),
      );
    });

    tearDown(() => platform.dispose());

    test('snapshot feeds state and streams', () async {
      final List<Duration> positions = <Duration>[];
      final List<bool> playing = <bool>[];
      final List<int?> heights = <int?>[];
      platform.stream.position.listen(positions.add);
      platform.stream.playing.listen(playing.add);
      platform.stream.height.listen(heights.add);

      platform.applySnapshot(_state(pos: 1500), volume: 0.5);
      await Future<void>.delayed(Duration.zero);

      expect(platform.state.position, const Duration(milliseconds: 1500));
      expect(platform.state.duration, const Duration(minutes: 10));
      expect(platform.state.playing, isTrue);
      expect(platform.state.volume, 50);
      expect(platform.state.width, 3840);
      expect(platform.state.height, 2160);
      expect(positions, contains(const Duration(milliseconds: 1500)));
      expect(playing, <bool>[true]);
      expect(heights, <int?>[2160]);
    });

    test('position is extrapolated between snapshots while playing', () async {
      platform.applySnapshot(_state(pos: 10000, rate: 2));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      // 2x 走了 ~350 ms ≈ 700 ms（宽松下限，CI 时钟抖动）。
      expect(
        platform.state.position.inMilliseconds,
        greaterThanOrEqualTo(10400),
      );
      platform.applySnapshot(_state(pos: 20000, paused: true));
      final Duration frozen = platform.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(platform.state.position, frozen);
    });

    test('actions become page commands', () async {
      await platform.play();
      await platform.pause();
      await platform.seek(const Duration(seconds: 42));
      await platform.setRate(1.5);
      await platform.setVolume(25);
      await platform.setVolume(0);
      expect(js, <String>[
        'window.__fushiWebVideo.play()',
        'window.__fushiWebVideo.pause()',
        'window.__fushiWebVideo.seek(42000, 1)',
        'window.__fushiWebVideo.setRate(1.5)',
        'window.__fushiWebVideo.setVolume(0.25, false)',
        'window.__fushiWebVideo.setVolume(0.0, true)',
      ]);
      expect(platform.state.position, const Duration(seconds: 42));
      expect(platform.state.rate, 1.5);
    });

    test('seek 在途：旧位置快照不回灌，落进容差 / 收到回执才接受上报', () async {
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async => s.contains('.seek(') ? 'bridge' : 'ok',
      );
      p.applySnapshot(_state(pos: 10000, paused: true));
      await p.seek(const Duration(seconds: 300));
      expect(p.debugSeekInFlight, isTrue);
      // Netflix 还没落地：250 ms 后的快照仍是旧位置——不得把进度条拽回去。
      p.applySnapshot(_state(pos: 10250, paused: true));
      expect(p.state.position, const Duration(seconds: 300));
      expect(p.debugSeekInFlight, isTrue);
      // 落地：上报进入容差 → 结束在途，此后照常跟随上报。
      p.applySnapshot(_state(pos: 300400, paused: true));
      expect(p.debugSeekInFlight, isFalse);
      expect(p.state.position, const Duration(milliseconds: 300400));
      p.applySnapshot(_state(pos: 300900, paused: true));
      expect(p.state.position, const Duration(milliseconds: 300900));
      await p.dispose();
    });

    test('seek 回执：只认最后一次；失败也结束在途，真实位置回灌', () async {
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async => 'bridge',
      );
      p.applySnapshot(_state(pos: 10000, paused: true));
      await p.seek(const Duration(seconds: 100)); // id 1
      await p.seek(const Duration(seconds: 200)); // id 2
      p.applySeekDone(const WebVideoSeekDone(ok: true, err: '', id: 1));
      expect(p.debugSeekInFlight, isTrue, reason: '旧 seek 的回执不结束新 seek');
      p.applySeekDone(const WebVideoSeekDone(ok: false, err: 'timeout', id: 2));
      expect(p.debugSeekInFlight, isFalse);
      p.applySnapshot(_state(pos: 10000, paused: true));
      expect(p.state.position, const Duration(seconds: 10));
      await p.dispose();
    });

    test('seek 没发出去（no-player / null）立即结束在途', () async {
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async => 'no-player',
      );
      p.applySnapshot(_state(pos: 10000, paused: true));
      await p.seek(const Duration(seconds: 100));
      expect(p.debugSeekInFlight, isFalse);
      p.applySnapshot(_state(pos: 10000, paused: true));
      expect(p.state.position, const Duration(seconds: 10));
      await p.dispose();
    });

    test('暂停在途：反向的播放态快照不回灌，一致即结束', () async {
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async => 'ok',
      );
      p.applySnapshot(_state(pos: 1000));
      expect(p.state.playing, isTrue);
      await p.pause();
      p.applySnapshot(_state(pos: 1250));
      expect(p.state.playing, isFalse, reason: '暂停还没落到站点：不翻回播放');
      expect(p.debugPlayPauseInFlight, isTrue);
      p.applySnapshot(_state(pos: 1300, paused: true));
      expect(p.debugPlayPauseInFlight, isFalse);
      p.applySnapshot(_state(pos: 1300));
      expect(p.state.playing, isTrue, reason: '在途结束后照常跟随站点');
      await p.dispose();
    });

    test('play 被页面拒绝（cmdFailed / 没发出去）结束在途', () async {
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async => 'ok',
      );
      p.applySnapshot(_state(pos: 1000, paused: true));
      await p.play();
      expect(p.debugPlayPauseInFlight, isTrue);
      p.applyCommandFailed('play');
      expect(p.debugPlayPauseInFlight, isFalse);
      p.applySnapshot(_state(pos: 1000, paused: true));
      expect(p.state.playing, isFalse);
      final WebVideoPlatformPlayer q = WebVideoPlatformPlayer(
        evaluate: (String s) async => 'no-video',
      );
      await q.play();
      expect(q.debugPlayPauseInFlight, isFalse);
      await p.dispose();
      await q.dispose();
    });

    test('换视频（videoKey 变）作废在途 seek', () async {
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async => 'bridge',
      );
      p.applySnapshot(_state(pos: 1000, paused: true));
      await p.seek(const Duration(seconds: 500));
      p.applySnapshot(
        parseWebVideoStatePayload(<String, Object?>{
          'videoKey': 'nf-2',
          'hasVideo': true,
          't': 0,
          'paused': true,
          'dur': 600000,
        })!,
      );
      expect(p.debugSeekInFlight, isFalse);
      expect(p.state.position, Duration.zero);
      await p.dispose();
    });

    test('站点音轨变成 media_kit 音轨；选轨走页面 API', () async {
      final List<String> calls = <String>[];
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async {
          calls.add(s);
          return true;
        },
      );
      p.applySnapshot(
        parseWebVideoStatePayload(<String, Object?>{
          'videoKey': 'nf-1',
          'hasVideo': true,
          't': 0,
          'paused': true,
          'nfat': <String>[
            'A:en\ten\tEnglish\tPRIMARY\t0',
            'A:ja\tja\t日本語\tPRIMARY\t0',
            '#A:en',
          ].join('\n'),
        })!,
      );
      expect(p.state.tracks.audio.map((AudioTrack t) => t.id), <String>[
        'A:en',
        'A:ja',
      ]);
      expect(p.state.track.audio.id, 'A:en');
      await p.setAudioTrack(p.state.tracks.audio[1]);
      expect(p.state.track.audio.id, 'A:ja');
      expect(calls, <String>[
        'window.__fushiWebVideo.selectNetflixAudioTrack("A:ja")',
      ]);
      // 站点没上报过的轨不发命令。
      await p.setAudioTrack(const AudioTrack('A:xx', null, null));
      expect(calls, hasLength(1));
      await p.dispose();
    });

    test('no mpv handle, no screenshot', () async {
      await expectLater(platform.handle, throwsUnsupportedError);
      expect(await platform.screenshot(), isNull);
    });

    test('Netflix（硬件 DRM）不截帧、不发命令；YouTube 走页面 canvas 截帧', () async {
      final List<String> calls = <String>[];
      // 1x1 PNG 的 data URL：glue `captureFrame` 的成功返回形状。
      const String png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      final WebVideoPlatformPlayer p = WebVideoPlatformPlayer(
        evaluate: (String s) async {
          calls.add(s);
          return png;
        },
      );
      p.applySnapshot(_state());
      expect(p.frameCaptureSupported, isFalse);
      expect(await p.screenshot(), isNull);
      expect(calls, isEmpty);

      p.applySnapshot(_state(href: 'https://www.youtube.com/watch?v=abc'));
      expect(p.frameCaptureSupported, isTrue);
      final Uint8List? bytes = await p.screenshot(format: 'image/png');
      expect(bytes, isNotNull);
      expect(bytes!.sublist(1, 4), 'PNG'.codeUnits);
      expect(calls, <String>[
        "window.__fushiWebVideo.captureFrame('image/png')",
      ]);
      await p.dispose();
    });

    test('截帧结果码 / 坏 data URL 解成 null', () {
      for (final Object? r in <Object?>[
        null,
        'drm',
        'tainted',
        'no-video',
        'data:image/png,abc',
        'data:image/png;base64,',
        'data:image/png;base64,@@@',
      ]) {
        expect(decodeWebVideoFrameDataUrl(r), isNull, reason: '$r');
      }
      expect(
        webVideoFrameCaptureSupported('https://www.netflix.com/watch/1'),
        isFalse,
      );
      expect(
        webVideoFrameCaptureSupported('https://m.youtube.com/watch?v=a'),
        isTrue,
      );
      expect(webVideoFrameCaptureSupported(''), isFalse);
    });
  });

  testWidgets('VideoPlayerController.loadWeb drives cues from page state', (
    WidgetTester tester,
  ) async {
    final List<String> js = <String>[];
    final WebVideoPlatformPlayer platform = WebVideoPlatformPlayer(
      evaluate: (String s) async => js.add(s),
    );
    final VideoPlayerController controller = VideoPlayerController();
    await controller.loadWeb(
      platform: platform,
      bookUid: 'video/stream/nf:1',
      pageUrl: 'https://www.netflix.com/watch/1',
      cues: <AudioCue>[
        AudioCue()
          ..sentenceIndex = 0
          ..startMs = 1000
          ..endMs = 3000
          ..text = 'はじめまして',
        AudioCue()
          ..sentenceIndex = 1
          ..startMs = 5000
          ..endMs = 7000
          ..text = 'よろしく',
      ],
    );
    expect(controller.isWebBackend, isTrue);
    expect(controller.hasNativePlayer, isFalse);

    platform.applySnapshot(_state(pos: 5500, paused: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.positionMs, 5500);
    expect(controller.isPlaying, isFalse);
    expect(controller.currentCue?.text, 'よろしく');

    await controller.seekMs(1200);
    expect(js, contains('window.__fushiWebVideo.seek(1200, 1)'));

    controller.dispose();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'native Video + desktop controls run on the web backend unchanged',
    (WidgetTester tester) async {
      final List<String> js = <String>[];
      final WebVideoPlatformPlayer platform = WebVideoPlatformPlayer(
        evaluate: (String s) async => js.add(s),
      );
      final Player player = Player(platformPlayer: platform);
      final VideoController controller = VideoController(player);
      await player.open(Media('https://www.netflix.com/watch/1'));
      platform.applySnapshot(_state(pos: 65000, dur: 3600000, paused: true));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: SizedBox(
              width: 1280,
              height: 720,
              child: Video(
                controller: controller,
                fill: Colors.transparent,
                controls: MaterialDesktopVideoControls,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(controller.notifier.value, isA<ExternalVideoController>());
      expect(controller.id.value, isNull, reason: '外部渲染：不建纹理');
      // 桌面控制条悬停才显出：把鼠标移进画面。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(640, 360));
      await mouse.moveTo(const Offset(650, 600));
      await tester.pump(const Duration(milliseconds: 300));
      final List<String> texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .toList();
      debugPrint('[web-player-test] texts=$texts');
      // 原生控制条读到了网页上报的位置 / 时长（65 s / 60 min）。
      expect(
        texts.any((String s) => s.contains('01:05 / 60:00')),
        isTrue,
        reason: 'texts=$texts',
      );

      // 原生播放键 → 页面 JS。
      final Finder play = find.byIcon(Icons.play_arrow);
      if (play.evaluate().isNotEmpty) {
        await tester.tap(play.first);
        await tester.pump(const Duration(milliseconds: 50));
        expect(js, contains('window.__fushiWebVideo.play()'));
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
