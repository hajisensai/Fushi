import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG 守卫：静态 `\fscx`/`\fscy` 是 **span 级**语义（标签处生效到下一次覆盖），
/// 不得按行级「最后值生效」整行缩放。
///
/// 真实样本（Youjo Senki S02 NanakoRaws，432 处 \fscx50）：
/// - `{\fscx50}（名前）{\fscx100}本文`——只有说话人前缀压扁；
/// - `…足りません{\fscx50}。`——只有句尾句号压扁。行级模型把后者**整行**压成 50%
/// （用户报「全扁了」）。
AudioCue _cue(String raw) {
  final SubtitleMarkup m =
      parseSubtitleMarkup(raw, playResX: 960, playResY: 540);
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
  test('parser: static fscx is span-scoped', () {
    final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\fscx50}（ヴ）{\fscx100}弾薬ばかりで',
        playResX: 960,
        playResY: 540);
    // 前缀段 scaleX=0.5；主文段恢复 100%（span.scaleX 归一成 null）。
    final SubtitleSpan prefix =
        m.spans.firstWhere((SubtitleSpan s) => s.startGrapheme == 0);
    expect(prefix.scaleX, closeTo(0.5, 1e-6));
    final SubtitleMarkup m2 = parseSubtitleMarkup(r'日用品が全然足りません{\fscx50}。',
        playResX: 960, playResY: 540);
    final SubtitleSpan tail = m2.spans.single;
    expect(tail.scaleX, closeTo(0.5, 1e-6));
    expect(tail.startGrapheme, 11); // 只覆盖句号
  });

  testWidgets('trailing fscx50 squashes only the period, not the line',
      (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[_cue(r'日用品が全然足りません{\fscx50}。')]);
    c.debugUpdateCueForPosition(1000);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ));
    await tester.pump();

    double textW(String ch) => tester
        .getRect(find
            .byWidgetPredicate((Widget w) =>
                w is Text && w.data == ch && w.style?.foreground == null)
            .first)
        .width;

    final double normal = textW('ま');
    // span 缩放经 SizedBox 压布局盒：overlay 里应恰有一个有限宽 SizedBox（句号），
    // 宽度=正常 advance×0.5。
    final Iterable<SizedBox> boxes =
        tester.widgetList<SizedBox>(find.descendant(
      of: find.byType(VideoSubtitleOverlay),
      matching: find.byWidgetPredicate(
          (Widget w) => w is SizedBox && w.width != null && w.width!.isFinite),
    ));
    expect(boxes, hasLength(1), reason: '只有句号段被缩放');
    expect(boxes.single.width, closeTo(normal * 0.5, 1.5),
        reason: '句号布局盒必须压成 50%（span 级 fscx）');
    expect(textW('日'), closeTo(normal, 0.5), reason: '未标注段不得被整行压扁');
  });
}
