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

/// 高亮条一律一个字高（用户 2026-10-15「所有字体都要一个字高」）。
///
/// 真 Chrome 跑生产 CSS + 引擎 shell（分页 / 连续 / VN）× 横竖排：有声书当前句被注音拆成
/// 多个 wrapper 时每行仍是一条 1em 窄条且盖住整行基字、不留补缝阴影；查词（文字 + ruby
/// 分流 class）、收藏、搜索都是 1em 居中窄条；叠放 当前句 < 收藏 < 搜索 < 查词（BUG-125）；
/// 各路径自身不再铺整盒背景。WebKit 那一侧（含 13 款目录字体与系统字体的逐字体墨迹实测）
/// 在 Mac WKWebView 上做过，见 PR 描述。
///
/// BUG-3421：书自带底色的段落里，窄条画在书的底色之上、字之下（真截图取像素：窄条范围里
/// 不再露出裸底色，字仍压在窄条上），高亮撤掉后挂上的层与标记一并撤。行内元素的底色压不住
/// （Chromium 把行内底色随行内容一起画），只钉住「不给它挂层」，见 harness 注释。
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
    bool backdrop = false,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode(writingMode);
    await settings.setViewMode(viewMode);
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
        // 书自带的段落底色与行内底色（出版社 CSS，不带 !important）。
        '${backdrop ? '<style>p.bd { background-color: rgb(60, 200, 120); } '
                  'span.mk { background-color: rgb(240, 130, 60); }</style>' : ''}'
        '<script>window.flutter_inappwebview = { callHandler: function() '
        '{ return Promise.resolve(null); } };'
        'window.__fushiApplyReaderMargins = function() {};</script>'
        '</head><body><p>$p1</p>'
        '${backdrop ? '<p class="bd">${p2.replaceFirst('窓の外', '<span class="mk">窓の外</span>')}</p>' : '<p>$p2</p>'}'
        '<script>${ReaderSelectionScripts.source()}</script>$engine'
        '<script>window.__fushiInstallShell(${jsonEncode(config)});</script>'
        '</body></html>';
  }

  test(
    'every highlight is a 1em lane: current sentence, lookup, favourite, search',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final List<Map<String, String>> pages = <Map<String, String>>[];
      final List<Map<String, String>> backdropPages = <Map<String, String>>[];
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
          backdropPages.add(<String, String>{
            'name': '$writingMode/$viewMode/book-background',
            'html': await page(
              writingMode: writingMode,
              viewMode: viewMode,
              backdrop: true,
            ),
          });
        }
      }
      final Directory temp = Directory.systemTemp.createTempSync(
        'highlight-lanes-',
      );
      try {
        final File payload = File('${temp.path}/pages.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object>{
              'pages': pages,
              'backdropPages': backdropPages,
            }),
          );
        final Process process = await Process.start(nodeExe, <String>[
          'test/reader/highlight_lanes_harness.mjs',
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
        expect(out, contains('PASS 6 lane pages'));
        expect(out, contains('6 book-background pages'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );

  test('JS lane thickness is the Dart constant', () {
    final RegExp laneEm = RegExp(r'var LANE_EM = ([0-9.]+);');
    final Match? match = laneEm.firstMatch(ReaderSelectionScripts.source());
    expect(match, isNotNull);
    expect(double.parse(match!.group(1)!), ReaderContentStyles.highlightLaneEm);
  });

  test(
    'reader CSS colours every lane group and e-ink hides the layer',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      final String css = ReaderContentStyles.css(settings: settings);
      for (final String group in <String>[
        'fushi-sentence-audio',
        'fushi-search',
        'fushi-selection',
        'fushi-hl-yellow',
        'fushi-hl-green',
        'fushi-hl-blue',
        'fushi-hl-pink',
        'fushi-hl-purple',
      ]) {
        expect(
          css,
          contains('fushi-hl-lane[data-hl="$group"]'),
          reason: 'lane colour for $group',
        );
      }
      final String eink = ReaderContentStyles.css(
        settings: settings,
        einkMode: true,
      );
      final int hide = eink.lastIndexOf('fushi-hl-lanes {');
      expect(hide, greaterThan(0));
      expect(
        eink.substring(hide, eink.indexOf('}', hide)),
        contains('display: none'),
      );
    },
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
