import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_webview_render.dart';

/// TODO-1147 option A guard: vertical clip frames render via the offscreen
/// WebView true-vertical path (writing-mode: vertical-rl + per-sentence sasayaki
/// highlight), never the old unreadable RotatedBox; screenshots still feed the
/// JPEG image2 ffmpeg pipeline; horizontal keeps the Flutter raster path.
void main() {
  AudiobookClipTextLayout verticalLayout() => computeClipTextLayout(
        textLength: 10,
        baseFontSize: 40,
        vertical: true,
        lineHeight: 1.6,
        background: const Color(0xFF101010),
        foreground: const Color(0xFFF0F0F0),
        // Opaque red so the highlight rgba is deterministic in the HTML.
        highlight: const Color(0xFFFF0000),
      );

  test('buildAudiobookClipVerticalHtml uses reader vertical-rl typography', () {
    final String html = buildAudiobookClipVerticalHtml(
      segments: const <AudiobookClipTextSegment>[
        AudiobookClipTextSegment(text: '第一句'),
        AudiobookClipTextSegment(text: '第二句'),
      ],
      layout: verticalLayout(),
    );
    // True vertical, reused from the reader content styles.
    expect(html.contains('writing-mode: vertical-rl'), isTrue);
    expect(html.contains('text-orientation: mixed'), isTrue);
    // Every sentence is an addressable cue span.
    expect(html.contains('data-index="0"'), isTrue);
    expect(html.contains('data-index="1"'), isTrue);
    expect(html.contains('第一句'), isTrue);
    expect(html.contains('第二句'), isTrue);
    // Per-frame highlight toggling + fit hooks.
    expect(html.contains('__clipSetActive'), isTrue);
    expect(html.contains('__clipFit'), isTrue);
  });

  test('vertical HTML paints the current sentence with the sasayaki highlight',
      () {
    final String html = buildAudiobookClipVerticalHtml(
      segments: const <AudiobookClipTextSegment>[
        AudiobookClipTextSegment(text: 'あ'),
      ],
      layout: verticalLayout(),
    );
    // Highlight class is the sasayaki backing; opaque red => rgba(255,0,0,1.00).
    expect(html.contains('.clip-cue.current'), isTrue);
    expect(html.contains('rgba(255,0,0,1.00)'), isTrue);
  });

  test('vertical HTML escapes sentence text (no raw injection)', () {
    final String html = buildAudiobookClipVerticalHtml(
      segments: const <AudiobookClipTextSegment>[
        AudiobookClipTextSegment(text: '<b>&"x"'),
      ],
      layout: verticalLayout(),
    );
    expect(html.contains('&lt;b&gt;'), isTrue);
    expect(html.contains('<b>'), isFalse);
  });

  test(
      'source guard: renderer uses headless WebView + takeScreenshot, logs '
      'failures (no silent swallow)', () {
    final String code = File(
      'lib/src/media/audiobook/audiobook_clip_webview_render.dart',
    ).readAsStringSync();
    expect(code.contains('HeadlessInAppWebView'), isTrue);
    expect(code.contains('takeScreenshot()'), isTrue);
    expect(code.contains('writing-mode: vertical-rl'), isTrue);
    // Exceptions captured with stack + logged, never a bare swallowing catch.
    expect(code.contains('catch (e, st)'), isTrue);
    expect(code.contains('clipWebViewThrew'), isTrue);
    expect(
      RegExp(r'catch\s*\(\s*_\s*\)\s*\{\s*return null;').hasMatch(code),
      isFalse,
    );
  });

  test(
      'source guard: Flutter clip card no longer rotates vertical (RotatedBox '
      'gone)', () {
    final String code = File(
      'lib/src/media/audiobook/audiobook_clip_text_render.dart',
    ).readAsStringSync();
    expect(code.contains('RotatedBox('), isFalse,
        reason: 'vertical must go through the WebView path, not a 90deg block '
            'rotation (unreadable)');
    expect(code.contains('quarterTurns'), isFalse);
  });

  test(
      'source guard: caller routes vertical to the WebView renderers, '
      'horizontal to Flutter raster, both feed the JPEG pipeline', () {
    final String code = File(
      'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
    ).readAsStringSync();
    // Vertical branch dispatches to the offscreen WebView renderers.
    expect(code.contains('renderAudiobookClipFramesViaWebView'), isTrue);
    expect(code.contains('renderAudiobookClipTextViaWebView'), isTrue);
    // Gated on layout.vertical (horizontal keeps the Flutter raster path).
    expect(code.contains('layout.vertical'), isTrue);
    expect(code.contains('renderAudiobookClipFrames('), isTrue);
    expect(code.contains('renderAudiobookClipTextToPng('), isTrue);
    // Downstream JPEG re-encode pipeline is untouched (BUG-543 contract).
    expect(code.contains('encodeClipTextFrameAsJpg'), isTrue);
  });
}
