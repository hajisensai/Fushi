@Tags(<String>['chrome'])
library;

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

/// 复习页答案面窄屏「展开全文」（11-20 用户与所有者拍板：「这里一条都可以点击」「按钮砍掉吧，
/// 应该弄成只文字」）：内置 Fushi 卡片模板里的 `.fc-clamp-toggle` 是横跨释义整宽的一条纯文字
/// 行——无填充底色、无胶囊外形，整条都能点，键盘（Tab + Enter）能触发，按下 / 悬停有轻量
/// 高亮，周围不再垫白底。真实 headless Chrome 里跑生产外壳 + 释义页（与复习页窄版式同形）。
const SrsCardLabels _labels = SrsCardLabels(
  allDefinitions: 'all',
  frequency: 'freq',
  source: 'src',
  showMore: '展开全文',
);

/// 足够长、窄屏一定会被收起的主释义。
final String _longMain = List<String>.filled(
  40,
  '人のあとに出てそのまねをすること。特に、前の人と同じ失敗をくり返すこと。',
).join('<br>');

String _block(String css, String selector) {
  final RegExpMatch m = RegExp(
    '(^|\\n)${RegExp.escape(selector)} \\{([^}]*)\\}',
  ).firstMatch(css)!;
  return m.group(2)!;
}

SrsCardFaceDocument _doc({required Brightness brightness}) {
  const SrsCardAppearance appearance = SrsCardAppearance();
  final Map<String, String> fields = <String, String>{
    ...srsSampleCardFields(),
    'MainDefinition': _longMain,
  };
  final String defs = renderAnkiCard(
    questionTemplate: FushiCardNoteType.template.front,
    answerTemplate: kFushiCardDefinitionsTemplate,
    noteFields: fields,
    cardOrd: 0,
    isCloze: false,
  ).answer;
  const SrsDefsLayoutConfig config = SrsDefsLayoutConfig(
    columns: 2,
    autoExpandRows: 1,
    collapseDictionaries: true,
    collapsedDictionaryNames: <String>[],
    expandedDictionaryNames: <String>[],
    mainLabel: 'Main',
    othersLabel: 'Others',
    expandAllLabel: 'Expand all',
    collapseAllLabel: 'Collapse all',
    mainCollapseLabel: 'Collapse main',
    mainExpandLabel: 'Expand main',
    uiLanguageTag: 'zh-CN',
  );
  return srsCardFaceDocumentFor(
    SrsCardFace(
      cardId: 'c1#defs',
      showingAnswer: true,
      bodyHtml: defs,
      css: FushiCardNoteType.template.css,
      languageCode: 'ja',
      onBridgeKey: (_) {},
      layout: SrsCardLayout.narrow,
      fushiCard: true,
      // 与 SrsFushiCardView._defsFace 窄版式同形：收起高度由宿主按外层视口给像素值。
      hostCss:
          '.fc.fc-back.fc-defs-only{flex-direction:column;align-items:stretch;'
          'max-width:none;margin:0;}:root{--fushi-srs-clamp:320px;}'
          '${srsDefsLayoutCss(config)}${srsDefsAppearanceCss(appearance)}',
      hostScript: kSrsDefsLayoutScript,
    ),
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      ),
    ),
    appearance: appearance,
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

  test('模板样式：纯文字整行，没有填充底色、没有胶囊外形、命中区 ≥48px', () {
    const String css = kFushiCardStylingCss;
    final String rule = _block(css, '.fc-clamp-toggle');
    expect(rule, contains('background: transparent;'));
    expect(rule, isNot(contains('999px')), reason: '不再是胶囊');
    expect(rule, isNot(contains('secondary-container')), reason: '不再填色');
    expect(rule, contains('width: 100%;'));
    expect(rule, contains('align-self: stretch;'));
    expect(rule, contains('min-height: max(var(--fc-tap), 48px);'));
    expect(rule, contains('color: var(--fc-accent);'));
    expect(rule, contains('transition:'));
    // 向下展开的小箭头；按下 / 键盘焦点有反馈。
    expect(css, contains('.fc-clamp-toggle::after {'));
    expect(css, contains('.fc-clamp-toggle:active {'));
    expect(css, contains('.fc-clamp-toggle:focus-visible {'));
    // 原生 <button>：键盘 / 手柄焦点可达，Enter / 空格触发。
    expect(
      kFushiCardBackTemplate,
      contains('btn = document.createElement("button");'),
    );
  });

  test(
    '真实 Chrome：整条可点、键盘可触发、悬停 / 按下有高亮、周围透明',
    () async {
      final String node = browserRuntime.requireNode();
      final Map<String, Object?> cases = <String, Object?>{
        for (final Brightness b in Brightness.values)
          b.name: () {
            final SrsCardFaceDocument d = _doc(brightness: b);
            return <String, Object?>{
              'shell': d.shellHtml,
              'calls': d.hostScript + d.fullCardScript,
              'label': _labels.showMore,
            };
          }(),
      };
      final String? shotDir = Platform.environment['FUSHI_SRS_EXPAND_SHOT_DIR'];
      final Process proc = await Process.start(node, <String>[
        'test/srs/srs_card_clamp_toggle_harness.mjs',
      ]);
      final Future<String> stdout = proc.stdout.transform(utf8.decoder).join();
      final Future<String> stderr = proc.stderr.transform(utf8.decoder).join();
      proc.stdin.add(
        utf8.encode(
          jsonEncode(<String, Object?>{'cases': cases, 'shotDir': shotDir}),
        ),
      );
      await proc.stdin.close();
      final int exitCode = await proc.exitCode.timeout(
        const Duration(seconds: 80),
        onTimeout: () {
          killProcessTree(proc);
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
