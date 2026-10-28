import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_defs_layout.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';

/// 复习页混合渲染的释义页排版（srs_card_defs_layout.dart）：
/// - 宿主 CSS 的参数变量 / 转义 / 钳位；
/// - 外壳在卡片脚本跑完后、换主题后调宿主排版钩子，`SrsCardFace.hostScript` 随主题下发；
/// - 真实 Chrome 里跑生产外壳 + 内置 Fushi 卡片释义页：主词典通栏带标记、其他词典分列，
///   展开规则与查词弹窗同序（逐本折叠 > 自动展开行数 × 列数 > 全局折叠开关）。
const SrsCardLabels _labels = SrsCardLabels(
  allDefinitions: 'all',
  frequency: 'freq',
  source: 'src',
);

/// 主词典之外 4 本（Fushi 制卡写进 Glossary 的形状）。
const String _glossary =
    '<div class="yomitan-glossary" style="text-align: left;"><ol>'
    '<li data-dictionary="DictA"><i>(n, DictA)</i> <span>a1</span></li>'
    '<li data-dictionary="DictA"><i>(n)</i> <span>a2</span></li>'
    '<li data-dictionary="DictB"><i>(DictB)</i> <span>b</span></li>'
    '<li data-dictionary="DictC"><i>(DictC)</i> <span>c</span></li>'
    '<li data-dictionary="DictD"><i>(DictD)</i> <span>d</span></li>'
    '</ol></div>';

SrsDefsLayoutConfig _config({
  int columns = 2,
  int rows = 1,
  bool collapse = true,
  List<String> folded = const <String>[],
  List<String> unfolded = const <String>[],
}) => SrsDefsLayoutConfig(
  columns: columns,
  autoExpandRows: rows,
  collapseDictionaries: collapse,
  collapsedDictionaryNames: folded,
  expandedDictionaryNames: unfolded,
  mainLabel: 'Main',
  othersLabel: 'Others',
  expandAllLabel: 'Expand all',
  collapseAllLabel: 'Collapse all',
  uiLanguageTag: 'zh-CN',
);

/// 与 SrsFushiCardView._defsFace 同形的释义页文档。[glossExpanded] = 卡面外观「默认展开
/// 全部释义」。
SrsCardFaceDocument _doc(
  SrsDefsLayoutConfig config, {
  bool withMain = true,
  bool glossExpanded = false,
}) {
  final Map<String, String> fields = <String, String>{
    ...srsSampleCardFields(),
    'Glossary': _glossary,
    if (!withMain) 'MainDefinition': '',
  };
  final String defs = renderAnkiCard(
    questionTemplate: FushiCardNoteType.template.front,
    answerTemplate: kFushiCardDefinitionsTemplate,
    noteFields: fields,
    cardOrd: 0,
    isCloze: false,
  ).answer;
  return srsCardFaceDocumentFor(
    SrsCardFace(
      cardId: 'c1#defs',
      showingAnswer: true,
      bodyHtml: defs,
      css: FushiCardNoteType.template.css,
      languageCode: 'ja',
      onBridgeKey: (_) {},
      layout: SrsCardLayout.wide,
      fushiCard: true,
      hostCss:
          '.fc.fc-back.fc-defs-only{flex-direction:column;align-items:stretch;'
          'max-width:none;margin:0;}${srsDefsLayoutCss(config)}',
      hostScript: kSrsDefsLayoutScript,
    ),
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    ),
    appearance: SrsCardAppearance(glossaryExpanded: glossExpanded),
    labels: _labels,
    mediaUrlPrefix: 'https://srs.local/media/',
    themedScrollbar: false,
    fontUrl: (String path) => path,
  );
}

