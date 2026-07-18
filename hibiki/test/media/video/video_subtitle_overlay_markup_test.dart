import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';

VideoPlayerController _stubWithCue(AudioCue cue) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[cue]);
  c.debugUpdateCueForPosition(cue.startMs + 1); // 命中该 cue
  return c;
}

AudioCue _cue(String raw, {int start = 0, int end = 5000}) {
  final SubtitleMarkup m = parseSubtitleMarkup(raw);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = m.plainText
    ..markup = m
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0;
}

void main() {
  testWidgets('an8 anchor aligns subtitle to top + lookup keeps plain text',
      (WidgetTester tester) async {
    final VideoPlayerController c = _stubWithCue(_cue(r'{\an8}トップ'));
    String? tappedSentence;
    int? tappedIndex;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect r) {
            tappedSentence = s;
            tappedIndex = i;
          },
        ),
      ),
    ));
    await tester.pump();

    // 顶部锚点：字幕盒落在 overlay 上半部。
    final Rect overlayRect = tester.getRect(find.byType(VideoSubtitleOverlay));
    // 默认统一外观：每字单层 Text（Niratan 软投影），取 .first 兼容有无描边。
    final Offset boxCenter = tester.getCenter(find.text('プ').first);
    expect(boxCenter.dy, lessThan(overlayRect.center.dy));

    // 逐字查词仍传纯文本 + 正确 grapheme 索引。
    await tester.tapAt(tester.getCenter(find.text('ト').first));
    expect(tappedSentence, 'トップ');
    expect(tappedIndex, 0);
  });

  testWidgets('italic span renders italic; sibling stays upright',
      (WidgetTester tester) async {
    final VideoPlayerController c = _stubWithCue(_cue(r'{\i1}A{\i0}B'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VideoSubtitleOverlay(controller: c)),
    ));
    await tester.pump();
    // 取填充层（foreground==null）断言样式：默认单层即该层，ASS 尊重路径为双层的 fill 层。
    final Text a = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    final Text b = tester
        .widgetList<Text>(find.text('B'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(a.style?.fontStyle, FontStyle.italic);
    expect(b.style?.fontStyle, isNot(FontStyle.italic));
  });

  testWidgets('no markup falls back to bottom-center (backward compatible)',
      (WidgetTester tester) async {
    final AudioCue plain = AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = '[data-cue-id="0"]'
      ..text = 'そこ'
      ..startMs = 0
      ..endMs = 5000
      ..audioFileIndex = 0; // markup 为 null
    final VideoPlayerController c = _stubWithCue(plain);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VideoSubtitleOverlay(controller: c)),
    ));
    await tester.pump();
    final Rect overlayRect = tester.getRect(find.byType(VideoSubtitleOverlay));
    // 默认单层 Text，取 .first 兼容有无描边。
    final Offset boxCenter = tester.getCenter(find.text('そ').first);
    expect(boxCenter.dy, greaterThan(overlayRect.center.dy)); // 底部
  });
  testWidgets(
      'respectAssStyle ON: inline c/fn/3c apply; OFF: unified style wins',
      (WidgetTester tester) async {
    // Cue with inline primary color (red \c), font (\fnArial) and outline blue (\3c).
    AudioCue buildCue() => _cue(r'{\c&H0000FF&\fnArial\3c&HFF0000&}A');

    // OFF: fill color follows widget.textColor; \fn/\3c NOT applied (font stays null).
    final VideoPlayerController cOff = _stubWithCue(buildCue());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: cOff,
          textColor: const Color(0xFF112233),
          fontFamily: 'UnifiedFont',
          respectAssStyle: false,
        ),
      ),
    ));
    await tester.pump();
    // Fill layer: foreground == null (default single layer; ASS-respect is dual).
    Text fillOff = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    // Inline \c red is a legacy span style -> applies even when off.
    expect(fillOff.style?.color, const Color(0xFFFF0000));
    // \fn is gated by respectAssStyle -> off keeps unified font family.
    expect(fillOff.style?.fontFamily, 'UnifiedFont');

    // ON: \fn applies (Arial), \c red still applies.
    final VideoPlayerController cOn = _stubWithCue(buildCue());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: cOn,
          textColor: const Color(0xFF112233),
          fontFamily: 'UnifiedFont',
          shadowColor: const Color(0xFF000000),
          shadowThickness: 5,
          respectAssStyle: true,
        ),
      ),
    ));
    await tester.pump();
    Text fillOn = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(fillOn.style?.color, const Color(0xFFFF0000)); // inline \c red
    expect(fillOn.style?.fontFamily, 'Arial'); // \fn respected

    // Stroke layer uses ASS outline color \3c blue when respectAssStyle on.
    final Text strokeOn = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground != null);
    expect(strokeOn.style?.foreground?.color, const Color(0xFF0000FF));
  });

  testWidgets('respectAssStyle ON: cueStyle default font/color/outline applied',
      (WidgetTester tester) async {
    // No inline overrides; style comes from V4+ Styles (cueStyle).
    const SubtitleMarkup markup = SubtitleMarkup(
      plainText: 'B',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(
        fontName: 'CueFont',
        primaryColorArgb: 0xFF00FF00, // green
        outlineColorArgb: 0xFF0000FF, // blue
        outlineWidthPx: 4,
      ),
    );
    final AudioCue cue = AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = '[data-cue-id="0"]'
      ..text = 'B'
      ..markup = markup
      ..startMs = 0
      ..endMs = 5000
      ..audioFileIndex = 0;
    final VideoPlayerController c = _stubWithCue(cue);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          textColor: const Color(0xFF112233),
          fontFamily: 'UnifiedFont',
          shadowColor: const Color(0xFF000000),
          shadowThickness: 5,
          respectAssStyle: true,
        ),
      ),
    ));
    await tester.pump();
    final Text fill = tester
        .widgetList<Text>(find.text('B'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(fill.style?.color, const Color(0xFF00FF00)); // cueStyle primary
    expect(fill.style?.fontFamily, 'CueFont'); // cueStyle font
    final Text stroke = tester
        .widgetList<Text>(find.text('B'))
        .firstWhere((Text t) => t.style?.foreground != null);
    expect(stroke.style?.foreground?.color, const Color(0xFF0000FF)); // outline
  });
  // ---- TODO-1246: ASS 字号缩放 / 字重(bold) / 阴影(shadow) 映射到 overlay 渲染 ----
  AudioCue cueFromMarkup(SubtitleMarkup m) => AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = m.plainText
    ..markup = m
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;

  Future<void> pumpOverlay(
    WidgetTester tester,
    AudioCue cue, {
    required bool respect,
    double width = 640,
    double height = 360,
    int fontWeight = 400,
  }) async {
    final VideoPlayerController c = _stubWithCue(cue);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: VideoSubtitleOverlay(
              controller: c,
              textColor: const Color(0xFFFFFFFF),
              fontSize: 36,
              fontWeight: fontWeight,
              shadowColor: const Color(0xFF000000),
              shadowThickness: 5,
              respectAssStyle: respect,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  // 填充层 foreground==null；描边层 foreground!=null（BUG-323/TODO-569 双层）。
  Text fillOf(WidgetTester tester, String ch) => tester
      .widgetList<Text>(find.text(ch))
      .firstWhere((Text t) => t.style?.foreground == null);
  Text strokeOf(WidgetTester tester, String ch) => tester
      .widgetList<Text>(find.text(ch))
      .firstWhere((Text t) => t.style?.foreground != null);

  testWidgets(
      'respectAssStyle ON: cueStyle Shadow depth + BackColour -> TextStyle.shadows '
      'on bottom stroke layer, cleared on fill (TODO-1246)',
      (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'S',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(shadowDepthPx: 3, shadowColorArgb: 0xFF112233),
    ));
    await pumpOverlay(tester, cue, respect: true);
    final Text stroke = strokeOf(tester, 'S');
    expect(stroke.style?.shadows, isNotNull);
    expect(stroke.style!.shadows!.single.color, const Color(0xFF112233));
    expect(stroke.style!.shadows!.single.offset, const Offset(3, 3));
    final Text fill = fillOf(tester, 'S');
    expect(fill.style?.shadows ?? const <Shadow>[], isEmpty);
  });

  testWidgets(
      'respectAssStyle OFF: ASS Shadow ignored, default soft drop shadow applied '
      'instead (TODO-1246 / Niratan)', (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'S',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(shadowDepthPx: 3, shadowColorArgb: 0xFF112233),
    ));
    await pumpOverlay(tester, cue, respect: false);
    // 关时单层 fill（无描边层）；.ass 的 \shad 硬投影（(3,3)、色 0xFF112233）被忽略，
    // 改挂用户默认柔和投影（(0,1)、色=统一 shadowColor、模糊=统一 shadowThickness）。
    expect(find.text('S'), findsOneWidget);
    final List<Shadow> shadows =
        fillOf(tester, 'S').style?.shadows ?? const <Shadow>[];
    expect(shadows.length, 1, reason: '默认柔和投影单枚，非 ASS 硬投影');
    expect(shadows.single.offset, const Offset(0, 1));
    expect(shadows.single.color,
        const Color(0xFF000000)); // pumpOverlay shadowColor
    expect(shadows.single.blurRadius, 5); // pumpOverlay shadowThickness
  });

  testWidgets(
      'respectAssStyle ON: inline span shadow overrides cueStyle shadow (TODO-1246)',
      (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'S',
      spans: <SubtitleSpan>[
        SubtitleSpan(
          startGrapheme: 0,
          endGrapheme: 1,
          shadowDepthPx: 4,
          shadowColorArgb: 0xFF445566,
        ),
      ],
      cueStyle: SubtitleCueStyle(shadowDepthPx: 1, shadowColorArgb: 0xFF112233),
    ));
    await pumpOverlay(tester, cue, respect: true);
    final Text stroke = strokeOf(tester, 'S');
    expect(stroke.style!.shadows!.single.color, const Color(0xFF445566));
    expect(stroke.style!.shadows!.single.offset, const Offset(4, 4));
  });

  testWidgets(
      'respectAssStyle ON: cueStyle Bold -> FontWeight.bold over lighter user weight '
      '(TODO-1246)', (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'B',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(bold: true),
    ));
    await pumpOverlay(tester, cue, respect: true, fontWeight: 400);
    expect(fillOf(tester, 'B').style?.fontWeight, FontWeight.bold);
  });

  testWidgets(
      'respectAssStyle OFF: cueStyle Bold ignored, user weight wins (TODO-1246)',
      (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'B',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(bold: true),
    ));
    await pumpOverlay(tester, cue, respect: false, fontWeight: 400);
    expect(fillOf(tester, 'B').style?.fontWeight, FontWeight.w400);
  });

  testWidgets(
      'respectAssStyle ON: ASS font size scales by displayHeight / PlayResY '
      '(48 @ PlayResY 720 in 360px area -> 24) (TODO-1246)',
      (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'X',
      spans: <SubtitleSpan>[
        SubtitleSpan(startGrapheme: 0, endGrapheme: 1, fontSizePx: 48),
      ],
      playResY: 720,
    ));
    await pumpOverlay(tester, cue, respect: true, height: 360);
    expect(fillOf(tester, 'X').style?.fontSize, 24.0);
  });

  testWidgets(
      'respectAssStyle ON but no PlayResY: ASS font size used raw '
      '(backward compatible) (TODO-1246)', (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'X',
      spans: <SubtitleSpan>[
        SubtitleSpan(startGrapheme: 0, endGrapheme: 1, fontSizePx: 48),
      ],
    ));
    await pumpOverlay(tester, cue, respect: true, height: 360);
    expect(fillOf(tester, 'X').style?.fontSize, 48.0);
  });

  // ---- TODO-1246: ASS 描边宽（Outline/\bord）同字号按 显示区高/PlayResY 缩放 ----
  // 根因：BUG-604 只缩放了字号，描边宽仍按裸 PlayRes 像素渲染 → 小屏上描边相对已缩放字号
  // 偏粗，anime .ass（ScaledBorderAndShadow: yes、PlayResY=1080）设计的细描边被渲染成过重黑边，
  // 「尊重自带样式」名不副实。守卫：ASS 描边宽随字号同源缩放；无 PlayResY 退回裸值；关时用统一宽。
  testWidgets(
      'respectAssStyle ON: ASS outline width scales by displayHeight / PlayResY '
      '(4 @ PlayResY 720 in 360px area -> 2) (TODO-1246)',
      (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'X',
      spans: <SubtitleSpan>[],
      cueStyle:
          SubtitleCueStyle(outlineColorArgb: 0xFF0000FF, outlineWidthPx: 4),
      playResY: 720,
    ));
    await pumpOverlay(tester, cue, respect: true, height: 360);
    final Text stroke = strokeOf(tester, 'X');
    // BUG-891：半径 4×360/720=2 → 居中 strokeWidth ×2 = 4（可见描边=半径，对齐 mpv）。
    expect(stroke.style?.foreground?.strokeWidth, 4.0); // (4 * 360/720) * 2
    expect(stroke.style?.foreground?.color, const Color(0xFF0000FF));
  });

  testWidgets(
      'respectAssStyle ON but no PlayResY: ASS outline width used raw '
      '(backward compatible) (TODO-1246)', (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'X',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(outlineWidthPx: 4),
    ));
    await pumpOverlay(tester, cue, respect: true, height: 360);
    // BUG-891：裸半径 4 → 居中 strokeWidth ×2 = 8（无 PlayResY 不缩放，仅 ×2 换算）。
    expect(strokeOf(tester, 'X').style?.foreground?.strokeWidth, 8.0);
  });

  testWidgets(
      'respectAssStyle OFF: default soft shadow uses unified shadowThickness, ASS '
      'Outline ignored (TODO-1246 / Niratan)', (WidgetTester tester) async {
    final AudioCue cue = cueFromMarkup(const SubtitleMarkup(
      plainText: 'X',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(outlineWidthPx: 4),
      playResY: 720,
    ));
    await pumpOverlay(tester, cue, respect: false, height: 360);
    // 关时无描边层，走默认柔和投影：模糊半径 = 统一 shadowThickness 5，不吃 ASS 的 \bord 4。
    expect(find.text('X'), findsOneWidget);
    final List<Shadow> shadows =
        fillOf(tester, 'X').style?.shadows ?? const <Shadow>[];
    expect(shadows.single.blurRadius, 5.0);
    expect(shadows.single.offset, const Offset(0, 1));
  });

  // ---- TODO-1373: \blur 辉光 / \fad 淡入淡出 渲染门控 ----
  testWidgets(r'respectAssStyle ON: \blur wraps glyph in ImageFiltered (glow)',
      (WidgetTester tester) async {
    final VideoPlayerController c = _stubWithCue(_cue(r'{\blur5}あ'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ));
    await tester.pump();
    // 无 PlayResY → _assFontScale=1 → sigma=5×0.8493≈4.25>0 → 该字符包一层高斯 ImageFiltered。
    expect(find.byType(ImageFiltered), findsWidgets);
  });

  // ASS `\blur` → 高斯 sigma 换算须带 libass 的 `2/sqrt(ln256)`≈0.8493 因子（对齐 mpv），
  // 不能把 `\blur` 值直接当 sigma（会比 mpv 明显偏糊 ~1.18×）。锁死纯函数换算。
  test(r'assBlurValueToSigma applies libass 2/sqrt(ln256) factor (mpv parity)',
      () {
    expect(kLibassBlurRadiusScale, closeTo(0.8493, 0.0005));
    // \blur5，无缩放（scale=1）：libass 有效 sigma = 5×0.8493 ≈ 4.247，而非旧的 5。
    expect(assBlurValueToSigma(5, 1), closeTo(5 * 0.8493218, 0.001));
    expect(assBlurValueToSigma(5, 1), lessThan(5.0),
        reason: '必须比裸 \\blur 值小（带 libass 因子），否则比 mpv 偏糊');
    // \blur4 @ 2× 缩放（1080p 脚本渲染到 2160）：4×2×0.8493 ≈ 6.79，而非旧的 8。
    expect(assBlurValueToSigma(4, 2), closeTo(4 * 2 * 0.8493218, 0.001));
    expect(assBlurValueToSigma(4, 2), lessThan(8.0));
    // 边界：0 → 0；超大值夹到 24。
    expect(assBlurValueToSigma(0, 3), 0);
    expect(assBlurValueToSigma(100, 3), 24);
  });

  testWidgets(r'respectAssStyle OFF: \blur ignored (no ImageFiltered)',
      (WidgetTester tester) async {
    // blurEnabled 默认 false → 无听力沉浸 ImageFiltered；故有无 ImageFiltered 仅取决于 \blur。
    final VideoPlayerController c = _stubWithCue(_cue(r'{\blur5}あ'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: false),
      ),
    ));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets(r'respectAssStyle ON: \blur keeps per-char lookup working',
      (WidgetTester tester) async {
    String? tapped;
    int? idx;
    final VideoPlayerController c = _stubWithCue(_cue(r'{\blur5}あい'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          respectAssStyle: true,
          onCharTap: (String s, int i, Rect r) {
            tapped = s;
            idx = i;
          },
        ),
      ),
    ));
    await tester.pump();
    // ImageFiltered 不改布局尺寸 → 命中矩形不变 → 逐字查词照常。
    await tester.tapAt(tester.getCenter(find.text('い').first));
    expect(tapped, 'あい');
    expect(idx, 1);
  });

  testWidgets(
      r'respectAssStyle ON: \fad fades cue opacity by playback position',
      (WidgetTester tester) async {
    final AudioCue cue = _cue(r'{\fad(160,160)}う', start: 1000, end: 5000);
    final VideoPlayerController c = _stubWithCue(cue);
    // 80ms into a 160ms fade-in → opacity 0.5.
    c.debugSetPositionForTesting(1080);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ));
    await tester.pump();
    final Iterable<Opacity> ops =
        tester.widgetList<Opacity>(find.byType(Opacity));
    expect(ops.any((Opacity o) => (o.opacity - 0.5).abs() < 1e-6), isTrue,
        reason: 'fade-in at 80/160ms should be ~0.5');
  });

  testWidgets(r'respectAssStyle OFF: \fad ignored (no partial opacity)',
      (WidgetTester tester) async {
    final AudioCue cue = _cue(r'{\fad(160,160)}う', start: 1000, end: 5000);
    final VideoPlayerController c = _stubWithCue(cue);
    c.debugSetPositionForTesting(1080);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: false),
      ),
    ));
    await tester.pump();
    // 关时不包 fade Opacity：不存在 opacity<1 的 Opacity（历史外观）。
    final Iterable<Opacity> ops =
        tester.widgetList<Opacity>(find.byType(Opacity));
    expect(ops.every((Opacity o) => o.opacity >= 1.0), isTrue);
  });
}
