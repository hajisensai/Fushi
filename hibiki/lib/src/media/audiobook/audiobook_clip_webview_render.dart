import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// TODO-1147 option A: true-vertical offscreen render path for clip export.
///
/// Flutter cannot lay out CJK vertical text, so [renderAudiobookClipFrames]'s
/// vertical branch could only RotatedBox the whole block 90deg (unreadable).
/// Option A renders vertical frames via an offscreen HeadlessInAppWebView reusing
/// the reader's proven writing-mode: vertical-rl typography + per-sentence
/// sasayaki highlight backing. Vertical only; horizontal keeps the Flutter
/// raster path untouched (never break). Screenshots go PNG then
/// encodeClipTextFrameAsJpg then image2 ffmpeg (downstream unchanged). ffmpeg
/// scale+pad handles DPR/aspect.
String buildAudiobookClipVerticalHtml({
  required List<AudiobookClipTextSegment> segments,
  required AudiobookClipTextLayout layout,
}) {
  final String bg = _clipColorToCssRgba(layout.background);
  final String fg = _clipColorToCssRgba(layout.foreground);
  final String highlight = _clipColorToCssRgba(layout.highlight);
  final String fontSize = _num(layout.fontSize);
  final String lineHeight = _num(layout.lineHeight);
  final String padding = _num(layout.padding);

  final StringBuffer cueHtml = StringBuffer();
  for (int i = 0; i < segments.length; i++) {
    cueHtml.write(
      '<span class="clip-cue" data-index="$i">'
      '${_escapeHtml(segments[i].text)}</span>',
    );
  }

  return _kClipHtmlHead
      .replaceAll(r'$BG', bg)
      .replaceAll(r'$FG', fg)
      .replaceAll(r'$HIGHLIGHT', highlight)
      .replaceAll(r'$FONTSIZE', fontSize)
      .replaceAll(r'$LINEHEIGHT', lineHeight)
      .replaceAll(r'$PADDING', padding)
      .replaceAll(r'$CUES', cueHtml.toString());
}

/// Static clip HTML template. Placeholders ($BG/$FG/$HIGHLIGHT/$FONTSIZE/
/// $LINEHEIGHT/$PADDING/$CUES) are substituted by buildAudiobookClipVerticalHtml.
/// Reuses the reader's vertical-rl + text-orientation: mixed typography and a
/// per-sentence sasayaki highlight backing (.clip-cue.current).
const String _kClipHtmlHead = r'''
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: 100%; height: 100%; background: $BG; overflow: hidden; }
body {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: $PADDINGpx;
  font-family: "Noto Serif JP", "Noto Sans JP", "Hiragino Mincho ProN", serif;
}
#clip {
  writing-mode: vertical-rl;
  text-orientation: mixed;
  max-width: 100%;
  max-height: 100%;
  overflow: hidden;
  color: $FG;
  font-size: $FONTSIZEpx;
  line-height: $LINEHEIGHT;
  font-weight: 700;
  text-align: start;
}
.clip-cue.current {
  background-color: $HIGHLIGHT;
  border-radius: 0.18em;
  padding: 0.08em 0.12em;
}
</style>
</head>
<body>
<div id="clip">$CUES</div>
<script>
var __clipCurrent = -1;
var __clipCues = document.querySelectorAll(".clip-cue");
window.__clipSetActive = function(i) {
  if (__clipCurrent >= 0 && __clipCurrent < __clipCues.length) {
    __clipCues[__clipCurrent].classList.remove("current");
  }
  __clipCurrent = i;
  if (i >= 0 && i < __clipCues.length) {
    __clipCues[i].classList.add("current");
  }
};
window.__clipFit = function() {
  var el = document.getElementById("clip");
  if (!el) return;
  var base = parseFloat(getComputedStyle(el).fontSize) || 24;
  var min = 12;
  var size = base;
  var guard = 0;
  while (guard < 40 && size > min &&
      (el.scrollWidth > el.clientWidth || el.scrollHeight > el.clientHeight)) {
    size = Math.max(min, size * 0.94);
    el.style.fontSize = size + "px";
    guard++;
  }
};
</script>
</body>
</html>
''';

