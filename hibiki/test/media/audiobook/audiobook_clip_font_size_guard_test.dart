import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_webview_render.dart';

/// TODO-1282 守卫：书籍（EPUB）片段导出的文本必须像书页那样大字，而不是 SRT 字幕小条，
/// 且竖排走的是复用阅读器 EPUB 排版（vertical-rl + 明朝体 + 主题色）的渲染路径，不是
/// 任何 SRT 字幕路径。
///
/// 根因（[computeClipTextLayout]）：旧「12 字反比缩、18px 地板」让一句普通日文正文在
/// 1080/1920 画布上塌到 ~18px 字幕大小。改为按可用画布面积自适应铺满，下限跟随 EPUB
/// 正文字号。这里锁死「典型单句 → 书页大字」「reader 字号越大导出越大」两条不变量，
/// 以及竖排 HTML 走 EPUB 排版路径。
void main() {
  const Color bg = Color(0xFF101010);
  const Color fg = Color(0xFFF0F0F0);
  const Color highlight = Color(0x66FFCC00);

  group('TODO-1282 clip font size (book-sized, not SRT subtitle-sized)', () {
    test('typical single Japanese sentence renders book-sized font, not tiny',
        () {
      // 典型单句（30 runes），默认阅读正文字号 22。
      final AudiobookClipTextLayout horizontal = computeClipTextLayout(
        textLength: 30,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      final AudiobookClipTextLayout vertical = computeClipTextLayout(
        textLength: 30,
        baseFontSize: 22,
        vertical: true,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      // 旧路径这句会塌到 18px（字幕大小）。修复后必须远大于旧上限（base×2=44）。
      expect(horizontal.fontSize, greaterThan(60),
          reason: 'book clip must be big, not subtitle-tiny');
      expect(vertical.fontSize, greaterThan(60),
          reason: 'vertical book clip must be big too');
    });

    test(
        'font floor scales with EPUB reader font (bigger reader -> bigger clip)',
        () {
      // 长选区（200 runes）落到面积解出的字号 < 下限区，此时下限（跟随 EPUB base）决定
      // 结果：reader 字号越大，导出字号越大 -> 证明「真按 EPUB 生成」。
      final AudiobookClipTextLayout small = computeClipTextLayout(
        textLength: 200,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.6,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      final AudiobookClipTextLayout big = computeClipTextLayout(
        textLength: 200,
        baseFontSize: 48,
        vertical: false,
        lineHeight: 1.6,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      expect(big.fontSize, greaterThan(small.fontSize),
          reason: 'clip font must follow EPUB reader font size');
    });

    test('longer selections shrink but never collapse below the book floor',
        () {
      final AudiobookClipTextLayout shortSel = computeClipTextLayout(
        textLength: 6,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      final AudiobookClipTextLayout longSel = computeClipTextLayout(
        textLength: 220,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      expect(longSel.fontSize, lessThan(shortSel.fontSize));
      // 书页地板：远高于旧 18px 字幕地板。
      expect(longSel.fontSize, greaterThanOrEqualTo(32),
          reason: 'never collapse to subtitle size');
    });
  });

  group('TODO-1282 vertical clip renders via EPUB typography path (not SRT)',
      () {
    test('vertical HTML reuses reader vertical-rl EPUB styling + theme + size',
        () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 20,
        baseFontSize: 22,
        vertical: true,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      final String html = buildAudiobookClipVerticalHtml(
        segments: const <AudiobookClipTextSegment>[
          AudiobookClipTextSegment(text: 'しょうがくせいのころ、'),
        ],
        layout: layout,
      );
      // EPUB 阅读排版：竖排 vertical-rl + text-orientation: mixed + 明朝/黑体日文字体。
      expect(html, contains('writing-mode: vertical-rl'));
      expect(html, contains('text-orientation: mixed'));
      expect(html, contains('Noto Serif JP'));
      // 字号必须是 layout 算出的书页大字，原样注入 CSS（不是硬编码小字）。
      final int fs = layout.fontSize.round();
      expect(html, contains('font-size: ${fs}px'),
          reason: 'vertical clip must render at the computed book font size');
      // 逐句高亮跟随衬底（sasayaki）——EPUB 有声书跟读观感，非字幕条。
      expect(html, contains('.clip-cue.current'));
      // 绝不走任何 SRT 字幕路径。
      expect(html.toLowerCase(), isNot(contains('srt')));
    });
  });
}
