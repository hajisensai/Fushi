import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 漫画阅读器触屏双指缩放（iPad 用户报：双指缩放不了、大滑动后莫名放大到巨大比例、
/// 放大后卡死点什么都没反应）。
///
/// 漫画正文是原生 WebView，捏合 / 平移 / 翻页全在生成文档注入的手势脚本里——Flutter
/// widget 测试的 TestGesture 根本到不了这一层（platform view 之上没有任何 Flutter
/// 识别器）。所以这里在**真 Chromium** 里加载 [mangaWindowDocument] 生成的整份文档，
/// 用真实 DOM `PointerEvent` 在手指下的元素上派发多指序列，跑的是生产脚本本身。
///
/// 「丢失的手指」：手指按在一个随后被移出 DOM 的节点上（OCR 层被替换、覆盖翻页层
/// 被拆掉），松手事件派发给已脱离文档的节点，传播路径里不再有 `document`——文档级
/// 手势机永远听不到它抬起。旧实现把这根手指永久留在活跃触点表里：下一次单指大滑动
/// 被当成「幽灵指 + 真手指」的捏合（指距从几十像素拉到几百像素 → 放大到上限），
/// 捏合守卫又要等触点表清空才解除 → 之后所有点击 / 滑动被吞（卡死）。
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

  /// 生成指定阅读模式的三页文档，并在页内注入桥桩与用例脚本。
  String documentFor(MangaReadingMode mode, String cases) {
    const List<MokuroImage> pages = <MokuroImage>[
      MokuroImage(
        url: 'p0.png',
        size: MokuroSize(1000, 1414),
        blocks: <MokuroBlock>[],
      ),
      MokuroImage(
        url: 'p1.png',
        size: MokuroSize(1000, 1414),
        blocks: <MokuroBlock>[],
      ),
      MokuroImage(
        url: 'p2.png',
        size: MokuroSize(1000, 1414),
        blocks: <MokuroBlock>[],
      ),
    ];
    final String document = mangaWindowDocument(
      pages,
      const <String>['p0.png', 'p1.png', 'p2.png'],
      mode: mode,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
      currentSpread: 1,
    );
    const String bridge =
        '<script>window.flutter_inappwebview={callHandler:function(){'
        'var c=window.__mangaTestCalls;if(c)c.push([].slice.call(arguments));'
        'return undefined;}};</script>';
    final String tag = mode == MangaReadingMode.webtoon ? 'webtoon' : 'paged';
    return document
        .replaceFirst('<html>', '<html data-test-mode="$tag">')
        .replaceFirst('<head>', '<head>$bridge')
        .replaceFirst('</body>', '<script>$cases</script></body>');
  }

  final String cases = File(
    'test/media/manga/manga_touch_pinch_js_test.js',
  ).readAsStringSync();

  for (final MangaReadingMode mode in <MangaReadingMode>[
    MangaReadingMode.spread,
    MangaReadingMode.webtoon,
  ]) {
    test(
      '${mode.name}：双指捏合缩放 / 单指平移 / 丢失手指后大滑动不缩放、不卡死',
      () async {
        final Directory temp = Directory.systemTemp.createTempSync(
          'manga-touch-pinch-',
        );
        try {
          final File html = File('${temp.path}/test.html')
            ..writeAsStringSync(documentFor(mode, cases));
          final ProcessResult result = await Process.run(chrome!, <String>[
            '--headless',
            '--no-sandbox',
            '--disable-gpu',
            '--no-first-run',
            '--disable-background-networking',
            '--window-size=412,860',
            '--dump-dom',
            '--user-data-dir=${temp.path}/profile',
            html.uri.toString(),
            // 比外层 90s 短：Chrome 真卡住时先由这里抛，错误里带得上 stderr。
          ]).timeout(const Duration(seconds: 60));
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final RegExpMatch? payload = RegExp(
            r'<pre id="results">([^<]+)</pre>',
          ).firstMatch(result.stdout as String);
          expect(
            payload,
            isNotNull,
            reason: '${result.stdout}\n${result.stderr}',
          );
          final Map<String, dynamic> report =
              jsonDecode(utf8.decode(base64Decode(payload!.group(1)!)))
                  as Map<String, dynamic>;
          expect(report['failures'], isEmpty, reason: '${report['failures']}');
          expect(
            report['passed'] as int,
            mode == MangaReadingMode.webtoon ? 11 : 14,
          );
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
      skip: chrome == null ? 'Chromium required; set CHROME_EXECUTABLE' : false,
      // test/media/manga 也可能并行起多个 Chrome；与 test/reader 的真 Chrome 套件同口径。
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
