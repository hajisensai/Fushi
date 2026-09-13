import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi_audio/fushi_audio.dart';

// BUG-2367：字幕列表点词查词时，浮层锚点原先只有**被点那一个字**的矩形。查询串恒是
// 「被点字位 → 句末」、真实匹配长度要等引擎回报，故被查词跨行时第二排不在锚里，
// 而 [calcPopupPosition] 只按锚的 top/bottom 贴上/贴下（BUG-098「绝不盖住被查词」），
// 浮层就正好压住第二排。修复把锚改成「被点字位 → 句末」的字形盒并集
// （[subtitleListLookupAnchorRect]）——匹配串恒是这段的前缀，锚必然包含被查词。
//
// 本测试钉两层：纯函数并集覆盖跨行；widget 层真点一个换行句的第一排，把回调拿到的锚
// 喂进真实浮层定位函数，断言浮层矩形与「被点字位→句末」那段文字零垂直重叠。

AudioCue _cue(int i, int s, int e, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

Rect _unionRects(Iterable<Rect> rects) {
  final Iterator<Rect> it = rects.iterator;
  if (!it.moveNext()) return Rect.zero;
  Rect union = it.current;
  while (it.moveNext()) {
    union = union.expandToInclude(it.current);
  }
  return union;
}

typedef _RowMeasure = ({
  Offset globalPoint,
  Rect tailRect,
  Rect charRect,
});

/// 复算某行文本从 [fromGrapheme] 起到句末的**全局**矩形，并给出该 grapheme 的中心点。
_RowMeasure _measureRow(
  WidgetTester tester,
  String sentence,
  int fromGrapheme,
) {
  final Finder textFinder = find.text(sentence, findRichText: true);
  expect(textFinder, findsOneWidget);
  final BuildContext context = tester.element(textFinder);
  final RichText richText = tester.widget<RichText>(textFinder);
  final RenderBox textBox = tester.renderObject<RenderBox>(textFinder);
  final List<int> starts = subtitleGraphemeStartOffsets(sentence);
  final List<int> ends = subtitleGraphemeEndOffsets(sentence);
  final TextPainter painter = TextPainter(
    text: richText.text,
    textAlign: TextAlign.start,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: null,
    ellipsis: null,
  )..layout(maxWidth: textBox.size.width);
  Rect boxFor(int start, int end) => _unionRects(
        painter
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: end),
              boxHeightStyle: BoxHeightStyle.max,
            )
            .map((TextBox box) => box.toRect()),
      );
  final Rect charRect = boxFor(starts[fromGrapheme], ends[fromGrapheme]);
  final Rect tailRect = boxFor(starts[fromGrapheme], ends.last);
  painter.dispose();
  final Offset origin = textBox.localToGlobal(Offset.zero);
  return (
    globalPoint: textBox.localToGlobal(charRect.center),
    tailRect: tailRect.shift(origin),
    charRect: charRect.shift(origin),
  );
}

void main() {
  group('subtitleListLookupAnchorRect (BUG-2367)', () {
    test('锚是「被点字位→句末」的并集，跨行时含第二排', () {
      // 两排：0..2 在第一排（y 0..20），3..4 换到第二排（y 20..40）。
      const List<Rect> rects = <Rect>[
        Rect.fromLTWH(0, 0, 10, 20),
        Rect.fromLTWH(10, 0, 10, 20),
        Rect.fromLTWH(20, 0, 10, 20),
        Rect.fromLTWH(0, 20, 10, 20),
        Rect.fromLTWH(10, 20, 10, 20),
      ];
      // 点第一排最后一个字：锚必须一路盖到第二排底（否则浮层贴在第一排下方压住它）。
      expect(
        subtitleListLookupAnchorRect(rects, 2),
        const Rect.fromLTRB(0, 0, 30, 40),
      );
      // 点第二排的字：锚不回头包含第一排——浮层可以贴得更近，不白让空间。
      expect(
        subtitleListLookupAnchorRect(rects, 3),
        const Rect.fromLTRB(0, 20, 20, 40),
      );
      // 越界返回零矩形（调用方的容差扩盒兜底）。
      expect(subtitleListLookupAnchorRect(rects, -1), Rect.zero);
      expect(subtitleListLookupAnchorRect(rects, 5), Rect.zero);
    });
  });

  group('字幕列表查词浮层不压住换行到第二排的词 (BUG-2367)', () {
    testWidgets('点第一排的字，浮层矩形与「被点字位→句末」零垂直重叠', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      // 窄面板 + 长句 → 必然换行（与用户截图同形：列表面板窄、行文本满宽）。
      const String sentence = 'も 推薦人の２人には 喜んでもらえたみたいだ ほんとうによかった';
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, sentence)]);

      Rect? anchor;
      await tester.pumpWidget(_wrap(SizedBox(
        width: 360,
        height: 600,
        child: VideoSubtitleJumpPanel(
          controller: controller,
          onTapCue: (_) {},
          onLookupCue: (AudioCue _, int __, Rect rect) => anchor = rect,
          onClose: () {},
          onCopyCue: (_) => true,
          onFavoriteCue: (_) async {},
          isCueFavorited: (_) => false,
          colorScheme: const ColorScheme.dark(),
          title: 'Subtitle list',
          emptyHint: 'empty',
          width: 360,
        ),
      )));
      await tester.pump();

      final _RowMeasure row = _measureRow(tester, sentence, 0);
      // 前提：这句真的换了行，否则本用例证明不了任何事（空壳断言防线）。
      expect(
        row.tailRect.height,
        greaterThan(row.charRect.height * 1.5),
        reason: '测试语料必须在 360px 面板里换行，否则跨行锚点无从谈起',
      );

      await tester.tapAt(row.globalPoint);
      await tester.pump();

      expect(anchor, isNotNull, reason: '点列表行文本必须触发查词回调');
      // 锚必须盖住整段「被点字位→句末」，被查词无论多长都在里面。
      expect(anchor!.bottom, greaterThanOrEqualTo(row.tailRect.bottom - 0.5));

      // 真实浮层定位（BUG-098 的上/下避让）：浮层与那段文字零垂直重叠。
      final Rect popup = calcPopupPosition(
        selectionRect: anchor!,
        screen: tester.view.physicalSize / tester.view.devicePixelRatio,
        maxWidth: 360,
        maxHeight: 360,
      );
      expect(
        popup.top >= row.tailRect.bottom || popup.bottom <= row.tailRect.top,
        isTrue,
        reason: '浮层压住了被查词所在的行（$popup vs ${row.tailRect}）',
      );
    });
  });
}
