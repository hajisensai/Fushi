import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 漫画朗读的高亮（Vfy9mU3-OV）：`__mangaSetSpeaking(page, group)` 只给正在读的
/// 句子分组加 `manga-speaking`，后台 OCR 用 `__mangaReplaceOcr` 换掉文字层后高亮
/// 仍在，group < 0 清除。
///
/// 在**真 Chromium** 里加载 [mangaWindowDocument] 生成的整份文档跑生产脚本（与
/// manga_zoom_scroll_chrome_js_test 同一套方式）；页 0 的文字层用
/// [mangaOcrBoxesHtml] 生成，组号取 [mangaBlockSentenceGroups]，与阅读器同源。
void main() {
  final String? chrome =
      <String?>[
            Platform.environment['CHROME_EXECUTABLE'],
            r'C:\Program Files\Google\Chrome\Application\chrome.exe',
            r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            '/usr/bin/google-chrome',
            '/usr/bin/chromium',
            '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
          ]
          .whereType<String>()
          .where((String path) => File(path).existsSync())
          .firstOrNull;

  /// BUG-1333 的真实页：右起「なに?」一组，左边注音 + 三列正文一组。
  const MokuroImage page0 = MokuroImage(
    url: 'p0.png',
    size: MokuroSize(1000, 1414),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(288, 565, 309, 675),
        isVertical: true,
        fontSize: 21,
        zIndex: 0,
        lines: <String>['だいじょうぶ'],
      ),
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(250, 561, 288, 687),
        isVertical: true,
        fontSize: 37,
        zIndex: 1,
        lines: <String>['大丈夫'],
      ),
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(205, 565, 240, 687),
        isVertical: true,
        fontSize: 34,
        zIndex: 2,
        lines: <String>['だよな'],
      ),
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(164, 644, 177, 683),
        isVertical: true,
        fontSize: 22,
        zIndex: 3,
        lines: <String>['?'],
      ),
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(322, 560, 360, 686),
        isVertical: true,
        fontSize: 34,
        zIndex: 4,
        lines: <String>['なに?'],
      ),
    ],
  );

  String documentFor(String cases) {
    final List<MokuroImage> pages = <MokuroImage>[
      for (int i = 0; i < 3; i++)
        MokuroImage(
          url: 'p$i.png',
          size: const MokuroSize(1000, 1414),
          blocks: const <MokuroBlock>[],
        ),
    ];
    final String document = mangaWindowDocument(
      pages,
      <String>[for (int i = 0; i < 3; i++) 'p$i.png'],
      mode: MangaReadingMode.webtoon,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
    );
    final int group = mangaBlockSentenceGroups(page0)[1].group;
    final String setup =
        'window.__testBoxes=${jsonEncode(mangaOcrBoxesHtml(page0))};'
        'window.__testGroup=$group;';
    const String bridge =
        '<script>window.flutter_inappwebview={callHandler:function(){'
        'return undefined;}};</script>';
    return document
        .replaceFirst('<head>', '<head>$bridge')
        .replaceFirst('</body>', '<script>$setup$cases</script></body>');
  }

  test(
    '朗读高亮只挂在正在读的句子分组上，换文字层后仍在，-1 清除',
    () async {
      final String cases = File(
        'test/media/manga/manga_read_aloud_highlight_js_test.js',
      ).readAsStringSync();
      final Directory temp = Directory.systemTemp.createTempSync(
        'manga-read-aloud-highlight-',
      );
      try {
        final File html = File('${temp.path}/test.html')
          ..writeAsStringSync(documentFor(cases));
        final _ChromeRun result = await _runChrome(chrome!, <String>[
          '--headless',
          '--no-sandbox',
          '--disable-gpu',
          '--no-first-run',
          '--disable-background-networking',
          '--enable-logging=stderr',
          '--window-size=412,860',
          '--dump-dom',
          '--user-data-dir=${temp.path}/profile',
          html.uri.toString(),
        ]);
        expect(result.exitCode, 0, reason: result.stderr);
        final RegExpMatch? payload = RegExp(
          r'<pre id="results">([^<]+)</pre>',
        ).firstMatch(result.stdout);
        expect(
          payload,
          isNotNull,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final Map<String, dynamic> report =
            jsonDecode(utf8.decode(base64Decode(payload!.group(1)!)))
                as Map<String, dynamic>;
        expect(report['failures'], isEmpty, reason: '${report['failures']}');
        expect(report['passed'] as int, 8);
      } finally {
        try {
          temp.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows 上 Chrome 偶尔还占着 profile：临时目录留给系统清理。
        }
      }
    },
    skip: chrome == null ? 'Chromium required; set CHROME_EXECUTABLE' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

typedef _ChromeRun = ({int exitCode, String stdout, String stderr});

/// 起 headless Chrome 并等它退出、输出流关闭（与 manga_zoom_scroll_chrome_js_test
/// 同口径）。
Future<_ChromeRun> _runChrome(String executable, List<String> args) async {
  final Process process = await Process.start(executable, args);
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final Future<void> outDone = process.stdout
      .transform(utf8.decoder)
      .forEach(out.write);
  final Future<void> errDone = process.stderr
      .transform(utf8.decoder)
      .forEach(err.write);
  int? exitCode;
  final Future<int> exited = process.exitCode.then((int code) {
    exitCode = code;
    return code;
  });
  try {
    await Future.wait<void>(<Future<void>>[
      exited,
      outDone,
      errDone,
    ]).timeout(const Duration(seconds: 60));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    fail('headless Chrome 60 s 内没有结束。\n--- stderr ---\n$err');
  }
  return (exitCode: exitCode!, stdout: out.toString(), stderr: err.toString());
}
