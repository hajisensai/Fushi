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
final String kFushiCardDefinitionsTemplate = fushiCardDefinitionsTemplateFor(
  FushiCardBlockItem(FushiCardBlock.definitions),
);

// ---------------------------------------------------------------- 区块布局
//
// 「区块布局」：Fushi 卡片正面 / 背面由一串区块组成，用户可以调顺序、增删、改内置区块的
// 选项，也可以加自己的「字段区块」「HTML 区块」。**模板本身就是唯一的数据来源**：每个区块
// 在模板里是一个带 `data-fc-block` 标记的元素（连同紧包着它的 `{{#字段}}…{{/字段}}`），选项
// 写成 `data-fc-opt-<名字>` 属性；不另存一份布局数据。原生卡面按 [fushiCardLayoutOf] 从模板
// 读出区块来画，Anki 照常渲染同一份 HTML。
//
// 识别规则：去掉全部区块后的「骨架」必须与默认模板的骨架一致（缩进、注释不算）；每个区块按
// 它的标记与选项重新生成一遍，与模板里那段一致就是结构化区块（原生直接画），不一致（在源码
// 里随手改了区块内部）就当成 HTML 区块，交给原生 HTML 渲染器。

/// 卡片的哪一面。
enum FushiCardSide { front, back }

/// 正面的内置区块（显示顺序）。
enum FushiCardFrontBlock {
  /// 词频序位角标（外观里开了「正面显示词频」才显示）。
  frequency,

  /// 卡型决定的题面：单词 / 例句 / 单词 + 例句 / 点击 / 听力。
  prompt,

  /// 提示。
  hint,
}

/// 内置区块选项的类型。
enum FushiCardOptionKind {
  /// 开关：`'1'` 开、`'0'` 关。
  toggle,

  /// 文字（空 = 用默认）。
  text,
}

/// 内置区块的一个选项。
class FushiCardBlockOption {
  const FushiCardBlockOption(this.name, this.kind, {this.defaultValue = ''});

  /// 选项名（模板属性 `data-fc-opt-<name>`）。
  final String name;
  final FushiCardOptionKind kind;

  /// 默认值：等于默认值的选项不写进模板。
  final String defaultValue;
}

FushiCardBlockOption _toggle(String name, {bool on = true}) =>
    FushiCardBlockOption(
      name,
      FushiCardOptionKind.toggle,
      defaultValue: on ? '1' : '0',
    );

/// 读音行：音调图、单词发音键、词频角标。
const String kFushiOptPitch = 'pitch';
const String kFushiOptAudio = 'audio';
const String kFushiOptFreq = 'freq';

/// 例句：翻译。
const String kFushiOptTranslation = 'translation';

/// 释义：默认展开全部释义。
const String kFushiOptExpand = 'expand';

/// 词频 / 来源：标签文字。
const String kFushiOptLabel = 'label';

/// 内置区块 [block]（[FushiCardBlock] 或 [FushiCardFrontBlock]）可调的选项。
List<FushiCardBlockOption> fushiCardBlockOptions(Enum block) => switch (block) {
  FushiCardBlock.reading => <FushiCardBlockOption>[
    _toggle(kFushiOptPitch),
    _toggle(kFushiOptAudio),
    _toggle(kFushiOptFreq),
  ],
  FushiCardBlock.sentence => <FushiCardBlockOption>[
    _toggle(kFushiOptTranslation),
    _toggle(kFushiOptAudio),
  ],
  FushiCardBlock.definitions => <FushiCardBlockOption>[
    _toggle(kFushiOptExpand, on: false),
  ],
  FushiCardBlock.frequency ||
  FushiCardBlock.source => const <FushiCardBlockOption>[
    FushiCardBlockOption(kFushiOptLabel, FushiCardOptionKind.text),
  ],
  FushiCardFrontBlock.prompt => <FushiCardBlockOption>[_toggle(kFushiOptPitch)],
  _ => const <FushiCardBlockOption>[],
};

