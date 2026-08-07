import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

// BUG-874：查词浮层打开时，根 Overlay 的全屏 dismiss barrier 盖在推挤式字幕列表侧栏之上、
// 抢走点击 → 点列表里下一个词只会关浮层。修复让 barrier 先用 [VideoSubtitleListHitTester]
// 反查是否点到了列表某行某字符，是则切换查词。本测试在最强可落地层（widget）钉死这条反查：
// 绑定句柄 → 对某行字符全局坐标 hitTest 返回正确 (cue, grapheme, charRect)，行外返回 null。

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

/// 复算某行某 grapheme 的全局中心点（与面板行内 tap 同源的 TextPainter 逻辑），供 hitTest。
({Offset globalPoint, int graphemeIndex}) _pointForGrapheme(
  WidgetTester tester,
  String sentence,
  String targetGrapheme,
) {
  final Finder textFinder = find.text(sentence, findRichText: true);
  expect(textFinder, findsOneWidget);
  final BuildContext context = tester.element(textFinder);
  final RichText richText = tester.widget<RichText>(textFinder);
  final RenderBox textBox = tester.renderObject<RenderBox>(textFinder);
  final List<String> graphemes = sentence.characters.toList(growable: false);
  final int targetIndex = graphemes.indexOf(targetGrapheme);
  expect(targetIndex, greaterThanOrEqualTo(0), reason: targetGrapheme);
  int startOffset = 0;
  for (int i = 0; i < targetIndex; i++) {
    startOffset += graphemes[i].length;
  }
  final int endOffset = startOffset + graphemes[targetIndex].length;
  final TextPainter painter = TextPainter(
    text: richText.text,
    textAlign: TextAlign.start,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: null,
    ellipsis: null,
  )..layout(maxWidth: textBox.size.width);
  final Rect targetRect = _unionRects(
    painter
        .getBoxesForSelection(
          TextSelection(baseOffset: startOffset, extentOffset: endOffset),
        )
        .map((TextBox box) => box.toRect()),
  );
  painter.dispose();
  expect(targetRect, isNot(Rect.zero));
  return (
    globalPoint: textBox.localToGlobal(targetRect.center),
    graphemeIndex: targetIndex,
  );
}

