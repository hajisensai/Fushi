// BUG-2537：字幕盒的 hover 回报（页面据此唤回光标 + 唤起 / 续命控制条，BUG-284）只认
// **真实指针移动**。Flutter MouseTracker 在「字幕盒挪到静止指针之下」或子树重挂时也会
// 派发 onEnter——鼠标一动没动，`\pos` 招牌一出现在鼠标停放点，控制条就像被划过一样弹出。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(String raw) {
  final SubtitleMarkup m =
      parseSubtitleMarkup(raw, playResX: 1280, playResY: 720);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = m.plainText
    ..markup = m
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

void main() {
  testWidgets('招牌落到静止指针下不回报 hover；指针真动了才回报，移出回报 false',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final VideoPlayerController c = VideoPlayerController()
      ..debugVideoWidthOverride = 1280
      ..debugVideoHeightOverride = 720;
    addTearDown(c.dispose);
    final List<bool> events = <bool>[];
    final AudioCue sign = _cue(r'{\an7\pos(300,300)}Hoh');

    Future<void> pumpOverlay() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child: VideoSubtitleOverlay(
              controller: c,
              respectAssStyle: true,
              onHoverChanged: events.add,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    // 先量出招牌落点，再把它撤掉。
    c.setCues(<AudioCue>[sign]);
    c.debugUpdateCueForPosition(1000);
    await pumpOverlay();
    final Offset spot = tester.getCenter(find.text('H').first);
    c.debugUpdateCueForPosition(9000);
    await tester.pump();
    expect(find.text('H'), findsNothing);

    // 指针静止停在落点；招牌再次出现（MouseTracker 会对新挂的 MouseRegion 派 onEnter）。
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: spot);
    addTearDown(gesture.removePointer);
    await tester.pump();
    events.clear();
    c.debugUpdateCueForPosition(1000);
    await tester.pump();
    await tester.pump();
    expect(find.text('H'), findsWidgets);
    expect(events, isEmpty,
        reason: '鼠标没动，招牌自己出现在指针下不得算作用户 hover（BUG-2537）');

    // 指针真的动了 1px → 回报 true（且只回报一次）。
    await gesture.moveTo(spot + const Offset(1, 0));
    await tester.pump();
    expect(events, <bool>[true]);
    await gesture.moveTo(spot + const Offset(2, 0));
    await tester.pump();
    expect(events, <bool>[true], reason: '盒内继续移动不重复回报');

    // 移出 → false。
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(events, <bool>[true, false]);
  });
}