FushiCardBlockOption? _optionOf(Enum block, String name) {
  for (final FushiCardBlockOption o in fushiCardBlockOptions(block)) {
    if (o.name == name) return o;
  }
  return null;
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 区块布局里的一项。
sealed class FushiCardItem {
  const FushiCardItem();

  /// 远端协议用的 JSON。
  Map<String, Object?> toJson();

  /// [toJson] 的逆；认不出时 null（新对端多出来的种类，旧端跳过）。
  static FushiCardItem? fromJson(Object? json) {
    if (json is! Map) return null;
    switch (json['t']) {
      case 'b':
        final Enum? block = json['s'] == 'front'
            ? FushiCardFrontBlock.values.asNameMap()[json['b']]
            : FushiCardBlock.values.asNameMap()[json['b']];
        if (block == null) return null;
        final Object? o = json['o'];
        return FushiCardBlockItem(
          block,
          options: <String, String>{
            if (o is Map)
              for (final MapEntry<Object?, Object?> e in o.entries)
                if (e.key is String && e.value is String)
                  e.key! as String: e.value! as String,
          },
        );
      case 'f':
        final Object? field = json['f'];
        if (field is! String) return null;
        return FushiCardFieldItem(
          field: field,
          style:
              FushiCardFieldStyle.values.asNameMap()[json['y']] ??
              FushiCardFieldStyle.body,
          title: json['n'] is String ? json['n']! as String : '',
        );
      case 'h':
        final Object? html = json['h'];
        if (html is! String) return null;
        return FushiCardHtmlItem(html, wrapped: json['w'] != false);
    }
    return null;
  }
}

/// 内置区块（[block] 是 [FushiCardBlock] 或 [FushiCardFrontBlock]）及其选项。
final class FushiCardBlockItem extends FushiCardItem {
  FushiCardBlockItem(
    this.block, {
    Map<String, String> options = const <String, String>{},
  }) : assert(block is FushiCardBlock || block is FushiCardFrontBlock),
       options = _normalizeOptions(block, options);

  /// 只留这个区块认得的、与默认值不同的选项（开关规整成 `'1'` / `'0'`）。
  static Map<String, String> _normalizeOptions(
    Enum block,
    Map<String, String> raw,
  ) {
    final Map<String, String> out = <String, String>{};
    for (final FushiCardBlockOption o in fushiCardBlockOptions(block)) {
      final String? given = raw[o.name];
      if (given == null) continue;
      final String v = o.kind == FushiCardOptionKind.text
          ? _cleanText(given)
          : (given == '1' ? '1' : '0');
      if (v != o.defaultValue) out[o.name] = v;
    }
    return Map<String, String>.unmodifiable(out);
  }

  final Enum block;

  /// 与默认值不同的选项（名字 → 值）。
  final Map<String, String> options;

  FushiCardSide get side =>
      block is FushiCardFrontBlock ? FushiCardSide.front : FushiCardSide.back;

  /// 开关选项 [name] 的当前值（不是这个区块的选项时 true）。
  bool flag(String name) {
    final FushiCardBlockOption? o = _optionOf(block, name);
    if (o == null) return true;
    return (options[name] ?? o.defaultValue) == '1';
  }

  /// 文字选项 [name] 的当前值（空 = 默认）。
  String text(String name) => options[name] ?? '';

  /// 改一个选项后的新区块。
  FushiCardBlockItem withOption(String name, String value) =>
      FushiCardBlockItem(
        block,
        options: <String, String>{...options, name: value},
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'b',
    's': side.name,
    'b': block.name,
    if (options.isNotEmpty) 'o': options,
  };

  @override
  bool operator ==(Object other) =>
      other is FushiCardBlockItem &&
      other.block == block &&
      _mapEquals(other.options, options);

  @override
  int get hashCode => Object.hash(
    block,
    Object.hashAllUnordered(
      options.entries.map(
        (MapEntry<String, String> e) => Object.hash(e.key, e.value),
      ),
    ),
  );

  @override
  String toString() => 'FushiCardBlockItem(${block.name}, $options)';
}

/// 字段区块的显示样式。
enum FushiCardFieldStyle {
  /// 正文。
  body,

  /// 标签（小胶囊）。
  tag,

  /// 引用卡片（与例句卡同底色）。
  quote,

  /// 小字（次要色）。
  small,
}

/// 字段区块：一个字段 + 显示样式 + 可选标题。字段为空时整块不显示（与模板条件段同义）。
final class FushiCardFieldItem extends FushiCardItem {
  FushiCardFieldItem({
    required this.field,
    this.style = FushiCardFieldStyle.body,
    String title = '',
  }) : title = _cleanText(title);

  /// 字段名。
  final String field;
  final FushiCardFieldStyle style;

  /// 标题（空 = 不显示标题）。
  final String title;

  FushiCardFieldItem copyWith({
    String? field,
    FushiCardFieldStyle? style,
    String? title,
  }) => FushiCardFieldItem(
    field: field ?? this.field,
    style: style ?? this.style,
    title: title ?? this.title,
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'f',
    'f': field,
    'y': style.name,
    if (title.isNotEmpty) 'n': title,
  };

  @override
  bool operator ==(Object other) =>
      other is FushiCardFieldItem &&
      other.field == field &&
      other.style == style &&
      other.title == title;

  @override
  int get hashCode => Object.hash(field, style, title);

  @override
  String toString() => 'FushiCardFieldItem($field, ${style.name}, $title)';
}

/// HTML 区块：用户自己写的一段 HTML（模板里可带 `{{字段}}`）。
///
/// [wrapped] = 模板里是标准的 `<div class="fc-html" data-fc-block="html">…</div>` 包装、[html]
/// 是里面的内容；false = 认不出的区块原文（在源码里改过内部的内置 / 字段区块），[html] 是
/// 整段原文，写回模板时原样不动。
///
/// 引擎渲染卡片时（`SrsRenderedCard`）[html] 已按笔记字段展开。
final class FushiCardHtmlItem extends FushiCardItem {
  const FushiCardHtmlItem(this.html, {this.wrapped = true});

  final String html;
  final bool wrapped;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'h',
    'h': html,
    if (!wrapped) 'w': false,
  };

  @override
  bool operator ==(Object other) =>
      other is FushiCardHtmlItem &&
      other.html == html &&
      other.wrapped == wrapped;

  @override
  int get hashCode => Object.hash(html, wrapped);

  @override
  String toString() => 'FushiCardHtmlItem(wrapped: $wrapped, $html)';
}

