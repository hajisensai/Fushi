@Tags(<String>['chrome'])
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/node_runtime.dart';

/// BUG-3776：Blink 上任何生效的 CSS Custom Highlight 都会裁掉它覆盖的着重号（傍点）。VN 的有声书
/// 当前句自 BUG-3741 起在 Blink 上也走 Range + CSS.highlights，播到带傍点的句子时傍点只剩一角。
/// 同一机制还把墨迹伸出文字片段盒的字形切平（圆体 / Meiryo 的 ruby 基字）。真 Chrome 跑生产 CSS +
/// 引擎壳 + 选区脚本，三种 view mode、横竖排、默认 / 自定义字色各一遍：高亮前后截同一块着重号区域，
/// 墨迹不能变少；当前句窄条仍盖住带傍点的字；交给引擎绘制的高亮不覆盖带傍点的文字，也不覆盖
/// 高亮对它是空操作的文字（默认字色时整句都不交）；自定义字色时不走 CSS Highlight，VN 在换屏时
/// （显示之前）把句子包裹好、字色走 wrapper，播放时屏上 DOM 只切 class（BUG-3741 不平移），
/// 带傍点的字也换成自定义色。查词高亮设了文字色（反色高亮）时，带傍点的字照样交给引擎换色（能读优先），
/// 没设时查词高亮对整段是空操作、一个字都不交。
void main() {
  const String paragraph =
      '彼は<span class="em">教科書通り</span>の<ruby>技術<rt>ぎじゅつ</rt></ruby>で戦った。';

  String baseText(String html) => html
      .replaceAll(RegExp(r'<rt>.*?</rt>'), '')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  int units(String text) => text.replaceAll(RegExp('[、。]'), '').length;

  Future<String> page({
    required String writingMode,
    required String viewMode,
    String? textColor,
    String? selectionTextColor,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode(writingMode);
    await settings.setViewMode(viewMode);
    final String css = ReaderContentStyles.css(
      settings: settings,
      sentenceAudioTextColor: textColor,
      selectionColor: selectionTextColor == null ? null : 'rgb(20, 20, 20)',
      selectionTextColor: selectionTextColor,
    );
    final bool vn = viewMode == 'vn';
    final String engine = ReaderPaginationScripts.engineShell(
      vnMode: vn,
      continuousMode: viewMode == 'continuous',
    );
    final String text = baseText(paragraph);
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
      'sentenceAudioCues': <Map<String, Object>>[
        <String, Object>{
          'id': 'c1',
          'text': text,
          'start': 0,
          'length': units(text),
        },
      ],
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
        // 段落离开页顶 / 页右：连续模式页顶有渐隐，着重号取样带不能落在里面。
        '<style>.em { text-emphasis: sesame; } p { margin-block-start: 4em; }</style>'
        // The bridge stub records onRestoreComplete -- the engine's content-ready signal that
        // lifts the app's loading mask -- so the harness waits on it, not on a fixed sleep.
        '<script>window.__fushiRestored = new Promise(function(r) '
        '{ window.__fushiMarkRestored = r; });'
        'window.flutter_inappwebview = { callHandler: function(name) '
        '{ if (name === "onRestoreComplete") window.__fushiMarkRestored(); '
        'return Promise.resolve(null); } };'
        'window.__fushiApplyReaderMargins = function() {};</script>'
        '</head><body><p>$paragraph</p>'
        '<script>${ReaderSelectionScripts.source()}</script>$engine'
        '<script>window.__fushiInstallShell(${jsonEncode(config)});</script>'
        '</body></html>';
  }

  test(
    'a current-sentence highlight keeps the emphasis marks it covers',
    () async {
      final String? nodeExe = resolveNodeExecutable();
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
          // 查词高亮文字色（拍板台 -8azTfJh_v）做的反色高亮：深色查词条上带傍点的字也必须换成
          // 浅色交给引擎绘制，否则深字落在深条上看不见。
          pages.add(<String, String>{
            'name': '$writingMode/$viewMode/selection-text',
            'selectionText': 'true',
            'html': await page(
              writingMode: writingMode,
              viewMode: viewMode,
              selectionTextColor: 'rgb(255, 255, 255)',
            ),
          });
          // 自定义当前句字色：Blink 上不走 CSS Highlight，VN 换屏时先包裹、播放只切 class。
          pages.add(<String, String>{
            'name': '$writingMode/$viewMode/custom-color',
            'customColor': 'true',
            'html': await page(
              writingMode: writingMode,
              viewMode: viewMode,
              textColor: 'rgb(30, 90, 200)',
            ),
          });
        }
      }
      final Map<String, Object> payload = <String, Object>{'pages': pages};
      final NodeHarnessResult run = await runNodeHarness(
        nodeExe,
        'test/reader/reader_emphasis_highlight_bug3770_harness.mjs',
        payload,
        timeout: const Duration(seconds: 100),
      );
      final int exitCode = run.exitCode;
      final String out = run.stdout;
      if (exitCode == 77) {
        markTestSkipped('Chrome unavailable: $out');
        return;
      }
      expect(exitCode, 0, reason: '$out\n${run.stderr}');
      expect(out, contains('PASS 18 emphasis pages'));
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );
}
