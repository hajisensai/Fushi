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
    // 'hello' 拆成逐字符可点；每个字符现在渲染成**双层**（底层 stroke 描边 Text +
    // 上层 fill Text，BUG-321 / TODO-569 真描边），故每个唯一字符出现 2 个 Text，
    // 重复字符 'l'（出现 2 次）共 4 个。默认 shadowThickness=5（非零）→ 描边层存在。
    expect(find.text('h'), findsNWidgets(2));
    expect(find.text('e'), findsNWidgets(2));
    expect(find.text('l'), findsNWidgets(4));

    // 双层重叠，点哪层都命中同一字符矩形；用 .first 避免「matched 2 widgets」。
    await tester.tap(find.text('e').first);
    expect(tappedSentence, 'hello');
    expect(tappedIndex, 1); // 'e' 是第 1 个 grapheme
    // 浮层定位用：被点字符报告非零屏幕矩形（弹窗据此定位到字符附近）。
    expect(tappedRect, isNotNull);
    expect(tappedRect, isNot(Rect.zero));
    expect(tappedRect!.width, greaterThan(0));
    expect(tappedRect!.height, greaterThan(0));

    c.debugUpdateCueForPosition(2500);
    await tester.pump();
    expect(find.text('w'), findsNWidgets(2));
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
      'renders real outline as double-layer stroke+fill Text, no shadow residue (BUG-321)',
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

    // BUG-321 / TODO-569 真描边：字符 'A' 渲染成**两层** Text（底层 stroke 描边 +
    // 上层 fill 正文），故 find.text('A') 命中 2 个。旧的「8 个模糊 Shadow glyph
    // 拷贝伪描边」会在大 thickness/横竖屏缩放下外溢成残留黑字，已彻底移除。
    final List<Text> texts = tester.widgetList<Text>(find.text('A')).toList();
    expect(texts.length, 2, reason: '真描边 = 底层 stroke + 上层 fill 两个 Text');

    // 分辨两层：fill 层有 color、无 foreground、无 shadows；stroke 层 foreground 是
    // PaintingStyle.stroke 画笔、color 为 null、无 shadows。
    final Text fill = texts.firstWhere((Text t) => t.style?.foreground == null);
    final Text stroke =
        texts.firstWhere((Text t) => t.style?.foreground != null);

    // fill 层：正文色、字号、字重、字体如实；**绝无 shadows**（残留黑字源已根除）。
    expect(fill.style!.color, themedSubtitleColor);
    expect(fill.style!.fontSize, 36);
    expect(fill.style!.fontWeight, FontWeight.w500);
    expect(fill.style!.fontFamily, 'ReaderFont');
    expect(fill.style!.shadows, anyOf(isNull, isEmpty),
        reason: '不再用 Shadow 伪描边');

    // stroke 层：foreground 是 stroke 画笔，宽度==thickness、色==shadowColor，
    // 几何（字号/字重/字体）与 fill 层一致（两层逐像素对齐）；同样**无 shadows**。
    final Paint strokePaint = stroke.style!.foreground!;
    expect(strokePaint.style, PaintingStyle.stroke);
    expect(strokePaint.strokeWidth, 6); // strokeWidth == thickness
    // Paint.color round-trip 后实例不严格 ==（colorSpace/浮点表示），比 ARGB32。
    expect(strokePaint.color.toARGB32(), const Color(0xFF224466).toARGB32());
    expect(stroke.style!.color, isNull, reason: 'foreground 与 color 不可共存');
    expect(stroke.style!.fontSize, 36);
    expect(stroke.style!.fontWeight, FontWeight.w500);
    expect(stroke.style!.fontFamily, 'ReaderFont');
    expect(stroke.style!.shadows, anyOf(isNull, isEmpty));
  });

  testWidgets('thickness<=0 renders single fill Text (no stroke layer)',
      (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('A', 0, 1000)]);

    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      shadowColor: const Color(0xFF224466),
      shadowThickness: 0, // 无描边：不应再有第二层 Text。
    )));
    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 无描边 → 单层 fill Text，绝不渲染空描边层（无多余 widget、无残影）。
    final List<Text> texts = tester.widgetList<Text>(find.text('A')).toList();
    expect(texts.length, 1);
    expect(texts.single.style!.foreground, isNull);
    expect(texts.single.style!.shadows, anyOf(isNull, isEmpty));
  });
}
