// 起真 headless Chrome：带 chrome 标签，dist_test 只派给声明了 chrome 能力的 worker。
@Tags(<String>['chrome'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import 'manga_tilted_block_frame_bug5308_fixture.dart';

/// BUG-5308（反馈 3ERe-0Q4q8）：漫画朗读的当前句高亮在斜排文字上仍是正框。
///
/// 在**真 Chromium** 里加载 [mangaWindowDocument] 生成的整份文档，文字层用
/// [mangaOcrBoxesHtml] 生成，走生产的 `__mangaSetSpeaking`，量浏览器实际算出来的
/// 样式：斜块的高亮画在 `::before` 上且转角与字格一致、块框本身不画正框；正立块
/// 照旧由块框描边；「显示识别范围」同理。
const String _cases = r'''
(function () {
  var failures = [];
  var passed = 0;
  function check(cond, msg) { if (cond) { passed++; } else { failures.push(msg); } }
  function angleOf(transform) {
    var m = /matrix\(([^)]+)\)/.exec(transform || '');
    if (!m) return null;
    var v = m[1].split(',').map(parseFloat);
    return Math.atan2(v[1], v[0]) * 180 / Math.PI;
  }
  window.__mangaReplaceOcr(0, window.__testBoxes);
  var sel = '.manga-page[data-page="0"] .ocr-box[data-manga-block="';
  var tilted = document.querySelector(sel + '0"]');
  var upright = document.querySelector(sel + '1"]');
  check(!!tilted && !!upright, 'both boxes rendered');

  var idle = getComputedStyle(tilted, '::before');
  check(idle.outlineStyle === 'none', 'idle tilted frame draws nothing: ' + idle.outlineStyle);

  window.__mangaSetSpeaking(0, [0]);
  check(tilted.classList.contains('manga-speaking'), 'tilted block is speaking');
  check(getComputedStyle(tilted).outlineStyle === 'none',
      'axis-aligned block box draws no outline: ' + getComputedStyle(tilted).outlineStyle);
  var frame = getComputedStyle(tilted, '::before');
  check(frame.outlineStyle === 'solid', 'rotated frame is outlined: ' + frame.outlineStyle);
  var frameAngle = angleOf(frame.transform);
  var charAngle = angleOf(getComputedStyle(tilted.querySelector('.ocr-char')).transform);
  check(frameAngle !== null && Math.abs(frameAngle - (-20)) < 0.5,
      'frame rotated -20deg: ' + frame.transform);
  check(charAngle !== null && Math.abs(frameAngle - charAngle) < 0.5,
      'frame follows character rotation: ' + frameAngle + ' vs ' + charAngle);
  var ratio = parseFloat(frame.height) / parseFloat(frame.width);
  check(Math.abs(ratio - 3) < 0.05, 'frame is the 1x3 column, not its bounds: ' + ratio);

  window.__mangaSetSpeaking(0, [1]);
  check(getComputedStyle(upright).outlineStyle === 'solid',
      'upright block keeps the box outline');
  check(getComputedStyle(upright, '::before').content === 'none',
      'upright block has no frame pseudo element');
  check(getComputedStyle(tilted, '::before').outlineStyle === 'none',
      'tilted frame cleared when not speaking');

  window.__mangaSetSpeaking(0, []);
  document.body.classList.add('ocr-boxes-visible');
  check(getComputedStyle(tilted).outlineStyle === 'none',
      'recognition-range view: no axis-aligned box on tilted block');
  check(getComputedStyle(tilted, '::before').outlineStyle === 'solid',
      'recognition-range view: rotated frame outlined');

  var out = document.createElement('pre');
  out.id = 'results';
  out.textContent = btoa(JSON.stringify({passed: passed, failures: failures}));
  document.body.appendChild(out);
})();
''';

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

  String documentFor() {
    final List<MokuroImage> pages = <MokuroImage>[
      for (int i = 0; i < 2; i++)
        MokuroImage(
          url: 'p$i.png',
          size: const MokuroSize(400, 400),
          blocks: const <MokuroBlock>[],
        ),
    ];
    final String document = mangaWindowDocument(
      pages,
      <String>[for (int i = 0; i < 2; i++) 'p$i.png'],
      mode: MangaReadingMode.webtoon,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
    );
    final String setup =
        'window.__testBoxes=${jsonEncode(mangaOcrBoxesHtml(bug5308Page()))};';
    const String bridge =
        '<script>window.flutter_inappwebview={callHandler:function(){'
        'return undefined;}};</script>';
    return document
        .replaceFirst('<head>', '<head>$bridge')
        .replaceFirst('</body>', '<script>$setup$_cases</script></body>');
  }

  test(
    '斜排块的朗读高亮 / 识别范围框跟字格一起转，正立块照旧',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'manga-tilted-frame-',
      );
      try {
        final File html = File('${temp.path}/test.html')
          ..writeAsStringSync(documentFor());
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
        expect(report['passed'] as int, 13);
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
