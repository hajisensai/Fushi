import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 条漫缩放的「锚点回写滚动」不算用户滚动（反馈 P2jQzOBBag 排查中发现）。
///
/// 条漫缩放以手指下的内容为锚，靠 `_zoomAbout` 回写 `window.scrollY` 保住锚点。
/// 旧实现里这次 `scrollTo` 落在按下后 1200ms 的「用户输入」窗口内，被「滚动收起
/// 界面」监听当成读者自己滚动、回报 `onMangaReaderHide`：双击放大（scrollY 变大）
/// 把界面收起，双击缩回（scrollY 变小）把界面弹出来——读者看到的是「双击弹出了
/// 控制层」。捏合同理。真正的单指拖动滚动仍须照常回报。
///
/// 在**真 Chromium** 里加载 [mangaWindowDocument] 生成的整份文档、用真实 DOM
/// `PointerEvent` 驱动生产脚本（与 manga_touch_pinch_js_test 同一套方式）。浏览器
/// 每帧合并派发一次 `scroll` 事件，用例在相应时刻同步派发它，全程确定性。
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

  /// 生成十页条漫文档，并在页内注入桥桩与用例脚本。
  String documentFor(String cases) {
    final List<MokuroImage> pages = <MokuroImage>[
      for (int i = 0; i < 10; i++)
        MokuroImage(
          url: 'p$i.png',
          size: const MokuroSize(1000, 1414),
          blocks: const <MokuroBlock>[],
        ),
    ];
    final String document = mangaWindowDocument(
      pages,
      <String>[for (int i = 0; i < 10; i++) 'p$i.png'],
      mode: MangaReadingMode.webtoon,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
      // 双击缩放不播动画：缩放在第二击里同步落定，用例全程同步可判。
      animateDoubleTap: false,
    );
    const String bridge =
        '<script>window.flutter_inappwebview={callHandler:function(){'
        'var c=window.__mangaTestCalls;if(c)c.push([].slice.call(arguments));'
        'return undefined;}};</script>';
    return document
        .replaceFirst('<head>', '<head>$bridge')
        .replaceFirst('</body>', '<script>$cases</script></body>');
  }

  test(
    '条漫双击放大 / 缩回的锚点滚动不切换界面，真实拖动滚动照常收起界面',
    () async {
      final String cases = File(
        'test/media/manga/manga_zoom_scroll_chrome_js_test.js',
      ).readAsStringSync();
      final Directory temp = Directory.systemTemp.createTempSync(
        'manga-zoom-scroll-chrome-',
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
        expect(report['passed'] as int, 9);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: chrome == null ? 'Chromium required; set CHROME_EXECUTABLE' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// 一次 headless Chrome 运行的结果。
typedef _ChromeRun = ({int exitCode, String stdout, String stderr});

/// 起 headless Chrome 并等它退出、输出流关闭；超时就结束 Chrome 并带上已收到的
/// 输出报错（与 manga_touch_pinch_js_test 同口径）。
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
    final String tail = out.length > 2000
        ? out.toString().substring(out.length - 2000)
        : out.toString();
    fail(
      'headless Chrome 60 s 内没有结束（浏览器进程'
      '${exitCode == null ? '仍在运行' : '已退出，exit $exitCode，但输出管道未关闭'}）。\n'
      '--- stderr ---\n$err\n--- stdout（末尾）---\n$tail',
    );
  }
  return (exitCode: exitCode!, stdout: out.toString(), stderr: err.toString());
}
