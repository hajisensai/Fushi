import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG 守卫：位置分组的 Stack 子节点必须按**分组键**挂 key。
///
/// 回归背景：分组顺序=活跃集发现顺序（cue 文件序号）。歌词/招牌（顶部组）与对白
/// （底部组）的序号在 .ass 里交错时，每次换句两组在 Stack 子列表里对调；无 key 时
/// Flutter 按位置复用 element——底部组的 [AnimatedPadding]（控制条避让）被喂成顶部组
/// 的 padding 目标（b:75→0 / t:0→75），把差值动画播出来＝**每句对白入场从底边滑升
/// 一次**（真实播放探针实测 854→778 约 170ms 减速滑动；用户报「字幕跳」）。
AudioCue _cue(String text,
    {required int start, required int end, required bool top}) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = text
    ..markup = SubtitleMarkup(
      plainText: text,
      spans: const <SubtitleSpan>[],
      anchor: top
          ? const SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center)
          : const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center),
    )
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0;
}

Finder _fillText(String ch) => find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);

void main() {
  testWidgets(
      'group order flip does not replay controls-dodge padding animation '
      '(identity-keyed group Positioned)', (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 文件序号交错：对白(0) / 顶部歌词(1) / 对白(2)——换句时顶部组与底部组在
    // 活跃集里的相对顺序翻转（[d1,ED] → [ED,d2]）。
    c.setCues(<AudioCue>[
      _cue('い', start: 0, end: 2000, top: false), // d1
      _cue('あ', start: 1000, end: 10000, top: true), // ED 歌词
      _cue('う', start: 3000, end: 5000, top: false), // d2
    ]);
    c.debugUpdateCueForPosition(1500); // [d1, ED]
    final ValueNotifier<bool> controlsVisible = ValueNotifier<bool>(false);
    addTearDown(controlsVisible.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          respectAssStyle: true,
          controlsVisible: controlsVisible, // 启用 AnimatedPadding 避让路径
        ),
      ),
    ));
    await tester.pump();
    expect(_fillText('い'), findsOneWidget);
    expect(_fillText('あ'), findsOneWidget);
    final Element edBefore = tester.element(_fillText('あ'));
    final double edTopBefore = tester.getRect(_fillText('あ')).top;

    // 换句：组顺序翻转为 [ED, d2]。
    c.debugUpdateCueForPosition(4000);
    await tester.pump();
    expect(_fillText('う'), findsOneWidget);
    final double d2Entry = tester.getRect(_fillText('う')).top;
    final double edAfterFlip = tester.getRect(_fillText('あ')).top;

    // 顶部歌词的 element 必须原样保留（组按键匹配而非按 Stack 位置复用）。
    expect(identical(tester.element(_fillText('あ')), edBefore), isTrue,
        reason: '顶部组 element 不得被底部组窃用');

    // 让可能存在的隐式动画走完；位置必须与入场帧一致（无滑动）。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    final double d2Settled = tester.getRect(_fillText('う')).top;
    final double edSettled = tester.getRect(_fillText('あ')).top;
    expect(d2Settled, closeTo(d2Entry, 0.5),
        reason: '新对白入场位置必须立即到位，不得播 padding 滑动动画');
    expect(edSettled, closeTo(edAfterFlip, 0.5), reason: '顶部歌词不得因组序翻转而滑动');
    expect(edSettled, closeTo(edTopBefore, 0.5), reason: '顶部歌词位置全程不变');
  });
}
