import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'widget_test_helpers.dart';

AudioCue _cue(String t, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
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

  testWidgets(
      'uses themed asbplayer-style bold text shadow without subtitle box',
      (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('A', 0, 1000)]);
    const Color themedSubtitleColor = Color(0xFF00AA88);

    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      fontSize: 36,
      textColor: themedSubtitleColor,
      fontWeight: 500,
      shadowColor: const Color(0xFF224466),
      shadowThickness: 6,
      backgroundColor: const Color(0xFF6688AA),
      backgroundOpacity: 0,
      bottomPadding: 75,
      fontFamily: 'ReaderFont',
    )));

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    final DecoratedBox box = tester.widget(find.byType(DecoratedBox));
    final BoxDecoration decoration = box.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);

    final Text text = tester.widget(find.text('A'));
    expect(text.style!.color, themedSubtitleColor);
    expect(text.style!.fontSize, 36);
    expect(text.style!.fontWeight, FontWeight.w500);
    expect(text.style!.fontFamily, 'ReaderFont');
    // BUG-222: 阴影是贴合文字四周的对称描边/光晕（八方向），不再是单个
    // 向下偏移 Offset(0, thickness) 的 drop shadow（thickness 越大越「掉」、
    // 换句时与字身分离像残留）。
    final List<Shadow> shadows = text.style!.shadows!;
    expect(shadows.length, greaterThan(1));
    for (final Shadow s in shadows) {
      expect(s.color, const Color(0xFF224466));
      expect(s.blurRadius, 6); // blurRadius == thickness
    }
    // 描边对称：x 偏移与 y 偏移的和都为 0（八向相互抵消），且不存在
    // 任何「offset==(0, thickness)」的纯向下投影。
    final double sumDx =
        shadows.fold(0.0, (double a, Shadow s) => a + s.offset.dx);
    final double sumDy =
        shadows.fold(0.0, (double a, Shadow s) => a + s.offset.dy);
    expect(sumDx, moreOrLessEquals(0, epsilon: 1e-6));
    expect(sumDy, moreOrLessEquals(0, epsilon: 1e-6));
    expect(
      shadows.any((Shadow s) => s.offset == const Offset(0, 6)),
      isFalse,
      reason: '不应再有单向下方 Offset(0, thickness) 的投影',
    );
  });
}
