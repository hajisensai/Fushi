/// 「Fushi 卡片」背面的区块 → 字段映射：原生渲染（Fushi 复习页）与导出 HTML 模板
/// （templates/fushi_card/back.html）共用的**单一真相源**。
///
/// 顺序就是背面自上而下的显示顺序（窄屏单栏）；`definitionArea` 为 true 的区块是释义区，
/// Fushi 复习页里由 WebView 渲染（词典 HTML 原样），其余区块原生渲染。测试保证模板里各字段
/// 的首次出现顺序与这里一致，两条渲染路径不会显示不同的字段集合 / 顺序。
library;

import 'fushi_card_template_data.dart';

/// 背面的一个区块。
enum FushiCardBlock {
  /// 词条（带振假名）。
  term(<String>['TermFurigana', 'Term']),

  /// 读音 + 音调 + 单词音频 + 词频序位（标题区第二行）。
  reading(<String>[
    'TermReading',
    'PitchPosition',
    'TermAudio',
    'FrequencyRank',
  ]),

  /// 图片。
  picture(<String>['Media']),

  /// 例句 + 例句翻译 + 例句音频。
  sentence(<String>['Sentence', 'SentenceTranslation', 'SentenceAudio']),

  /// 释义区：选中文本、释义图片、主释义、全部释义。
  definitions(<String>[
    'LookupSelection',
    'DefinitionMedia',
    'MainDefinition',
    'Glossary',
  ], definitionArea: true),

  /// 词频列表。
  frequency(<String>['Frequency']),

  /// 来源。
  source(<String>['Source']);

  const FushiCardBlock(this.fields, {this.definitionArea = false});

  /// 区块用到的字段（显示顺序）。
  final List<String> fields;

  /// 是否属于释义区（Fushi 复习页里用 WebView 渲染）。
  final bool definitionArea;
}

/// 背面的区块（显示顺序）。
const List<FushiCardBlock> kFushiCardBackBlocks = FushiCardBlock.values;

/// 释义区字段（WebView 渲染）。
final List<String> kFushiCardDefinitionFields = <String>[
  for (final FushiCardBlock b in kFushiCardBackBlocks)
    if (b.definitionArea) ...b.fields,
];

/// 只控制卡型、不直接显示的字段（正面用）。
const List<String> kFushiCardSwitchFields = <String>[
  'IsWordAndSentenceCard',
  'IsClickCard',
  'IsSentenceCard',
  'IsAudioCard',
];

/// 只辅助其它区块、不单独成块的字段（音调分类给音调着色；提示只在正面）。
const List<String> kFushiCardAuxFields = <String>['PitchCategories', 'Hint'];

/// 为与 Lapis 同名同序留在笔记类型里、但卡面不读的字段（例句注音句由所有者 2026-10-28
/// 拍板删除：例句只显示 `Sentence` 自带的注音）。
const List<String> kFushiCardUnusedFields = <String>['SentenceFurigana'];

/// 释义区单独渲染用的背面子模板：取自背面模板（[kFushiCardBackTemplate]）的释义区与脚本，
/// 根节点多一个 `fc-defs-only` 类（样式表据此取消双栏网格）。Fushi 复习页的混合渲染里，
/// 词条 / 读音 / 例句 / 词频 / 来源由原生绘制，只有这一段进 WebView；导出给 Anki 的模板不变。
final String kFushiCardDefinitionsTemplate = _definitionsTemplate();

String _definitionsTemplate() {
  const String t = kFushiCardBackTemplate;
  final int start = t.indexOf('<section class="fc-defs">');
  final int end = t.indexOf('<footer class="fc-foot">');
  final int script = t.indexOf('<script>');
  if (start < 0 || end < start || script < end) {
    throw StateError('Fushi Card back template lost its definitions section');
  }
  return '<div class="fc fc-back fc-defs-only" lang="ja">\n'
      '  ${t.substring(start, end).trim()}\n'
      '</div>\n\n'
      '${t.substring(script)}';
}
