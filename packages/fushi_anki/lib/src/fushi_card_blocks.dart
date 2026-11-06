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

// ---------------------------------------------------------------- 背面区块布局

/// 背面各区块在默认模板（[kFushiCardBackTemplate]）里的原文片段，按显示顺序。
///
/// 「区块布局」只在这些片段上做文章：用户在区块布局编辑里调顺序 / 增删
/// （[fushiCardBackTemplateFor]），或在模板源码里把整段剪切挪位置 / 删掉，片段以外的标记、
/// 脚本与样式都没动——原生卡面按 [fushiCardBackLayoutOf] 认出的顺序照样画。
final Map<FushiCardBlock, String> kFushiCardBackSnippets = _backSnippets();

Map<FushiCardBlock, String> _backSnippets() {
  const String t = kFushiCardBackTemplate;
  String cut(String start, String end) {
    final int s = t.indexOf(start);
    final int e = s < 0 ? -1 : t.indexOf(end, s + start.length);
    if (e < 0) {
      throw StateError('Fushi Card back template lost block "$start"');
    }
    return t.substring(s, e + end.length);
  }

  return <FushiCardBlock, String>{
    FushiCardBlock.term: cut('<div class="fc-term">', '</div>'),
    FushiCardBlock.reading: cut('<div class="fc-reading-row">', '</div>'),
    FushiCardBlock.picture: cut('{{#Media}}', '{{/Media}}'),
    FushiCardBlock.sentence: cut('{{#Sentence}}', '{{/Sentence}}'),
    FushiCardBlock.definitions: cut('<section class="fc-defs">', '</section>'),
    FushiCardBlock.frequency: cut('{{#Frequency}}', '{{/Frequency}}'),
    FushiCardBlock.source: cut('{{#Source}}', '{{/Source}}'),
  };
}

final RegExp _comment = RegExp(r'<!--[\s\S]*?-->');
final RegExp _space = RegExp(r'\s+');
final RegExp _spaceAroundTag = RegExp(r' ?(<|>|\{\{|\}\}) ?');

/// 比较用的规范形：去掉 HTML 注释、空白折成一个空格、标签 / 花括号两侧的空白去掉
/// （缩进、换行不同不算改了模板）。
String _norm(String s) => s
    .replaceAll(_comment, '')
    .replaceAll(_space, ' ')
    .replaceAllMapped(_spaceAroundTag, (Match m) => m.group(1)!)
    .trim();

final Map<FushiCardBlock, String> _normSnippets = <FushiCardBlock, String>{
  for (final MapEntry<FushiCardBlock, String> e
      in kFushiCardBackSnippets.entries)
    e.key: _norm(e.value),
};

/// 默认背面去掉全部区块片段后的「骨架」（规范形）。
final String _normSkeleton = _skeletonOf(_norm(kFushiCardBackTemplate))!.rest;

/// 在规范形 [u] 里找各区块片段：每段至多出现一次、互不重叠。返回去掉片段后的骨架与各区块
/// 的位置；片段重复或重叠返回 null。
({String rest, Map<FushiCardBlock, int> at})? _skeletonOf(String u) {
  final List<({FushiCardBlock block, int start, int end})> found =
      <({FushiCardBlock block, int start, int end})>[];
  for (final MapEntry<FushiCardBlock, String> e in _normSnippets.entries) {
    final int i = u.indexOf(e.value);
    if (i < 0) continue;
    if (u.indexOf(e.value, i + 1) >= 0) return null;
    found.add((block: e.key, start: i, end: i + e.value.length));
  }
  found.sort((a, b) => a.start.compareTo(b.start));
  final StringBuffer rest = StringBuffer();
  int cursor = 0;
  for (final ({FushiCardBlock block, int start, int end}) f in found) {
    if (f.start < cursor) return null;
    rest.write(u.substring(cursor, f.start));
    cursor = f.end;
  }
  rest.write(u.substring(cursor));
  return (
    rest: rest.toString(),
    at: <FushiCardBlock, int>{
      for (final ({FushiCardBlock block, int start, int end}) f in found)
        f.block: f.start,
    },
  );
}

/// 背面模板 [back]（名字形式）是不是默认背面的「区块布局」变体：只调了区块顺序、删了
/// 某些区块（含缩进 / 注释差异），其余标记与脚本原样。是则返回自上而下的区块顺序（删掉的
/// 区块不在里面），否则 null（改了区块内部或骨架，原生卡面画不出来）。
List<FushiCardBlock>? fushiCardBackLayoutOf(String back) {
  final ({String rest, Map<FushiCardBlock, int> at})? s = _skeletonOf(
    _norm(back),
  );
  if (s == null || s.rest != _normSkeleton) return null;
  final List<FushiCardBlock> order = s.at.keys.toList()
    ..sort(
      (FushiCardBlock a, FushiCardBlock b) => s.at[a]!.compareTo(s.at[b]!),
    );
  return List<FushiCardBlock>.unmodifiable(order);
}

/// 正面 / 样式是否与默认一致（规范形比较：缩进、注释不同不算改）。
bool fushiCardFrontIsDefault(String front) => _norm(front) == _normDefaultFront;

final String _normDefaultFront = _norm(kFushiCardFrontTemplate);

/// 样式表是否与默认一致（空白差异不算改）。
bool fushiCardCssIsDefault(String css) =>
    css.replaceAll(_space, ' ').trim() == _normDefaultCss;

final String _normDefaultCss = kFushiCardStylingCss
    .replaceAll(_space, ' ')
    .trim();

/// 按区块顺序 [blocks] 生成背面模板：默认背面里各区块原本的位置（槽）依次放入 [blocks]
/// 的片段，多出的槽留空。生成的模板一定被 [fushiCardBackLayoutOf] 认回同一顺序，Anki
/// 里也照常可用（骨架、脚本、样式都不变）。
String fushiCardBackTemplateFor(List<FushiCardBlock> blocks) {
  const String t = kFushiCardBackTemplate;
  final List<({int start, int end})> slots = <({int start, int end})>[
    for (final String snip in kFushiCardBackSnippets.values)
      (start: t.indexOf(snip), end: t.indexOf(snip) + snip.length),
  ]..sort((a, b) => a.start.compareTo(b.start));
  final List<FushiCardBlock> unique = blocks.toSet().toList();
  final StringBuffer out = StringBuffer();
  int cursor = 0;
  for (int i = 0; i < slots.length; i++) {
    out.write(t.substring(cursor, slots[i].start));
    if (i < unique.length) out.write(kFushiCardBackSnippets[unique[i]]);
    cursor = slots[i].end;
  }
  out.write(t.substring(cursor));
  return out.toString();
}
