@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_vertical_punctuation_font.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3606：真 Chrome 跑生产阅读器 CSS，正文字体是一款没有 `vert` 的字体
/// （`fixtures/no_vert_cjk.woff2`）。竖排三种布局下正文的「必须画成标点子集的竖排字形
/// （与只用缺 vert 字体画出的横排「不同）；横排必须原样（不注入子集）。WebKit 一侧要在
/// Mac WKWebView 上另验。
void main() {
  String dataUri(String path) =>
      'data:font/woff2;base64,${base64Encode(File(path).readAsBytesSync())}';

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
    final String css =
        ReaderContentStyles.css(
          settings: settings,
          fontFaces:
              '@font-face { font-family: "NoVert"; '
              'src: url("${dataUri('test/reader/fixtures/no_vert_cjk.woff2')}"); }',
          fontFamily: '"NoVert"',
        ).replaceAll(
          ReaderCustomFontCss.resourceUrl(
            ReaderVerticalPunctuationFont.urlPath,
          ),
          dataUri(ReaderVerticalPunctuationFont.assetKey),
        );
    // 探针要看得见：去掉只为翻页准备的视口裁剪与页边距遮罩。
    const String probeCss = '''
body { clip-path: none !important; }
html::before { display: none !important; }
.probe { position: fixed; top: 300px; width: 96px; height: 96px;
  font-size: 64px; line-height: 1; margin: 0; padding: 0; }
''';
    const String fallback =
        '"${ReaderVerticalPunctuationFont.family}", "NoVert"';
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<style>$css</style><style>$probeCss</style></head><body>'
        '<p>「床に」</p>'
        '<div id="t" class="probe" style="left: 400px">「</div>'
        '<div id="ref" class="probe" style=\'left: 600px; '
        'font-family: $fallback !important\'>「</div>'
        '<div id="bad" class="probe" style=\'left: 800px; '
        'font-family: "NoVert" !important\'>「</div>'
        // 反馈 mTof77pMTe：长音符 ー 与「」同属 Tr，缺 vert 时同样画成横线。
        '<div id="t2" class="probe" style="left: 400px; top: 450px">ー</div>'
        '<div id="ref2" class="probe" style=\'left: 600px; top: 450px; '
        'font-family: $fallback !important\'>ー</div>'
        '<div id="bad2" class="probe" style=\'left: 800px; top: 450px; '
        'font-family: "NoVert" !important\'>ー</div>'
        '</body></html>';
  }

  test(
    'vertical body text uses the vertical form of 「 even with a no-vert font',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final List<Map<String, Object>> pages = <Map<String, Object>>[
        for (final String viewMode in <String>['paginated', 'continuous', 'vn'])
          <String, Object>{
            'name': 'vertical-rl/$viewMode',
            'vertical': true,
            'html': await page(writingMode: 'vertical-rl', viewMode: viewMode),
          },
        <String, Object>{
          'name': 'horizontal-tb/paginated',
          'vertical': false,
          'html': await page(
            writingMode: 'horizontal-tb',
            viewMode: 'paginated',
          ),
        },
      ];
      final Directory temp = Directory.systemTemp.createTempSync(
        'vertical-punct-',
      );
      try {
        final File payload = File('${temp.path}/pages.json')
          ..writeAsStringSync(jsonEncode(<String, Object>{'pages': pages}));
        final Process process = await Process.start(nodeExe, <String>[
          'test/reader/vertical_punctuation_render_harness.mjs',
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
        expect(out, contains('PASS 4 punctuation pages'));
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