/// 文字选项 / 标题里不许出现模板语法（花括号）与换行。
String _cleanText(String s) => s.replaceAll(RegExp(r'[{}\r\n]'), '').trim();

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _unescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

// ------------------------------------------------ 模板里找区块

/// 模板里的一个区块：`[start, end)` 是整段（含紧包着的 `{{#X}}…{{/X}}`）。
class _Span {
  _Span({
    required this.start,
    required this.end,
    required this.kind,
    required this.attrs,
    required this.inner,
    required this.condition,
  });

  final int start;
  final int end;

  /// `data-fc-block` 的值。
  final String kind;

  /// 标记元素的属性。
  final Map<String, String> attrs;

  /// 标记元素里面的内容。
  final String inner;

  /// 最里层紧包着它的条件段字段名（`{{#X}}` 的 X），没有为 null。
  final String? condition;
}

final RegExp _marker = RegExp(r'''data-fc-block\s*=\s*"([^"]*)"''');
final RegExp _tagName = RegExp(r'<([A-Za-z][A-Za-z0-9-]*)');
final RegExp _attr = RegExp(
  r'''([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*"([^"]*)"''',
);
final RegExp _openCond = RegExp(r'\{\{#([^{}]+)\}\}\s*$');
const Set<String> _voidTags = <String>{'img', 'br', 'hr', 'input', 'source'};

