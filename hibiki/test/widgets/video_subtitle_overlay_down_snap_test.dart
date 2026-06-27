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
  // TODO-916 症状④-A（down-snap）：down 时刻记录命中字符下标，up 用该下标查词。
  // 即便 down→up 之间字幕盒被控制条避让动画上移，命中仍锁按下瞄准的那个字符，
  // 而不是落到上移后 up 落点下的另一个字符（或 miss）。
  testWidgets('down 记录命中下标后字幕盒上移，up 仍查 down 时刻的字符', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('hello', 0, 1000)]);

    final ValueNotifier<bool> controlsVisible = ValueNotifier<bool>(false);
    addTearDown(controlsVisible.dispose);

    String? tappedSentence;
    int? tappedIndex;
    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      controlsVisible: controlsVisible,
      // 放大避让位移，确保 up 落点显著偏离 down 命中字符（验证锁 down 不依赖 up 反查）。
      controlsBottomReserve: 400,
      bottomPadding: 10,
      onCharTap: (String s, int i, Rect rect) {
        tappedSentence = s;
        tappedIndex = i;
      },
    )));

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 在 'e'（第 1 个 grapheme）上按下。
    final Offset eCenter = tester.getCenter(find.text('e').first);
    final TestGesture gesture = await tester.startGesture(eCenter);
    await tester.pump();

    // down 之后控制条唤起 → 字幕盒被 AnimatedPadding 向上避让；推进动画使盒真的上移。
    controlsVisible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 在仍按住的指针**原位置**松手（盒已上移，原位置如今对应另一个字符 / 空白）。
    await gesture.up();
    await tester.pump();

    // 命中锁 down 时刻的 'e'（index 1），不因盒上移而改判或 miss。
    expect(tappedSentence, 'hello');
    expect(tappedIndex, 1);
  });
}
