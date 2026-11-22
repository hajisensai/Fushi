// 起真 headless Chrome：带 chrome 标签，dist_test 只派给声明了 chrome 能力的 worker
// （浏览器装了不等于能跑——无图形会话的 SSH worker 上 Chrome 会段错误退出）。
@Tags(<String>['chrome'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_defs_layout.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show kFushiCardStylingCss;

/// BUG-5181（应用内反馈 qBykM9EeLw）：复习页释义里的词典插图「雷霆大」且点不开。
///
/// 在**真 Chromium** 里按真实约束排一遍：Fushi 卡片模板 CSS + 释义页插图样式 / 脚本 +
/// 释义排版脚本 + 卡面链接 / 点图脚本，插图用制卡导出的原样结构（popup.js
/// `applyImageStyles` + `inlineStructuredContentExportStyles`：gloss-* class 已剥掉、几何全是
/// 内联样式），放进小学館例解学習国語那种「插图 + 竖排图注」两格表里，词典 CSS 取该词典
/// styles.css 的原规则。浏览器配置打开 Android WebView 的默认最小字号 8px——导出的图片盒是
/// `font-size:1px; width:239em`，计算字号被报成 8px，旧脚本据此把 239px 的插图算成 1912px。
///
/// 每档「卡面图片大小」断言：图片在盒子里、盒子不超出栏宽（图注留在栏内）、宽度符合该档；
/// 点图片和点盒内占位层都把图片交给宿主放大。
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

  for (final SrsReviewImageSize size in SrsReviewImageSize.values) {
    test(
      '「${size.name}」档：插图跟着盒子、不超栏宽，点按交给宿主放大（最小字号 8px）',
      () async {
        final Directory temp = Directory.systemTemp.createTempSync(
          'srs-illus-chrome-',
        );
        try {
          // Android WebView 的 WebSettings 默认 minimumFontSize = 8。
          Directory('${temp.path}/profile/Default').createSync(recursive: true);
          File('${temp.path}/profile/Default/Preferences').writeAsStringSync(
            jsonEncode(<String, Object?>{
              'webkit': <String, Object?>{
                'webprefs': <String, Object?>{'minimum_font_size': 8},
              },
            }),
          );
          final File html = File('${temp.path}/test.html')
            ..writeAsStringSync(_document(size));
          final _ChromeRun result = await _runChrome(chrome!, <String>[
            '--headless',
            '--no-sandbox',
            '--disable-gpu',
            '--no-first-run',
            '--disable-background-networking',
            '--enable-logging=stderr',
            '--window-size=600,900',
            '--virtual-time-budget=5000',
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
          expect(
            report['failures'],
            isEmpty,
            reason: '${report['failures']}\n${report['details']}',
          );
          expect(report['passed'] as int, 23, reason: '${report['details']}');
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
      skip: chrome == null ? 'Chromium required; set CHROME_EXECUTABLE' : false,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

/// 插图自然尺寸（小学館例解学習国語「ネクタイ」的 images/700e5a6424.avif）。
const int _w = 239;
const int _h = 320;

/// 栏宽：卡面根的宽度（窄屏手机）。
const int _rootWidth = 360;

/// 「放大」档的高度上限（窄版式由调用方传像素值）。
const int _largeMaxHeight = 480;

const String _linkStyle =
    'display:inline-block;position:relative;line-height:1;max-width:100%;';
const String _boxStyle =
    'display:inline-block;white-space:nowrap;max-width:100%;max-height:100vh;'
    'position:relative;vertical-align:top;line-height:0;overflow:hidden;';
const String _imgAbs =
    'display:inline-block;vertical-align:top;object-fit:contain;border:none;'
    'outline:none;position:absolute;left:0;top:0;width:100%;height:100%;';
const String _imgNatural =
    'display:inline-block;vertical-align:top;object-fit:contain;border:none;'
    'outline:none;position:static;width:auto;height:auto;max-width:100%;';
const String _cell =
    'border-style:solid;padding:0.25em;vertical-align:top;border-width:1px;'
    'border-color:currentColor;';

/// 量到真实尺寸的导出：盒子 `font-size:1px; width:<N>em`，sizer 用 padding-top 撑高。
String _declaredLink(String id) =>
    '<a id="$id" href="700e5a6424.avif" target="_blank" '
    'rel="noreferrer noopener" style="$_linkStyle">'
    '<span style="${_boxStyle}font-size:1px;width:${_w}em;">'
    '<span style="padding-top:${_h / _w * 100}%;display:inline-block;width:0;'
    'vertical-align:top;font-size:0;"></span>'
    '<span style="display:none;"></span><span></span>'
    '<img alt="" width="$_w" height="$_h" style="$_imgAbs"></span></a>';

/// 没量到真实尺寸的导出：盒子 `width:auto`，img 按自然尺寸排。
String _naturalLink(String id) =>
    '<a id="$id" href="700e5a6424.avif" target="_blank" '
    'rel="noreferrer noopener" style="$_linkStyle">'
    '<span style="${_boxStyle}font-size:1px;width:auto;">'
    '<span style="padding-top:100%;display:none;"></span>'
    '<span style="display:none;"></span><span></span>'
    '<img alt="" style="$_imgNatural"></span></a>';

/// 小学館例解学習国語的插图：两格表（插图 | 竖排图注）。
String _figure(String link) =>
    '<div data-sc-image="" data-sc挿絵="" data-sc-class="挿絵">'
    '<div style="display:block;"><table data-sc-table="" data-sc-image="" '
    'data-sc-class="image" style="table-layout:auto;border-collapse:collapse;">'
    '<tr data-sc-tr=""><td data-sc-td="" data-sc-img="" data-sc-class="img" '
    'style="$_cell"><span data-sc-img="">$link</span></td>'
    '<td data-sc-td="" data-sc-caption="" data-sc-class="caption" '
    'style="$_cell"><span data-sc-caption="">〈ネクタイ〉</span></td></tr>'
    '</table></div></div>';

/// 该词典 styles.css 里作用于插图表的原规则（按导出方式加词条作用域）。
const String _dictCss =
    '[data-dictionary="D"] [data-sc-image] td{border-style:none!important;}'
    '[data-dictionary="D"] table[data-sc-image] td{border:none;}'
    '[data-dictionary="D"] table[data-sc-image] td[data-sc-caption]'
    '{text-align:start;writing-mode:vertical-rl;}'
    '[data-dictionary="D"] [data-sc-image]{display:block;'
    'margin-block-start:0.5em;margin-block-end:0.5em;}';

String _document(SrsReviewImageSize size) {
  final String cases = File(
    'test/srs/srs_defs_illustration_chrome_test.js',
  ).readAsStringSync();
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<style>$kFushiCardStylingCss</style>'
      '<style>${srsDefsIllustrationCss(size, maxHeight: '${_largeMaxHeight}px')}</style>'
      '<style>$_dictCss #fushi-card-root{width:${_rootWidth}px;}</style>'
      '<script>window.flutter_inappwebview={callHandler:function(){'
      'var c=window.__srsTestCalls;if(c)c.push([].slice.call(arguments));}};'
      'window.__srsTestCase=${jsonEncode(<String, Object?>{'size': size.name, 'w': _w, 'h': _h, 'largeMaxHeight': _largeMaxHeight, 'minWidth': kSrsDefsIllustrationMinWidth})};</script>'
      '</head><body style="margin:0">'
      '<div id="fushi-card-root"><div class="card">'
      '<div class="fc fc-back fc-defs-only"><div class="fc-gloss fc-gloss--main">'
      '<div class="fc-dicts"><details class="fc-dict" open>'
      '<summary class="fc-dict-label"><span class="fc-dict-name">D</span></summary>'
      '<ol class="fc-dict-items"><li data-dictionary="D"><span>'
      'ワイシャツのえりもとにまいてむすぶ、細長い布。タイ。'
      '${_figure(_declaredLink('declared'))}'
      '${_figure(_naturalLink('natural'))}'
      '</span></li></ol></details></div></div></div></div></div>'
      '<script>$kSrsDefsIllustrationScript$kSrsDefsLayoutScript</script>'
      '<script>$kSrsCardLinkScript$kSrsCardImageTapScript</script>'
      '<script>$cases</script>'
      '</body></html>';
}

/// 一次 headless Chrome 运行的结果。
typedef _ChromeRun = ({int exitCode, String stdout, String stderr});

/// 起 headless Chrome 并等它退出、输出流关闭；超时就结束 Chrome 并带上已收到的
/// 输出报错（与 manga_zoom_scroll_chrome_js_test 同口径）。
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
