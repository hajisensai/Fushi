import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_webview_render.dart';

import '../../helpers/source_guard.dart';

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

  test(
      'vertical HTML paints the current sentence with the sentenceAudioHighlight highlight',
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

  // BUG-808：逐句高亮不得改变盒子占位尺寸，否则 vertical-rl 流里高亮句被撑大、挤动
  // 后续所有句 → 整段文字逐帧重新排版抖动。守卫：基础 `.clip-cue` 常驻 padding，
  // `.current` 只换 background-color、绝不再单独加 padding（与 Flutter 横排路径同原则）。
  test(
      'BUG-808: base .clip-cue carries padding, .current only swaps bg '
      '(no reflow)', () {
    final String html = buildAudiobookClipVerticalHtml(
      segments: const <AudiobookClipTextSegment>[
        AudiobookClipTextSegment(text: 'あ'),
        AudiobookClipTextSegment(text: 'い'),
      ],
      layout: verticalLayout(),
    );
    // 基础 cue 规则常驻 padding（高亮前后盒子恒等）。
    final RegExp baseRule =
        RegExp(r'\.clip-cue\s*\{([^}]*)\}', multiLine: true);
    final Match? base = baseRule.firstMatch(html);
    expect(base, isNotNull, reason: 'base .clip-cue rule must exist');
    expect(base!.group(1)!.contains('padding'), isTrue,
        reason: 'every cue must reserve the same padding up-front');
    // 高亮规则只改 background-color，不含 padding（否则撑大盒子导致 reflow）。
    final RegExp currentRule =
        RegExp(r'\.clip-cue\.current\s*\{([^}]*)\}', multiLine: true);
    final Match? current = currentRule.firstMatch(html);
    expect(current, isNotNull);
    expect(current!.group(1)!.contains('padding'), isFalse,
        reason:
            'highlight must not add padding (would reflow vertical-rl flow)');
    expect(current.group(1)!.contains('background-color'), isTrue);
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

  // BUG-809/BUG-1322/TODO-2357：两端容器统一 .mp4，且输出容器跟着编码器走、不得硬编
  // 回 .mov（那是 mjpeg 时代的产物）。
  test('BUG-809/TODO-2357: output container is .mp4, never .mov', () {
    final String code = File(
      'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
    ).readAsStringSync();
    expect(code.contains("videoExt = 'mp4'"), isTrue);
    expect(code.contains("'mov'"), isFalse,
        reason: 'output must be .mp4, never MJPEG/.mov again');
    expect(code.contains(r"File('$base.$videoExt')"), isTrue);
    expect(code.contains(r"File('$base.mov')"), isFalse,
        reason: 'output container must follow the codec, not hardcode .mov');
  });

  // TODO-2357 契约反转：移动端 ffmpeg-kit 重编入 libx264 后，编码器**不再有平台分支**。
  //
  // 历史：这里原本钉的是 `useH264 = isDesktop`——因为移动端当时没有 libx264，谁把它改成
  // 常量 true，移动端真机就会 Unknown encoder。PR#607 审查的变异实测正是靠这条抓洞的。
  // 现在两端同一个编码器，那条判据不再成立，取而代之的是**禁止型**守卫：任何形式的
  // 「按平台选编码器」重新出现都必须当场红。这不是放松，是把约束挪到了新的正确位置——
  // 旧约束（移动端不许用 libx264）如今是错的，留着会阻止正确实现。
  test('TODO-2357: 编码器无平台分支，参数表是单一常量', () {
    final String src = File(
      'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final String body =
        methodBody(src, 'Future<void> _runAudiobookClipPipeline({');

    // 编码器开关及其透传必须彻底消失。
    expect(RegExp(r'\buseH264\b').hasMatch(body), isFalse,
        reason: 'TODO-2357：编码器平台开关已消除，重新出现即说明分支被加回来了');
    expect(RegExp(r'\bh264\s*:').hasMatch(body), isFalse,
        reason: '合成参数表不再接受 h264 开关，透传实参必须一并删除');

    // isDesktop 仍存在，但只准用于产物落盘/清理，不得再参与编码器选择。
    final RegExp isDesktopDecl = RegExp(r'\bbool\s+isDesktop\s*=\s*([^;]+);');
    final List<RegExpMatch> desktop = isDesktopDecl.allMatches(body).toList();
    expect(desktop, hasLength(1), reason: '导出管线里 isDesktop 必须有且只有一处声明');
    final String desktopRhs = desktop.single.group(1)!;
    for (final String platform in <String>[
      'Platform.isWindows',
      'Platform.isMacOS',
      'Platform.isLinux',
    ]) {
      expect(desktopRhs, contains(platform),
          reason: 'isDesktop 必须由真实平台判据推出（它仍决定存盘 vs 系统分享）');
    }

    // 参数表本体：必须是单一常量列表，且不含任何条件分支。
    final String exportSrc =
        File('lib/src/media/audiobook/audiobook_clip_export.dart')
            .readAsStringSync()
            .replaceAll('\r\n', '\n');
    expect(
      exportSrc.contains('const List<String> _clipVideoCodecArgs = <String>['),
      isTrue,
      reason: '编码器参数表必须是单一 const 列表——一旦退回带参函数，'
          '平台分支就有地方藏了',
    );
    expect(exportSrc.contains("'mpeg4'"), isFalse,
        reason: 'mpeg4 规格上限低于 1080×1920，会静默产出解不了的文件，不得回流');
  });
}
