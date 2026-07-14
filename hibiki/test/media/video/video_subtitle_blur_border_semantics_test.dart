import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG 守卫：ASS `\blur` 的 libass 语义 —— **有描边（\bord>0）时只糊描边层，字面
/// fill 保持锐利**；无描边（\bord==0）才糊整个字形。
///
/// 回归背景：`{\blur5}` + Outline=2.5 的对白（Nekomoe kissaten ASSx2 发布常见写法）
/// 此前被整字 [ImageFiltered] 高斯，白字黑边糊成一团不可读；mpv/libass 渲染为
/// 「清晰白字 + 柔光黑晕」（libass `ass_bitmap.c`：有描边位图糊描边、无描边才糊字形）。
AudioCue _cue(String raw) {
  final SubtitleMarkup m = parseSubtitleMarkup(raw);
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

VideoPlayerController _stubWithCue(AudioCue cue) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[cue]);
  c.debugUpdateCueForPosition(cue.startMs + 1);
  return c;
}

Future<void> _pump(
  WidgetTester tester,
  AudioCue cue, {
  required double shadowThickness,
}) async {
  final VideoPlayerController c = _stubWithCue(cue);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        textColor: const Color(0xFFFFFFFF),
        shadowColor: const Color(0xFF000000),
        shadowThickness: shadowThickness,
        respectAssStyle: true,
      ),
    ),
  ));
  await tester.pump();
}

/// 填充层（foreground==null）/描边层（foreground!=null）的精确 widget finder。
Finder _fillText(String ch) => find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);
Finder _strokeText(String ch) => find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground != null);

void main() {
  testWidgets(
      r'\blur with outline: stroke layer blurred, fill layer stays sharp '
      '(libass border-only blur)', (WidgetTester tester) async {
    // shadowThickness=5 → _resolveStroke 回退统一描边宽 → strokePaint 非空（双层）。
    await _pump(tester, _cue(r'{\blur5}あ'), shadowThickness: 5);

    expect(_strokeText('あ'), findsOneWidget);
    expect(_fillText('あ'), findsOneWidget);

    // 描边层必须在 ImageFiltered 里（辉光糊在描边上）……
    expect(
      find.ancestor(of: _strokeText('あ'), matching: find.byType(ImageFiltered)),
      findsWidgets,
    );
    // ……而字面 fill 层绝不能被任何 ImageFiltered 包住（保持锐利、可读）。
    expect(
      find.ancestor(of: _fillText('あ'), matching: find.byType(ImageFiltered)),
      findsNothing,
    );
  });

  testWidgets(
      r'\blur without outline: whole glyph blurred (edge blur preserved)',
      (WidgetTester tester) async {
    // shadowThickness=0 且 markup 无 ASS 描边 → strokePaint 为 null → 单层 fill。
    await _pump(tester, _cue(r'{\blur5}あ'), shadowThickness: 0);

    expect(_strokeText('あ'), findsNothing);
    expect(_fillText('あ'), findsOneWidget);
    // 无描边位图可糊 → libass 糊字形本身：fill 层在 ImageFiltered 里。
    expect(
      find.ancestor(of: _fillText('あ'), matching: find.byType(ImageFiltered)),
      findsWidgets,
    );
  });

  testWidgets(r'no \blur: neither layer wrapped in ImageFiltered',
      (WidgetTester tester) async {
    await _pump(tester, _cue('あ'), shadowThickness: 5);
    expect(find.byType(ImageFiltered), findsNothing);
  });
}
