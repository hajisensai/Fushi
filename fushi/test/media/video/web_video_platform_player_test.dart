// 网页视频的 media_kit 播放器后端：页面上报 → player.state / stream；动作 → 页面 JS；
// 以及最关键的一条——原生的 Video + MaterialDesktopVideoControls 能原封不动地跑在它上面
// （VideoController 走外部渲染分支，不碰 mpv 句柄）。
import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_platform_player.dart';

WebVideoPlaybackState _state({
  int pos = 0,
  int dur = 600000,
  bool paused = false,
  double rate = 1,
  int w = 3840,
  int h = 2160,
}) => parseWebVideoStatePayload(<String, Object?>{
  'type': 'state',
  'href': 'https://www.netflix.com/watch/1',
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
        'window.__fushiWebVideo.seek(42000)',
        'window.__fushiWebVideo.setRate(1.5)',
        'window.__fushiWebVideo.setVolume(0.25, false)',
        'window.__fushiWebVideo.setVolume(0.0, true)',
      ]);
      expect(platform.state.position, const Duration(seconds: 42));
      expect(platform.state.rate, 1.5);
    });

    test('no mpv handle, no screenshot', () async {
      await expectLater(platform.handle, throwsUnsupportedError);
      expect(await platform.screenshot(), isNull);
    });
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
