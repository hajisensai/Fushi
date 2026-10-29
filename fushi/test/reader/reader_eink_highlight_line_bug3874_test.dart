@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3886：墨水屏下有声书当前句的线在注音词、着重号处断开，字形被切。
///
/// 墨水屏原来关掉窄条层、给 `::highlight(fushi-sentence-audio)` 加下划线：Blink 把生效的 CSS
/// Highlight 覆盖的文字裁进文字片段盒重画（BUG-3776），窄条层的注册表钩子又把带着重号的文字剔出
/// 引擎绘制件，于是线到着重号处断开、注音所在的行丢线。现在墨水屏的线也由窄条层画。真 Chrome 跑
/// 生产 CSS + 引擎壳 + 选区脚本，墨水屏、三种 view mode × 横竖排：当前句不交给引擎绘制，线沿整句
/// （跨注音、着重号、换列 / 换行）逐像素连续。
void main() {
  const String lead = 'じりじりと狭まっていく<ruby>合成獣<rt>キメラ</rt></ruby>たちの包囲の中で、';
  const String cue =
      'あの少年が<ruby>満身創痍<rt>まんしんそうい</rt></ruby>の少女を'
      '<span class="em">抱きしめて</span>いる、その姿を見つめながら'
      '<ruby>彼<rt>かれ</rt></ruby>は<span class="em">何も言えずに</span>'
      'ただその場に立ち尽くしていた。';

  String baseText(String html) => html
      .replaceAll(RegExp(r'<rt>.*?</rt>'), '')
      .replaceAll(RegExp(r'<[^>]+>'), '');
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
    final String css = ReaderContentStyles.css(
      settings: settings,
      einkMode: true,
    );
    final bool vn = viewMode == 'vn';
    final String engine = ReaderPaginationScripts.engineShell(
      vnMode: vn,
      continuousMode: viewMode == 'continuous',
    );
    final String text = baseText(cue);
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
          'start': units(baseText(lead)),
          'length': units(text),
        },
      ],
      'perfTraceEnabled': false,
      'vnRevealSpeed': 0,
      'vnSentencesPerScreen': 4,
      'vnScreenMode': 'block',
      'vnPreserveDialogue': true,
      'vnMergeCrossScreenSentenceAudioCues': false,
      'navigationGeneration': 1,
      'revealedKeys': <String>[],
      'blurImages': false,
    };
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<style id="fushi-reader-style">$css</style>'
        // 段落离开页顶 / 页右：连续模式页顶有渐隐，线的取样带不能落在里面。
        '<style>.em { text-emphasis: sesame; } p { margin-block-start: 4em; }</style>'
        '<script>window.flutter_inappwebview = { callHandler: function() '
        '{ return Promise.resolve(null); } };'
        'window.__fushiApplyReaderMargins = function() {};</script>'
        '</head><body><p>$lead$cue</p>'
        '<script>${ReaderSelectionScripts.source()}</script>$engine'
        '<script>window.__fushiInstallShell(${jsonEncode(config)});</script>'
        '</body></html>';
  }

  test(
    'e-ink current-sentence line runs unbroken across ruby and emphasis',
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
        'eink-highlight-line-',
      );
      try {
        final File payload = File('${temp.path}/pages.json')
          ..writeAsStringSync(jsonEncode(<String, Object>{'pages': pages}));
        final ProcessResult result = await Process.run(nodeExe, <String>[
          'test/reader/reader_eink_highlight_line_bug3874_harness.mjs',
          payload.path,
        ]);
        if (result.exitCode == 77) {
          markTestSkipped('Chrome unavailable: ${result.stdout}');
          return;
        }
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 6 e-ink pages'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

/// Resolve Node before launching the browser harness so missing CI tools skip.
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