/// True-vertical offscreen render: lay the whole multi-sentence text out with a
/// headless WebView and screenshot one PNG per [highlightIndices] entry (frame i
/// highlights sentence i). Loads HTML once; per frame only toggles the active
/// sentence via JS then takeScreenshot (faster + steadier than reopening).
///
/// Same contract as [renderAudiobookClipFrames] (null per failed frame). Vertical
/// only; horizontal keeps [renderAudiobookClipFrames].
Future<List<Uint8List?>> renderAudiobookClipFramesViaWebView({
  required List<AudiobookClipTextSegment> segments,
  required AudiobookClipTextLayout layout,
  List<int>? highlightIndices,
}) async {
  final List<int> indices = highlightIndices ??
      List<int>.generate(segments.length, (int i) => i, growable: false);
  if (indices.isEmpty) return <Uint8List?>[];

  final String html = buildAudiobookClipVerticalHtml(
    segments: segments,
    layout: layout,
  );
  final Size size = Size(layout.width.toDouble(), layout.height.toDouble());
  final Completer<void> loaded = Completer<void>();
  HeadlessInAppWebView? headless;

  try {
    headless = HeadlessInAppWebView(
      initialSize: size,
      initialData: InAppWebViewInitialData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri('https://hoshi.local/clip'),
      ),
      initialSettings: InAppWebViewSettings(
        transparentBackground: false,
        supportZoom: false,
        disableVerticalScroll: true,
        disableHorizontalScroll: true,
        disableContextMenu: true,
      ),
      onLoadStop: (InAppWebViewController controller, WebUri? url) {
        if (!loaded.isCompleted) loaded.complete();
      },
    );
    await headless.run();

    var gotLoad = true;
    await loaded.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        gotLoad = false;
      },
    );
    if (!gotLoad) {
      ErrorLogService.instance.log(
        'AudiobookClipWebViewRender.loadTimeout',
        'offscreen vertical clip WebView never reported onLoadStop within 8s (segments=${segments.length})',
        StackTrace.current,
      );
    }

    try {
      await headless.setSize(size);
    } catch (_) {
      // setSize non-fatal: initialSize is the primary size.
    }

    final InAppWebViewController? controller = headless.webViewController;
    if (controller == null) {
      ErrorLogService.instance.log(
        'AudiobookClipWebViewRender.noController',
        'headless webViewController null after run (segments=${segments.length})',
        StackTrace.current,
      );
      return List<Uint8List?>.filled(indices.length, null);
    }

    await Future<void>.delayed(const Duration(milliseconds: 120));
    await controller.evaluateJavascript(
      source: 'window.__clipFit && window.__clipFit();',
    );
    await Future<void>.delayed(const Duration(milliseconds: 32));

    final List<Uint8List?> out = <Uint8List?>[];
    for (final int idx in indices) {
      await controller.evaluateJavascript(
        source: 'window.__clipSetActive && window.__clipSetActive($idx);',
      );
      await Future<void>.delayed(const Duration(milliseconds: 48));
      Uint8List? shot;
      try {
        shot = await controller.takeScreenshot();
      } catch (e, st) {
        ErrorLogService.instance.log(
          'AudiobookClipWebViewRender.screenshotThrew',
          e,
          st,
        );
        shot = null;
      }
      if (shot == null) {
        ErrorLogService.instance.log(
          'AudiobookClipWebViewRender.screenshotNull',
          'takeScreenshot returned null for vertical clip frame (highlight=$idx, segments=${segments.length})',
          StackTrace.current,
        );
      }
      out.add(shot);
    }
    return out;
  } catch (e, st) {
    ErrorLogService.instance.log(
      'AudiobookClipWebViewRender.clipWebViewThrew',
      e,
      st,
    );
    return List<Uint8List?>.filled(indices.length, null);
  } finally {
    try {
      await headless?.dispose();
    } catch (e) {
      debugPrint('[AudiobookClipWebViewRender] headless dispose failed: $e');
    }
  }
}

/// Vertical single-sentence static image: whole text as one highlighted
/// sentence. Reuses [renderAudiobookClipFramesViaWebView].
Future<Uint8List?> renderAudiobookClipTextViaWebView({
  required String text,
  required AudiobookClipTextLayout layout,
}) async {
  final List<Uint8List?> frames = await renderAudiobookClipFramesViaWebView(
    segments: <AudiobookClipTextSegment>[
      AudiobookClipTextSegment(text: text),
    ],
    layout: layout,
    highlightIndices: <int>[0],
  );
  return frames.isNotEmpty ? frames.first : null;
}

/// Color to rgba(r,g,b,a) CSS string, mirroring reader readerColorToCssRgba
/// (channel (c*255).round().clamp(0,255), alpha 2 decimals) without pulling the
/// giant reader page in for a 3-line helper.
String _clipColorToCssRgba(Color c) {
  final int r = (c.r * 255.0).round().clamp(0, 255);
  final int g = (c.g * 255.0).round().clamp(0, 255);
  final int b = (c.b * 255.0).round().clamp(0, 255);
  return 'rgba($r,$g,$b,${c.a.toStringAsFixed(2)})';
}

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

String _escapeHtml(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