void main() {
  group('subtitle grapheme offset helpers (BUG-874 shared with barrier hit)',
      () {
    test('start/end offsets track UTF-16 lengths incl. multi-unit graphemes',
        () {
      // 'a' + 👩‍💻(ZWJ 组合, 多 code unit) + 'b'。
      const String text = 'a👩‍💻b';
      final List<int> starts = subtitleGraphemeStartOffsets(text);
      final List<int> ends = subtitleGraphemeEndOffsets(text);
      expect(starts.length, 3);
      expect(ends.length, 3);
      // 'a' 占 1 个 UTF-16 unit；ZWJ 表情占多个；'b' 占 1 个。
      expect(starts.first, 0);
      expect(ends.first, 1);
      expect(starts[1], 1);
      expect(ends.last, text.length);
      // 每个 grapheme 的 [start,end) 连续、不重叠。
      for (int i = 1; i < starts.length; i++) {
        expect(starts[i], ends[i - 1]);
      }
    });
  });

  // BUG-916：字幕列表 Shift-悬停 / tap 查词系统性「偏左一格」——指向「護」查出「の」、
  // 指「ね」查出「衛」。病根是旧命中走 getPositionForOffset 的 caret 边界：点落在某字**左
  // 半格**时返回该字左边界（= 与左邻字之间的边界），旧映射又把边界一律归**左**字。改由
  // resolveSubtitleListGraphemeHit 对**每个字的真实渲染盒**做几何命中（先 contains 后半字宽
  // 最近），对真实像素点判定、不再塌陷左右半格。下面用合成矩形钉死这条纯函数判定。
  group('resolveSubtitleListGraphemeHit (BUG-916 几何命中，不偏左)', () {
    // 三个连续方块字：[0,30) [30,60) [60,90)，行高 40。
    final List<Rect> rects = <Rect>[
      const Rect.fromLTWH(0, 0, 30, 40),
      const Rect.fromLTWH(30, 0, 30, 40),
      const Rect.fromLTWH(60, 0, 30, 40),
    ];

    test('点在字内 → 该字（含左半格，回归病根）', () {
      // 中间字**左半格** x=35：旧实现查到左邻字（下标 0），几何命中返回本字（下标 1）。
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(35, 20)), 1,
          reason: '指向某字左半格必须命中该字本身，不偏左一格');
      // 中间字右半格 x=55 同样命中本字。
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(55, 20)), 1);
      // 首字左端、末字右端。
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(2, 20)), 0);
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(88, 20)), 2);
    });

    test('两字边界点归右侧字（Rect.contains 含左边、排右边）', () {
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(30, 20)), 1);
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(60, 20)), 2);
    });

    test('字缝 / 越界：半字宽容差内取最近，超出返回 -1', () {
      // 右端外 10px（< 半字宽 15）→ 命中末字。
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(100, 20)), 2);
      // 远在右侧（> 半字宽）→ 无命中。
      expect(resolveSubtitleListGraphemeHit(rects, const Offset(140, 20)), -1);
    });

    test('空矩形跳过；全空 → -1', () {
      expect(
        resolveSubtitleListGraphemeHit(
          <Rect>[Rect.zero, const Rect.fromLTWH(30, 0, 30, 40)],
          const Offset(40, 20),
        ),
        1,
      );
      expect(
          resolveSubtitleListGraphemeHit(
              <Rect>[Rect.zero, Rect.zero], const Offset(5, 5)),
          -1);
      expect(resolveSubtitleListGraphemeHit(<Rect>[], const Offset(5, 5)), -1);
    });
  });

  group('VideoSubtitleListHitTester wiring (BUG-874)', () {
    testWidgets(
        'panel binds a hit tester that reverse-hits a row char to '
        '(cue, grapheme, charRect)', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'first line'),
        _cue(1, 2000, 3000, 'second line'),
      ]);
      final VideoSubtitleListHitTester hitTester = VideoSubtitleListHitTester();

      await tester.pumpWidget(_wrap(SizedBox(
        width: 420,
        height: 500,
        child: VideoSubtitleJumpPanel(
          controller: controller,
          onTapCue: (_) {},
          // 查词能力启用（barrier 反查只在可查词时登记行）。
          onLookupCue: (AudioCue _, int __, Rect ___) {},
          hitTester: hitTester,
          onClose: () {},
          onCopyCue: (_) {},
          onFavoriteCue: (_) async {},
          isCueFavorited: (_) => false,
          colorScheme: const ColorScheme.dark(),
          title: 'Subtitle list',
          emptyHint: 'empty',
          width: 420,
        ),
      )));
      await tester.pump();

      final ({Offset globalPoint, int graphemeIndex}) target =
          _pointForGrapheme(tester, 'second line', 'c');

      final SubtitleListHit? hit = hitTester.hitTest(target.globalPoint);
      expect(hit, isNotNull,
          reason: 'tapping a list row char while a popup is open must resolve '
              'to a lookup hit (not fall through to dismiss)');
      expect(hit!.cue.text, 'second line');
      expect(hit.cue.startMs, 2000);
      expect(hit.graphemeIndex, target.graphemeIndex,
          reason: 'reverse-hit maps UTF-16 offset back to the grapheme');
      expect(hit.charRect.contains(target.globalPoint), isTrue,
          reason: 'returned global charRect must contain the tapped point');
    });

    testWidgets('a point outside every row returns null (barrier dismisses)',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'only line')]);
      final VideoSubtitleListHitTester hitTester = VideoSubtitleListHitTester();

      await tester.pumpWidget(_wrap(SizedBox(
        width: 420,
        height: 500,
        child: VideoSubtitleJumpPanel(
          controller: controller,
          onTapCue: (_) {},
          onLookupCue: (AudioCue _, int __, Rect ___) {},
          hitTester: hitTester,
          onClose: () {},
          onCopyCue: (_) {},
          onFavoriteCue: (_) async {},
          isCueFavorited: (_) => false,
          colorScheme: const ColorScheme.dark(),
          title: 'Subtitle list',
          emptyHint: 'empty',
          width: 420,
        ),
      )));
      await tester.pump();

      // 远在所有行之外（负坐标）→ 无命中 → barrier 落回原 dismiss。
      expect(hitTester.hitTest(const Offset(-100, -100)), isNull);
    });

    testWidgets('without onLookupCue no rows register → hitTest is null',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'plain line')]);
      final VideoSubtitleListHitTester hitTester = VideoSubtitleListHitTester();

      await tester.pumpWidget(_wrap(SizedBox(
        width: 420,
        height: 500,
        child: VideoSubtitleJumpPanel(
          controller: controller,
          onTapCue: (_) {},
          // onLookupCue 省略（不可查词）→ 不登记行，句柄命中恒 null。
          hitTester: hitTester,
          onClose: () {},
          onCopyCue: (_) {},
          onFavoriteCue: (_) async {},
          isCueFavorited: (_) => false,
          colorScheme: const ColorScheme.dark(),
          title: 'Subtitle list',
          emptyHint: 'empty',
          width: 420,
        ),
      )));
      await tester.pump();

      final Rect textRect = tester.getRect(find.text('plain line'));
      expect(hitTester.hitTest(textRect.center), isNull,
          reason: 'lookup disabled → no reverse-hit registration');
    });

    testWidgets(
        'BUG-910 exactOnly: on-glyph tap still switches; skirt blank dismisses',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'first line'),
        _cue(1, 2000, 3000, 'second line'),
      ]);
      final VideoSubtitleListHitTester hitTester = VideoSubtitleListHitTester();

      await tester.pumpWidget(_wrap(SizedBox(
        width: 420,
        height: 500,
        child: VideoSubtitleJumpPanel(
          controller: controller,
          onTapCue: (_) {},
          onLookupCue: (AudioCue _, int __, Rect ___) {},
          hitTester: hitTester,
          onClose: () {},
          onCopyCue: (_) {},
          onFavoriteCue: (_) async {},
          isCueFavorited: (_) => false,
          colorScheme: const ColorScheme.dark(),
          title: 'Subtitle list',
          emptyHint: 'empty',
          width: 420,
        ),
      )));
      await tester.pump();

      final ({Offset globalPoint, int graphemeIndex}) target =
          _pointForGrapheme(tester, 'second line', 'c');

      // 点在字形正中：exactOnly 也命中 → barrier 切词（用户要的「点在字上换词」保留）。
      final SubtitleListHit? onGlyph =
          hitTester.hitTest(target.globalPoint, exactOnly: true);
      expect(onGlyph, isNotNull, reason: 'exactOnly：点列表字形正中仍命中→切词');
      expect(onGlyph!.graphemeIndex, target.graphemeIndex);

      // 行首字符左外侧的空白（在默认半字格容差内、在字形盒外的左边距，中间不夹相邻字）：
      // 默认宽容差会兜底命中最近字符（旧行为，点这里被误判成切词）；exactOnly 必须 miss →
      // barrier 落回 dismiss（用户要的「点空白关闭」）。
      final SubtitleListHit? headHit = hitTester
          .hitTest(_pointForGrapheme(tester, 'second line', 's').globalPoint);
      expect(headHit, isNotNull);
      final Rect head = headHit!.charRect;
      final Offset leftSkirt = head.centerLeft - Offset(head.height * 0.4, 0);
      final SubtitleListHit? generous = hitTester.hitTest(leftSkirt);
      // 仅当该布局下左边距确被默认容差兜底命中，才断言 exactOnly 反差（不同 Text 布局下
      // 左边距可能落在行框外→默认也 miss，此时两者都 null 亦是「点空白关闭」正确行为）。
      if (generous != null) {
        expect(hitTester.hitTest(leftSkirt, exactOnly: true), isNull,
            reason: 'BUG-910：行首左侧空白 exactOnly 必 miss → barrier 关闭浮层续播');
      }
    });

    testWidgets('unbinds on panel dispose (hidden sidebar)',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'bye line')]);
      final VideoSubtitleListHitTester hitTester = VideoSubtitleListHitTester();

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onLookupCue: (AudioCue _, int __, Rect ___) {},
        hitTester: hitTester,
        onClose: () {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));
      await tester.pump();

      // 面板从树上移除（侧栏隐藏）→ dispose 解绑 → 句柄不再命中已失效实现。
      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      expect(hitTester.hitTest(Offset.zero), isNull,
          reason: 'disposed panel must unbind so the barrier never calls a '
              'stale hit impl');
    });
  });
}
