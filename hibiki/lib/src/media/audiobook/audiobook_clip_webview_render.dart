import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// TODO-1167：单帧 takeScreenshot 的超时上限，对齐 load 的 8s 语义（截图原来无超时，
/// 卡死会永久挂住整条导出管线 → 表现为卡死/ANR）。
const Duration _kClipScreenshotTimeout = Duration(seconds: 8);

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
    // TODO-1127：把该句后夹带的 EPUB 插图按序注成 data-uri <img> 块（竖排 vertical-rl
    // 流里作块级插图，随阅读顺序排在该句之后）。绝大多数句子 images 为空 → 无输出，
    // 与旧行为逐字节一致。
    for (final Uint8List image in segments[i].images) {
      cueHtml.write('<img class="clip-img" src="${_imageDataUri(image)}">');
    }
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
.clip-img {
  display: block;
  max-width: 92%;
  max-height: 60%;
  margin: 0.4em auto;
  object-fit: contain;
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
Future<void> renderAudiobookClipFramesViaWebView({
  required List<AudiobookClipTextSegment> segments,
  required AudiobookClipTextLayout layout,
  required AudiobookClipFrameSink onFrame,
  List<int>? highlightIndices,
}) async {
  final List<int> indices = highlightIndices ??
      List<int>.generate(segments.length, (int i) => i, growable: false);
  if (indices.isEmpty) return;

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
      // 发一帧 null，让调用方回退单句静态（流式回调下不再返回 List）。
      await onFrame(indices.first, null);
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 120));
    await controller.evaluateJavascript(
      source: 'window.__clipFit && window.__clipFit();',
    );
    await Future<void>.delayed(const Duration(milliseconds: 32));

    for (final int idx in indices) {
      await controller.evaluateJavascript(
        source: 'window.__clipSetActive && window.__clipSetActive($idx);',
      );
      await Future<void>.delayed(const Duration(milliseconds: 48));
      Uint8List? shot;
      try {
        // TODO-1167：takeScreenshot 加超时。load 已有 8s 超时但截图原来没有，单帧
        // takeScreenshot 卡死会永久挂住整条导出管线（native 位图迟迟不回）→ 卡死/ANR。
        // 超时该帧记 null，调用方走单句静态回退，绝不无限等。
        shot =
            await controller.takeScreenshot().timeout(_kClipScreenshotTimeout);
        if (shot == null) {
          ErrorLogService.instance.log(
            'AudiobookClipWebViewRender.screenshotNull',
            'takeScreenshot returned null for vertical clip frame '
                '(highlight=$idx, segments=${segments.length})',
            StackTrace.current,
          );
        }
      } on TimeoutException catch (e, st) {
        ErrorLogService.instance.log(
          'AudiobookClipWebViewRender.screenshotTimeout',
          'takeScreenshot exceeded ${_kClipScreenshotTimeout.inSeconds}s '
              '(highlight=$idx, segments=${segments.length}); frame skipped, '
              'caller falls back to static. $e',
          st,
        );
        shot = null;
      } catch (e, st) {
        ErrorLogService.instance.log(
          'AudiobookClipWebViewRender.screenshotThrew',
          e,
          st,
        );
        shot = null;
      }
      // 流式消费该帧（编码 + 落盘由调用方在后台 isolate 做），随即释放本帧内存。
      final bool keepGoing = await onFrame(idx, shot);
      if (!keepGoing) return;
    }
  } catch (e, st) {
    ErrorLogService.instance.log(
      'AudiobookClipWebViewRender.clipWebViewThrew',
      e,
      st,
    );
    // 发一帧 null 让调用方回退单句静态（流式回调下不再返回 List）。
    try {
      await onFrame(indices.first, null);
    } catch (_) {}
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
  Uint8List? result;
  await renderAudiobookClipFramesViaWebView(
    segments: <AudiobookClipTextSegment>[
      AudiobookClipTextSegment(text: text),
    ],
    layout: layout,
    highlightIndices: <int>[0],
    onFrame: (int highlightIndex, Uint8List? pngBytes) async {
      result = pngBytes;
      return false; // 单句静态图只需一帧。
    },
  );
  return result;
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

/// 把插图字节编码成 data-uri（按魔数区分 PNG/JPEG，其它按 png 兜底——浏览器仍会按真实
/// 字节嗅探解码）。供竖排 WebView 帧把 EPUB 插图内联进 HTML（TODO-1127）。
String _imageDataUri(Uint8List bytes) {
  final String mime = _imageMimeType(bytes);
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

/// 按文件头魔数判断图片 MIME：JPEG（FF D8 FF）/ PNG（89 50 4E 47）/ GIF（47 49 46）/
/// WebP（RIFF....WEBP）；无法识别按 image/png 兜底。
String _imageMimeType(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 4 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return 'image/gif';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/png';
}

String _escapeHtml(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
