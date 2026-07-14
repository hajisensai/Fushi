import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG 守卫：字幕组内 cue 数量变化时，在屏 cue 的 **element 身份**必须稳定。
///
/// 回归背景：底部锚组渲染用 `slots.reversed` 且 Column 子节点无 key——双语（ASSx2 /
/// 单 .ass 双样式）相邻对白重叠进场时，新 cue 追加到 Column 头部，在屏 cue 的
/// element 被 Flutter 按**位置**复用成另一条 cue（文本 + \fad 不透明度 1→0 瞬跳），
/// 表现为字幕闪一下。PR#49（TODO-1372/BUG-698）已让槽位数据层跨帧稳定，但没有 key
/// 时该稳定性传导不到 element 层。修复 = 每槽位按 cue 身份挂 [KeyedSubtree]。
AudioCue _cue(String text, {required int start, required int end}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'c'
  ..sentenceIndex = 0
  ..textFragmentId = '[data-cue-id="0"]'
  ..text = text
  ..markup = SubtitleMarkup(
    plainText: text,
    spans: const <SubtitleSpan>[],
    anchor: const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center),
  )
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0;

/// 填充层（foreground==null）的精确 finder（ASS 尊重路径每字双层：stroke+fill）。
Finder _fillText(String ch) => find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);

void main() {
  testWidgets(
      'overlapping cues entering a bottom group do not steal on-screen '
      'cue elements (identity-keyed slots)', (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 双语对 JP1/CH1 在屏时，下一对 JP2/CH2 提前重叠进场（ASSx2 时间不齐的常态）。
    c.setCues(<AudioCue>[
      _cue('あ', start: 0, end: 8000), // JP1
      _cue('い', start: 0, end: 8000), // CH1
      _cue('う', start: 6000, end: 12000), // JP2
      _cue('え', start: 6000, end: 12000), // CH2
    ]);
    c.debugUpdateCueForPosition(100); // 只有 JP1/CH1 活跃
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ));
    await tester.pump();
    expect(_fillText('あ'), findsOneWidget);
    expect(_fillText('い'), findsOneWidget);
    final Element jp1Before = tester.element(_fillText('あ'));
    final Element ch1Before = tester.element(_fillText('い'));

    // JP2/CH2 重叠进场：组内 4 条活跃，底部锚 reversed 后新 cue 排到 Column 头部。
    c.debugUpdateCueForPosition(6500);
    await tester.pump();
    expect(_fillText('う'), findsOneWidget);
    expect(_fillText('え'), findsOneWidget);

    // 在屏 JP1/CH1 的 element 必须原样保留（身份 key 让 Flutter 按 cue 匹配而非按
    // Column 位置复用）；否则它们的 widget 被喂成 JP2/CH2 的文本/透明度 → 视觉闪烁。
    expect(identical(tester.element(_fillText('あ')), jp1Before), isTrue,
        reason: 'JP1 element must survive group growth');
    expect(identical(tester.element(_fillText('い')), ch1Before), isTrue,
        reason: 'CH1 element must survive group growth');
  });
}
