import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'widget_test_helpers.dart';

AudioCue _cue(String t, int s, int e) => AudioCue()
  ..bookUid = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = t
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  testWidgets('renders current cue as tappable chars; fires onCharTap',
      (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('hello', 0, 1000), _cue('world', 2000, 3000)]);

    String? tappedSentence;
    int? tappedIndex;
    Rect? tappedRect;
    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      onCharTap: (String s, int i, Rect rect) {
        tappedSentence = s;
        tappedIndex = i;
        tappedRect = rect;
      },
    )));

    c.debugUpdateCueForPosition(500);
    await tester.pump();
    // 'hello' 拆成逐字符可点。
    expect(find.text('h'), findsOneWidget);
    expect(find.text('e'), findsOneWidget);
    expect(find.text('l'), findsNWidgets(2));

    await tester.tap(find.text('e'));
    expect(tappedSentence, 'hello');
    expect(tappedIndex, 1); // 'e' 是第 1 个 grapheme
    // 浮层定位用：被点字符报告非零屏幕矩形（弹窗据此定位到字符附近）。
    expect(tappedRect, isNotNull);
    expect(tappedRect, isNot(Rect.zero));
    expect(tappedRect!.width, greaterThan(0));
    expect(tappedRect!.height, greaterThan(0));

    c.debugUpdateCueForPosition(2500);
    await tester.pump();
    expect(find.text('w'), findsOneWidget);
    expect(find.text('h'), findsNothing);
  });

  testWidgets('renders nothing when no current cue', (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('hello', 0, 1000)]);
    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(controller: c)));
    await tester.pump();
    expect(find.text('h'), findsNothing); // 未推进位置，无 current cue
  });
}