/// 找出模板 [t] 里的全部（顶层）区块。结构坏了（标记不在标签里、标签没闭合）返回 null。
List<_Span>? _spansOf(String t) {
  final List<_Span> out = <_Span>[];
  int pos = 0;
  for (final RegExpMatch m in _marker.allMatches(t)) {
    if (m.start < pos) continue; // 嵌在上一个区块里（HTML 区块里的内容）。
    final int open = t.lastIndexOf('<', m.start);
    if (open < pos) return null;
    final Match? name = _tagName.matchAsPrefix(t, open);
    if (name == null) return null;
    final int tagEnd = t.indexOf('>', m.end);
    if (tagEnd < 0 || t.substring(open, m.start).contains('>')) return null;
    final String tag = name.group(1)!.toLowerCase();
    final Map<String, String> attrs = <String, String>{
      for (final Match a in _attr.allMatches(t.substring(open, tagEnd)))
        a.group(1)!.toLowerCase(): _unescape(a.group(2)!),
    };
    int innerStart = tagEnd + 1;
    int innerEnd = innerStart;
    int end = innerStart;
    if (!_voidTags.contains(tag) && !t.substring(open, tagEnd).endsWith('/')) {
      final RegExp tags = RegExp(
        '<(/?)$tag(?=[\\s>/])[^>]*>',
        caseSensitive: false,
      );
      int depth = 1;
      bool closed = false;
      for (final Match x in tags.allMatches(t, innerStart)) {
        depth += x.group(1)!.isEmpty ? 1 : -1;
        if (depth == 0) {
          innerEnd = x.start;
          end = x.end;
          closed = true;
          break;
        }
      }
      if (!closed) return null;
    }
    int start = open;
    String? condition;
    while (true) {
      final Match? c = _openCond.firstMatch(t.substring(pos, start));
      if (c == null) break;
      final String f = c.group(1)!;
      final Match? close = RegExp(
        '^\\s*\\{\\{/${RegExp.escape(f)}\\}\\}',
      ).matchAsPrefix(t.substring(end));
      if (close == null) break;
      condition ??= f.trim();
      start = pos + c.start;
      end += close.end;
    }
    out.add(
      _Span(
        start: start,
        end: end,
        kind: m.group(1)!,
        attrs: attrs,
        inner: t.substring(innerStart, innerEnd),
        condition: condition,
      ),
    );
    pos = end;
  }
  return out;
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

/// 一面的默认模板、默认区块（按显示顺序）及其原文。
class _SideDefaults {
  _SideDefaults(this.template, List<Enum> blocks) {
    final List<_Span> spans = _spansOf(template)!;
    if (spans.length != blocks.length) {
      throw StateError('Fushi Card template lost a block marker');
    }
    for (int i = 0; i < spans.length; i++) {
      if (spans[i].kind != blocks[i].name) {
        throw StateError('Fushi Card block "${blocks[i].name}" out of place');
      }
      snippets[blocks[i]] = template.substring(spans[i].start, spans[i].end);
      slots.add((start: spans[i].start, end: spans[i].end));
    }
    final StringBuffer rest = StringBuffer();
    int cursor = 0;
    for (final ({int start, int end}) s in slots) {
      rest.write(template.substring(cursor, s.start));
      cursor = s.end;
    }
    rest.write(template.substring(cursor));
    normSkeleton = _norm(rest.toString());
  }

  final String template;
  final Map<Enum, String> snippets = <Enum, String>{};
  final List<({int start, int end})> slots = <({int start, int end})>[];
  late final String normSkeleton;
}

final _SideDefaults _front = _SideDefaults(
  kFushiCardFrontTemplate,
  FushiCardFrontBlock.values,
);
final _SideDefaults _back = _SideDefaults(
  kFushiCardBackTemplate,
  FushiCardBlock.values,
);

_SideDefaults _defaults(FushiCardSide side) =>
    side == FushiCardSide.front ? _front : _back;

/// 默认背面 / 正面的区块布局。
final List<FushiCardItem> kFushiCardDefaultBackItems =
    List<FushiCardItem>.unmodifiable(<FushiCardItem>[
      for (final FushiCardBlock b in FushiCardBlock.values)
        FushiCardBlockItem(b),
    ]);
final List<FushiCardItem> kFushiCardDefaultFrontItems =
    List<FushiCardItem>.unmodifiable(<FushiCardItem>[
      for (final FushiCardFrontBlock b in FushiCardFrontBlock.values)
        FushiCardBlockItem(b),
    ]);

/// 一面的默认区块布局。
List<FushiCardItem> fushiCardDefaultItems(FushiCardSide side) =>
    side == FushiCardSide.front
    ? kFushiCardDefaultFrontItems
    : kFushiCardDefaultBackItems;

/// 选项关掉时从区块原文里去掉的那一段。
String? _optionalPart(Enum block, String option) => switch ((block, option)) {
  (FushiCardBlock.reading, kFushiOptPitch) =>
    '{{#PitchPosition}}<span class="fc-pitch-tags">{{PitchPosition}}</span>{{/PitchPosition}}',
  (FushiCardBlock.reading, kFushiOptAudio) =>
    '{{#TermAudio}}<span class="fc-audio">{{TermAudio}}</span>{{/TermAudio}}',
  (FushiCardBlock.reading, kFushiOptFreq) =>
    '{{#FrequencyRank}}<span class="fc-chip fc-chip--freq">{{FrequencyRank}}</span>{{/FrequencyRank}}',
  (FushiCardBlock.sentence, kFushiOptTranslation) =>
    '{{#SentenceTranslation}}<div class="fc-translation" lang="">{{SentenceTranslation}}</div>{{/SentenceTranslation}}',
  (FushiCardBlock.sentence, kFushiOptAudio) =>
    '{{#SentenceAudio}}<span class="fc-audio">{{SentenceAudio}}</span>{{/SentenceAudio}}',
  (FushiCardFrontBlock.prompt, kFushiOptPitch) =>
    '<div class="fc-front-pitch">{{PitchPosition}}</div>',
  _ => null,
};

/// 词频 / 来源的标签元素。
String _labelElement(Enum block, String label) {
  final String kind = block == FushiCardBlock.frequency ? 'freq' : 'source';
  return label.isEmpty
      ? '<span class="fc-meta-label fc-meta-label--$kind"></span>'
      : '<span class="fc-meta-label fc-meta-label--$kind fc-meta-label--custom">'
            '${_escape(label)}</span>';
}

/// 区块 [item] 在模板里的原文。
String fushiCardItemSnippet(FushiCardItem item) {
  switch (item) {
    case FushiCardBlockItem(
      :final Enum block,
      :final Map<String, String> options,
    ):
      String s = _defaults(item.side).snippets[block]!;
      final String marker = 'data-fc-block="${block.name}"';
      final StringBuffer attrs = StringBuffer();
      for (final FushiCardBlockOption o in fushiCardBlockOptions(block)) {
        final String? v = options[o.name];
        if (v == null) continue;
        attrs.write(' data-fc-opt-${o.name}="${_escape(v)}"');
        if (o.kind == FushiCardOptionKind.toggle && v == '0') {
          final String? part = _optionalPart(block, o.name);
          if (part != null) s = s.replaceAll(part, '');
        }
        if (o.name == kFushiOptLabel) {
          s = s.replaceFirst(_labelElement(block, ''), _labelElement(block, v));
        }
      }
      return s.replaceFirst(marker, '$marker$attrs');
    case FushiCardFieldItem(
      :final String field,
      :final FushiCardFieldStyle style,
      :final String title,
    ):
      final String t = _escape(title);
      return '{{#$field}}<div class="fc-field fc-field--${style.name}" '
          'data-fc-block="field" data-fc-style="${style.name}"'
          '${title.isEmpty ? '' : ' data-fc-title="$t"'}>'
          '${title.isEmpty ? '' : '<div class="fc-field-title">$t</div>'}'
          '<div class="fc-field-body">{{$field}}</div></div>{{/$field}}';
    case FushiCardHtmlItem(:final String html, :final bool wrapped):
      return wrapped
          ? '<div class="fc-html" data-fc-block="html">$html</div>'
          : html;
  }
}

/// 模板里一段区块 [s]（原文 [raw]）对应的布局项；内置区块在 [seen] 里已出现过的按 HTML 区块。
FushiCardItem _itemOf(_Span s, String raw, FushiCardSide side, Set<Enum> seen) {
  FushiCardItem? item;
  final Map<String, String> opts = <String, String>{
    for (final MapEntry<String, String> e in s.attrs.entries)
      if (e.key.startsWith('data-fc-opt-'))
        e.key.substring('data-fc-opt-'.length): e.value,
  };
  if (s.kind == 'field') {
    final FushiCardFieldStyle? style = FushiCardFieldStyle.values
        .asNameMap()[s.attrs['data-fc-style']];
    final String? field = s.condition;
    if (style != null && field != null) {
      item = FushiCardFieldItem(
        field: field,
        style: style,
        title: s.attrs['data-fc-title'] ?? '',
      );
    }
  } else if (s.kind == 'html') {
    item = FushiCardHtmlItem(s.inner);
  } else {
    final Enum? block = side == FushiCardSide.front
        ? FushiCardFrontBlock.values.asNameMap()[s.kind]
        : FushiCardBlock.values.asNameMap()[s.kind];
    if (block != null &&
        !seen.contains(block) &&
        opts.keys.every((String k) => _optionOf(block, k) != null)) {
      item = FushiCardBlockItem(block, options: opts);
    }
  }
  if (item != null && _norm(fushiCardItemSnippet(item)) == _norm(raw)) {
    if (item is FushiCardBlockItem) seen.add(item.block);
    return item;
  }
  return FushiCardHtmlItem(raw, wrapped: false);
}

/// 从 [side] 面的模板 [template]（名字形式）读出区块布局：自上而下的布局项，删掉的区块不在
/// 里面。骨架（区块以外的标记与脚本）被改过、或区块结构坏了时返回 null（原生卡面画不了，
/// 整面 WebView）。
List<FushiCardItem>? fushiCardLayoutOf(String template, FushiCardSide side) {
  final List<_Span>? spans = _spansOf(template);
  if (spans == null) return null;
  final StringBuffer rest = StringBuffer();
  int cursor = 0;
  for (final _Span s in spans) {
    rest.write(template.substring(cursor, s.start));
    cursor = s.end;
  }
  rest.write(template.substring(cursor));
  if (_norm(rest.toString()) != _defaults(side).normSkeleton) return null;
  final Set<Enum> seen = <Enum>{};
  return List<FushiCardItem>.unmodifiable(<FushiCardItem>[
    for (final _Span s in spans)
      _itemOf(s, template.substring(s.start, s.end), side, seen),
  ]);
}

/// 背面的区块布局（[fushiCardLayoutOf] 的背面简写）。
List<FushiCardItem>? fushiCardBackLayoutOf(String back) =>
    fushiCardLayoutOf(back, FushiCardSide.back);

/// 正面的区块布局（[fushiCardLayoutOf] 的正面简写）。
List<FushiCardItem>? fushiCardFrontLayoutOf(String front) =>
    fushiCardLayoutOf(front, FushiCardSide.front);

/// 样式表是否与默认一致（空白差异不算改）。
bool fushiCardCssIsDefault(String css) =>
    css.replaceAll(_space, ' ').trim() == _normDefaultCss;

final String _normDefaultCss = kFushiCardStylingCss
    .replaceAll(_space, ' ')
    .trim();

/// 按区块布局 [items] 生成 [side] 面的模板：骨架、脚本不变，区块依次放进默认模板里区块
/// 原本的位置（槽）——背面释义区之前的放进左栏（多出的都落在左栏最后一个槽）、释义区放回
/// 原位、之后的放进页脚；正面依次放、多出的落在最后一个槽。生成的模板一定被
/// [fushiCardLayoutOf] 认回同一布局，Anki 里也照常可用。
String fushiCardTemplateFor(FushiCardSide side, List<FushiCardItem> items) {
  final _SideDefaults d = _defaults(side);
  final List<List<FushiCardItem>> slots = <List<FushiCardItem>>[
    for (int i = 0; i < d.slots.length; i++) <FushiCardItem>[],
  ];
  void fill(List<FushiCardItem> list, List<int> slotIds) {
    for (int i = 0; i < list.length; i++) {
      slots[slotIds[i < slotIds.length ? i : slotIds.length - 1]].add(list[i]);
    }
  }

  if (side == FushiCardSide.front) {
    fill(items, <int>[for (int i = 0; i < d.slots.length; i++) i]);
  } else {
    final int defs = FushiCardBlock.values.indexOf(FushiCardBlock.definitions);
    final int at = items.indexWhere(
      (FushiCardItem x) =>
          x is FushiCardBlockItem && x.block == FushiCardBlock.definitions,
    );
    final List<FushiCardItem> before = at < 0 ? items : items.sublist(0, at);
    fill(before, <int>[for (int i = 0; i < defs; i++) i]);
    if (at >= 0) {
      slots[defs].add(items[at]);
      fill(items.sublist(at + 1), <int>[
        for (int i = defs + 1; i < d.slots.length; i++) i,
      ]);
    }
  }
  final StringBuffer out = StringBuffer();
  int cursor = 0;
  for (int i = 0; i < d.slots.length; i++) {
    out.write(d.template.substring(cursor, d.slots[i].start));
    out.write(slots[i].map(fushiCardItemSnippet).join('\n'));
    cursor = d.slots[i].end;
  }
  out.write(d.template.substring(cursor));
  return out.toString();
}

/// 背面模板（[fushiCardTemplateFor] 的背面简写）。
String fushiCardBackTemplateFor(List<FushiCardItem> items) =>
    fushiCardTemplateFor(FushiCardSide.back, items);

/// 释义区单独渲染用的背面子模板（见 [kFushiCardDefinitionsTemplate]），按释义区块 [defs]
/// 的选项（「默认展开全部释义」）生成。
String fushiCardDefinitionsTemplateFor(FushiCardBlockItem defs) {
  const String t = kFushiCardBackTemplate;
  final int script = t.indexOf('<script>');
  if (script < 0) {
    throw StateError('Fushi Card back template lost its script');
  }
  return '<div class="fc fc-back fc-defs-only" lang="ja">\n'
      '  ${fushiCardItemSnippet(defs)}\n'
      '</div>\n\n'
      '${t.substring(script)}';
}
