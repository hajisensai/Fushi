import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';

/// TODO-728②守卫：[AudiobookPlayBar.showCue] 控制底栏「当前句子」cue 文本的显隐。
/// 默认 true = 现状（始终显示）；false = 隐藏文本但**保留 Expanded 占位**，使
/// 其余控件（播放三联键 / follow / 设置齿轮）位置不跳。
class _CueController extends AudiobookPlayerController {
  _CueController(this._cueText);

  final String _cueText;

  @override
  AudioCue? get currentCue {
    final AudioCue cue = AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = '#s1'
      ..text = _cueText
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    return cue;
  }
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required bool showCue,
  required AudiobookPlayerController controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 400,
            child: AudiobookPlayBar(
              controller: controller,
              onOpenSettings: () {},
              showCue: showCue,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('showCue:true renders the current-sentence text', (tester) async {
    final _CueController controller = _CueController('現在の文');
    addTearDown(controller.dispose);
    await _pumpBar(tester, showCue: true, controller: controller);

    expect(find.text('現在の文'), findsOneWidget);
  });

  testWidgets('showCue:false hides the cue text but keeps controls in place',
      (tester) async {
    // 同一控制器、同一布局：先量 showCue:true 的控件位置，再量 showCue:false。
    final _CueController shown = _CueController('現在の文');
    addTearDown(shown.dispose);
    await _pumpBar(tester, showCue: true, controller: shown);
    final double playShown =
        tester.getCenter(find.byIcon(Icons.play_arrow_outlined)).dx;
    final double tuneShown =
        tester.getCenter(find.byIcon(Icons.tune_outlined)).dx;

    final _CueController hidden = _CueController('現在の文');
    addTearDown(hidden.dispose);
    await _pumpBar(tester, showCue: false, controller: hidden);

    // 文本不再渲染。
    expect(find.text('現在の文'), findsNothing);
    // 但播放键 / 设置齿轮位置不变（Expanded 占位保留，布局不跳）。
    final double playHidden =
        tester.getCenter(find.byIcon(Icons.play_arrow_outlined)).dx;
    final double tuneHidden =
        tester.getCenter(find.byIcon(Icons.tune_outlined)).dx;
    expect(playHidden, playShown);
    expect(tuneHidden, tuneShown);
  });
}
