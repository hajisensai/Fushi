import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_located_range_script.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

import '../helpers/source_guard.dart';

/// BUG-4103（feedback i9n2zSMKgT「跳转回去没高亮」）：卡片来源回跳 / 收藏页 / 制卡历史
/// 的句子跳转只把视口滚到句首，落点句没有任何标记。
///
/// ① 真 Chrome 跑 [kReaderLocatedRangeJs]：分页 / 连续（整章走查）与 VN（屏克隆 +
///    nodeStartOffsets）两条坐标路径都把 [start, end) 学习单位区间画成
///    `fushi-search` 高亮，越界 / 空区间 / 无 CSS Highlight 内核不画。
/// ② 源码守卫：开书句子跳转记下落点、每次该章恢复落定都重画、离章作废；回看横幅
///    不再挂 Scaffold.appBar（那会把 WebView 压矮而分页几何仍按全窗排版）。
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

  test(
    'jump target mark paints the located sentence in chapter and VN coordinates',
    () async {
      final String cases = File(
        'test/reader/reader_located_range_test.js',
      ).readAsStringSync();
      final Directory temp = Directory.systemTemp.createTempSync(
        'located-range-dom-',
      );
      try {
        final File html = File('${temp.path}/test.html');
        html.writeAsStringSync('''<!doctype html><meta charset="utf-8"><head>
<script>$kStudyUnitJs</script>
<script>${ReaderSelectionScripts.source()}</script>
<script>$kReaderLocatedRangeJs</script>
</head><body><script>
$cases
</script></body>''');
        final ProcessResult result = await Process.run(chrome!, <String>[
          '--headless',
          '--no-sandbox',
          '--disable-gpu',
          '--no-first-run',
          '--disable-background-networking',
          '--dump-dom',
          '--user-data-dir=${temp.path}/profile',
          html.uri.toString(),
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
        expect(report['passed'], 12);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: chrome == null ? 'Chromium required; set CHROME_EXECUTABLE' : false,
    // 同目录其它真 Chrome 套件同口径（并行起多个 Chrome 时默认 30s 不够）。
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('invocation defines the helper idempotently before calling it', () {
    final String js = readerMarkLocatedRangeInvocation(12, 30);
    expect(
      js,
      startsWith(kReaderLocatedRangeJs),
      reason: '首次调用时 WebView 里还没有这个函数，定义必须随调用一起下发',
    );
    expect(js, endsWith('window.__fushiMarkLocatedRange(12, 30);'));
    expect(
      kReaderLocatedRangeJs,
      contains("typeof window.__fushiMarkLocatedRange !== 'function'"),
    );
  });

  group('reader wiring', () {
    final String page = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ).readAsStringSync(),
    );
    final String navigation = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      ).readAsStringSync(),
    );

    test('sentence bookmark jump records the located span', () {
      final int branch = page.indexOf(
        "source: 'bookmark preserveSavedPosition=",
      );
      expect(branch, greaterThanOrEqualTo(0));
      final int assign = page.indexOf('_jumpTargetSpan =', branch);
      expect(assign, greaterThan(branch));
      final String expr = page.substring(assign, page.indexOf(';', assign));
      expect(expr, contains('end: charAnchor + len'));
      expect(expr, contains('len > 0'), reason: '普通书签（无句长）不是某一句，不标');
    });

    test('every settled restore of the chapter repaints the mark', () {
      final int favorites = navigation.indexOf('_applyChapterHighlights();');
      expect(favorites, greaterThanOrEqualTo(0));
      final int mark = navigation.indexOf('_applyJumpTargetMark();');
      expect(
        mark,
        greaterThan(favorites),
        reason: '与收藏高亮同一个恢复落定时机（重分页 / 宽变重导会重建 DOM）',
      );
      final String apply = methodBody(
        page,
        '  Future<void> _applyJumpTargetMark()',
      );
      expect(apply, contains('span.chapter != _currentChapter'));
      expect(apply, contains('readerMarkLocatedRangeInvocation('));
    });

    test('navigating to another chapter drops the mark', () {
      final String begin = methodBody(navigation, '  void _beginNavigation(');
      expect(
        begin,
        contains(
          'if (_jumpTargetSpan?.chapter != chapter) _jumpTargetSpan = null;',
        ),
      );
    });

    test('source review banner is an overlay counted in the top inset', () {
      expect(
        page,
        isNot(contains('appBar: _sourceReviewSession')),
        reason:
            'Scaffold.appBar 把 WebView 压矮一个横幅，而 dartPageHeight 仍是全窗 '
            'MediaQuery 高度，页底那一条排到 WebView 之外（「底下文字看不见」）',
      );
      final int banner = page.indexOf("'reader_source_review_banner'");
      expect(banner, greaterThanOrEqualTo(0));
      expect(
        page.substring(banner, page.indexOf('SourceReviewBanner(', banner)),
        contains('height: _topChromeInset'),
      );
      final int content = page.indexOf('double get _contentTopInset =>');
      expect(
        page.substring(content, page.indexOf(';', content)),
        contains('_topChromeInset'),
      );
      expect(page, contains('double get popupTopReserve => _topChromeInset;'));
    });
  });
}
