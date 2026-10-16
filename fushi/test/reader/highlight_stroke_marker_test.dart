@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/highlight_stroke_style.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// 高亮条笔触样式（用户 2026-10-15「高亮条自定义做成配置，用户自己可自选样式」「全部高亮都要
/// 能选可以自定义高亮」）。
///
/// 真 Chrome 跑生产 CSS（收藏 = 马克笔、查词 = 荧光笔、有声书 = 手绘、搜索 = 胶带）+ 引擎 shell
/// （分页 / 连续 / VN）× 横竖排：四类高亮都不画 1em 窄条而画 SVG 笔划，笔划盖住文字、约一个
/// 字高；「盖住振假名」关时不碰注音、开时盖上去；收藏笔触下没有下划线；重画逐字相同（翻页不
/// 抖）；六种样式都画得出；新收藏只放一次落笔动画；有声书读到下一句才画出、同句重画不重放；
/// 有声书底色透明时不画；切回经典恢复窄条。WebKit 一侧要在 Mac WKWebView 上另验。
void main() {
  const String p1 =
      '彼は軽く会<ruby>釈<rt>しゃく</rt></ruby>をして、'
      '<ruby>大喝采<rt>だいかっさい</rt></ruby>の中を歩いていった。';
  const String p2 =
      '<ruby>自嘲<rt>じちょう</rt></ruby>気味に笑った彼女は、'
      '<ruby>烏滸<rt>おこ</rt></ruby>がましいと<ruby>呟<rt>つぶや</rt></ruby>'
      'いて窓の外を見つめ続けていたが、やがて静かに目を閉じた。';

  String baseText(String html) => html
      .replaceAll(RegExp(r'<rt>.*?</rt>'), '')
      .replaceAll(RegExp(r'</?ruby>'), '');
  int units(String text) => text.replaceAll(RegExp('[、。]'), '').length;

  Future<String> page({
    required String writingMode,
    required String viewMode,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode(writingMode);
    await settings.setViewMode(viewMode);
    for (final (HighlightKind kind, HighlightStrokeStyle style)
        in <(HighlightKind, HighlightStrokeStyle)>[
          (HighlightKind.favorite, HighlightStrokeStyle.marker),
          (HighlightKind.lookup, HighlightStrokeStyle.fluo),
          (HighlightKind.audio, HighlightStrokeStyle.rough),
          (HighlightKind.search, HighlightStrokeStyle.tape),
        ]) {
      await settings.setHighlightStrokeConfig(
        kind,
        kind.defaults.copyWith(style: style),
      );
    }
    final String css = ReaderContentStyles.css(settings: settings);
    final bool vn = viewMode == 'vn';
    final String engine = ReaderPaginationScripts.engineShell(
      vnMode: vn,
      continuousMode: viewMode == 'continuous',
    );
    final String t1 = baseText(p1);
    final String t2 = baseText(p2);
    final List<Map<String, Object>> cues = <Map<String, Object>>[
      <String, Object>{'id': 'c1', 'text': t1, 'start': 0, 'length': units(t1)},
      <String, Object>{
        'id': 'c2',
        'text': t2,
        'start': units(t1),
        'length': units(t2),
      },
    ];
    final Map<String, Object?> config = <String, Object?>{
      'vnMode': vn,
      'continuousMode': viewMode == 'continuous',
      'dartPageWidth': 1280,
      'dartPageHeight': 800,
      'chromeTopInset': 0,
      'chromeBottomInset': 0,
      'initialCharOffset': -1,
      'initialProgress': 0,
      'initialFragment': null,
      'sentenceAudioCues': cues,
      'perfTraceEnabled': false,
      'vnRevealSpeed': 0,
      'vnSentencesPerScreen': 4,
      'vnScreenMode': 'sentences',
      'vnPreserveDialogue': true,
      'vnMergeCrossScreenSentenceAudioCues': false,
      'navigationGeneration': 1,
      'revealedKeys': <String>[],
      'blurImages': false,
    };
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<style id="fushi-reader-style">$css</style>'
        '<script>window.flutter_inappwebview = { callHandler: function() '
        '{ return Promise.resolve(null); } };'
        'window.__fushiApplyReaderMargins = function() {};</script>'
        '</head><body><p>$p1</p><p>$p2</p>'
        '<script>${ReaderSelectionScripts.source()}</script>$engine'
        '<script>window.__fushiInstallShell(${jsonEncode(config)});</script>'
        '</body></html>';
  }

  test(
    'all four highlight kinds paint SVG strokes on the lane layer in every mode',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final List<Map<String, String>> pages = <Map<String, String>>[];
      for (final String writingMode in <String>[
        'vertical-rl',
        'horizontal-tb',
      ]) {
        for (final String viewMode in <String>[
          'paginated',
          'continuous',
          'vn',
        ]) {
          pages.add(<String, String>{
            'name': '$writingMode/$viewMode',
            'html': await page(writingMode: writingMode, viewMode: viewMode),
          });
        }
      }
      final Directory temp = Directory.systemTemp.createTempSync(
        'highlight-strokes-',
      );
      try {
        final File payload = File('${temp.path}/pages.json')
          ..writeAsStringSync(jsonEncode(<String, Object>{'pages': pages}));
        final Process process = await Process.start(nodeExe, <String>[
          'test/reader/highlight_stroke_marker_harness.mjs',
          payload.path,
        ]);
        final Future<String> stdout = process.stdout
            .transform(utf8.decoder)
            .join();
        final Future<String> stderr = process.stderr
            .transform(utf8.decoder)
            .join();
        final int exitCode = await process.exitCode.timeout(
          const Duration(seconds: 100),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        final String out = await stdout;
        if (exitCode == 77) {
          markTestSkipped('Chrome unavailable: $out');
          return;
        }
        expect(exitCode, 0, reason: '$out\n${await stderr}');
        expect(out, contains('PASS 6 stroke pages'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