void main() {
  final NodeTestRuntime browserRuntime = NodeTestRuntime.probe(
    needsChrome: true,
  );

  group('宿主 CSS', () {
    test('参数变量；列数 / 行数钳位；逐本折叠的词典名转义进属性选择器', () {
      final String css = srsDefsLayoutCss(
        _config(
          columns: 9,
          rows: 99,
          folded: <String>['A "B" \\ C'],
          unfolded: <String>['E'],
        ),
      );
      expect(css, contains('--fushi-srs-dict-cols:4;'));
      expect(css, contains('--fushi-srs-dict-rows:6;'));
      expect(css, contains('--fushi-srs-dict-collapse:1;'));
      expect(css, contains('--fushi-srs-label-main:"Main";'));
      expect(css, contains('--fushi-srs-ui-lang:"zh-CN";'));
      expect(css, contains('--fushi-srs-label-expand-all:"Expand all";'));
      expect(css, contains('--fushi-srs-label-collapse-all:"Collapse all";'));
      expect(
        css,
        contains(
          r'.fc-dict[data-fc-dict="A \"B\" \\ C"]{--fushi-srs-dict-folded:1;}',
        ),
      );
      expect(
        css,
        contains('.fc-dict[data-fc-dict="E"]{--fushi-srs-dict-unfolded:1;}'),
      );
      expect(
        srsDefsLayoutCss(_config(columns: 0, collapse: false)),
        allOf(
          contains('--fushi-srs-dict-cols:1;'),
          contains('--fushi-srs-dict-collapse:0;'),
        ),
      );
    });
  });

  group('外壳接线', () {
    test('卡片钩子与设计系统判定之后、换主题派发事件之后都调宿主排版钩子', () {
      final int finish = kSrsCardShellScript.indexOf('function finish(');
      final int skin = kSrsCardShellScript.indexOf('designSkin();', finish);
      final int host = kSrsCardShellScript.indexOf('hostLayout();', finish);
      expect(skin, greaterThan(finish));
      expect(host, greaterThan(skin));
      final int setTheme = kSrsCardShellScript.indexOf(
        'window.__fushiSrsSetTheme = function',
      );
      final int event = kSrsCardShellScript.indexOf(
        'fushi-srs-theme',
        setTheme,
      );
      expect(
        kSrsCardShellScript.indexOf('hostLayout();', setTheme),
        greaterThan(event),
      );
    });

    test('分列参数与查词弹窗同值', () {
      expect(
        kSrsDefsLayoutScript,
        contains('MIN_COL = $kSrsDefsMinColumnWidth'),
      );
      expect(kSrsDefsLayoutScript, contains('GAP = 6, COLLAPSED_GAP = 4'));
      final String popup = File('assets/popup/popup.js').readAsStringSync();
      expect(
        popup,
        contains('DICT_COLUMN_MIN_WIDTH = $kSrsDefsMinColumnWidth;'),
      );
      expect(
        popup,
        matches(
          RegExp(r'function masonryGap\(\) \{[\s\S]{0,200}?return 6;\s*\}'),
        ),
      );
      expect(
        popup,
        matches(
          RegExp(
            r'function masonryCollapsedRowGap\(\) \{[\s\S]{0,200}?return 4;\s*\}',
          ),
        ),
      );
    });

    test('SrsCardFace.hostScript 随主题下发；参数只在主题样式里', () {
      final SrsCardFaceDocument d = _doc(_config());
      expect(d.hostScript, contains('window.__fushiSrsHostLayout = apply;'));
      expect(d.themeCss, contains('--fushi-srs-dict-cols:2;'));
      expect(kSrsDefsLayoutScript, isNot(contains('--fushi-srs-dict-cols:')));
    });
  });

  test(
    '真实 Chrome：主词典通栏带标记、其他词典分列，展开规则与查词弹窗同序',
    () async {
      final String node = browserRuntime.requireNode();
      Map<String, Object?> page(
        SrsDefsLayoutConfig config,
        List<bool> open, {
        bool withMain = true,
        bool glossExpanded = false,
        int cols = 2,
        List<int>? columnOf,
      }) {
        final SrsCardFaceDocument d = _doc(
          config,
          withMain: withMain,
          glossExpanded: glossExpanded,
        );
        return <String, Object?>{
          'shell': d.shellHtml,
          'calls': d.hostScript + d.fullCardScript,
          'host': d.hostScript,
          'open': open,
          'cols': cols,
          'main': withMain,
          'columnOf': columnOf,
        };
      }

      final Map<String, Object?> cases = <String, Object?>{
        // 默认 1 行：主词典占满第一行，其他词典全部收成标题。
        'rows 1': page(_config(), <bool>[false, false, false, false]),
        // 2 行：再展开一整行（= 列数 2 本）。DictA 两条释义比 DictB 高，收起的 DictC 进较矮的
        // 第 2 列（查词弹窗的最短列瀑布流；按行排的网格会把它放回第 1 列、留出空洞）。
        'rows 2': page(
          _config(rows: 2),
          <bool>[true, true, false, false],
          columnOf: <int>[0, 1, 1],
        ),
        // 词典管理里逐本折叠的优先于自动展开（BUG-1264 同序）。
        'folded wins': page(_config(rows: 2, folded: <String>['DictB']), <bool>[
          true,
          false,
          false,
          false,
        ]),
        // 词典管理里逐本显式展开的：自动展开窗口外也展开（BUG-2158 三态，与查词弹窗同序）。
        'unfolded outside budget': page(
          _config(unfolded: <String>['DictC']),
          <bool>[false, false, true, false],
        ),
        // 显式展开压过显式折叠与自动展开行数。
        'unfolded beats folded': page(
          _config(
            rows: 2,
            folded: <String>['DictB'],
            unfolded: <String>['DictD'],
          ),
          <bool>[true, false, false, true],
        ),
        // 全局「折叠词典显示」关：全部展开（逐本折叠的照样收起）。
        'collapse off': page(
          _config(collapse: false, folded: <String>['DictC']),
          <bool>[true, true, false, true],
        ),
        // 卡面外观「默认展开全部释义」开：压过自动展开行数，与全局折叠开关关同样全部展开
        // （逐本折叠的照样收起）。
        'gloss expanded': page(_config(folded: <String>['DictC']), <bool>[
          true,
          true,
          false,
          true,
        ], glossExpanded: true),
        // 列数 1：2 行只多展开 1 本。
        'one column': page(_config(columns: 1, rows: 2), <bool>[
          true,
          false,
          false,
          false,
        ], cols: 1),
        // 没有主释义：第一本通栏当主词典，1 行 = 只展开它。
        'no main': page(_config(), <bool>[
          true,
          false,
          false,
          false,
        ], withMain: false),
      };
      // 用例经 stdin 交给 harness（不传文件路径）。
      final Process proc = await Process.start(node, <String>[
        'test/srs/srs_card_defs_layout_harness.mjs',
      ]);
      final Future<String> stdout = proc.stdout.transform(utf8.decoder).join();
      final Future<String> stderr = proc.stderr.transform(utf8.decoder).join();
      proc.stdin.add(utf8.encode(jsonEncode(cases)));
      await proc.stdin.close();
      final int exitCode = await proc.exitCode.timeout(
        const Duration(seconds: 80),
        onTimeout: () {
          proc.kill();
          return -1;
        },
      );
      final String out = await stdout;
      expect(exitCode, 0, reason: '$out\n${await stderr}');
      expect(out, contains('PASS ${cases.length} browser cases'));
    },
    skip: browserRuntime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
