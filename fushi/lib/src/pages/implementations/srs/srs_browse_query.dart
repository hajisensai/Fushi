/// 浏览页搜索积木 ↔ Anki 搜索语法互转（纯函数，不碰 UI / i18n）。
///
/// 语法是唯一真相：积木只是查询串顶层「与」链的结构化视图，最终仍拼回一条查询交给内核
/// （native/fushi_fsrs/src/search.rs）。拆不动的部分（顶层有 `or`、未知字段、括号里混了多种条件、
/// 括号 / 引号不配对……）原样留成一块 [SrsBrowseChipKind.syntax] 积木，拼回去时一字不改——所以
/// `srsBrowseChipsToQuery(srsParseBrowseChips(q))` 与 `q` 的语义恒等（顶层只是重排了空白）。
///
/// 分词与 fushi_srs `search_parser.dart` 同口径：空白分隔、`"…"` 内空白不断开、`\x` 成对转义、
/// 括号成组；`key:"a b"` 与 `"key:a b"` 两种引号写法都认。积木里的取值保存**查询里的原文**
/// （转义原样保留），显示时才去转义；从选择器来的字面量（牌组名 / 标签）先经 [srsBrowseLiteral]
/// 转义再放进积木。
library;

/// 积木种类。
enum SrsBrowseChipKind {
  /// `deck:`（含子牌组）。
  deck,

  /// `is:`（卡片状态）。
  state,

  /// `tag:`。
  tag,

  /// `note:`（笔记类型）。
  noteType,

  /// `src:`（出处）。
  source,

  /// 属性 / 时间类条件：`prop:` `added:` `edited:` `rated:` `flag:` `card:` `has:` `introduced:`。
  /// 整条原文一块，编辑时改原文。
  property,

  /// 自由文本（任一字段包含）。
  text,

  /// 拆不动的原样语法。
  syntax,
}

/// 可多选取值、能合成 `(k:a or k:b)` 的积木种类 → 语法关键字。
const Map<SrsBrowseChipKind, String> kSrsBrowseChipKeys =
    <SrsBrowseChipKind, String>{
      SrsBrowseChipKind.deck: 'deck',
      SrsBrowseChipKind.state: 'is',
      SrsBrowseChipKind.tag: 'tag',
      SrsBrowseChipKind.noteType: 'note',
      SrsBrowseChipKind.source: 'src',
    };

/// 归入 [SrsBrowseChipKind.property] 的关键字。
const Set<String> kSrsBrowsePropertyKeys = <String>{
  'prop',
  'added',
  'edited',
  'rated',
  'flag',
  'card',
  'has',
  'introduced',
};

/// 一块积木。
///
/// - 可多选种类（[kSrsBrowseChipKeys]）：[values] 是一到多个取值的查询原文（不带外层引号），
///   多个取值是「或」；[negated] = 排除（`-k:a` / `-(k:a or k:b)`）。
/// - [SrsBrowseChipKind.property] / [SrsBrowseChipKind.text]：[values] 只有一项，是去掉 `-` 的整条原文。
/// - [SrsBrowseChipKind.syntax]：[values] 只有一项，是整条原文（含 `-`），[negated] 恒为假。
class SrsBrowseChip {
  const SrsBrowseChip(this.kind, this.values, {this.negated = false})
    : _raw = null;

  /// 原样语法积木。
  const SrsBrowseChip.syntax(String raw)
    : kind = SrsBrowseChipKind.syntax,
      values = const <String>[],
      negated = false,
      _raw = raw;

  final SrsBrowseChipKind kind;
  final List<String> values;
  final bool negated;
  final String? _raw;

  /// 原样语法积木的原文（其它种类为该积木拼出的语法）。
  String get raw => _raw ?? toQuery();

  /// 这块积木拼成的语法（不含首尾空白）。
  String toQuery() {
    if (kind == SrsBrowseChipKind.syntax) return _raw ?? '';
    final String neg = negated ? '-' : '';
    final String? key = kSrsBrowseChipKeys[kind];
    if (key == null) {
      // property / text：整条原文。
      return values.isEmpty ? '' : '$neg${values.first}';
    }
    if (values.isEmpty) return '';
    if (values.length == 1) return '$neg$key:${_quoteValue(values.single)}';
    return '$neg(${values.map((String v) => '$key:${_quoteValue(v)}').join(' or ')})';
  }

  SrsBrowseChip copyWith({List<String>? values, bool? negated}) =>
      kind == SrsBrowseChipKind.syntax
      ? this
      : SrsBrowseChip(
          kind,
          values ?? this.values,
          negated: negated ?? this.negated,
        );

  @override
  bool operator ==(Object other) =>
      other is SrsBrowseChip &&
      other.kind == kind &&
      other.negated == negated &&
      other.raw == raw;

  @override
  int get hashCode => Object.hash(kind, negated, raw);

  @override
  String toString() => 'SrsBrowseChip(${kind.name}, $raw)';
}

/// 积木列表 → 一条查询（顶层空格「与」）。空积木跳过。
String srsBrowseChipsToQuery(Iterable<SrsBrowseChip> chips) => <String>[
  for (final SrsBrowseChip c in chips)
    if (c.toQuery().trim().isNotEmpty) c.toQuery().trim(),
].join(' ');

/// 一条查询 → 积木列表。顶层有 `or`、括号 / 引号不配对时整条是一块语法积木；空查询 → 空列表。
List<SrsBrowseChip> srsParseBrowseChips(String query) {
  final String input = query.trim();
  if (input.isEmpty) return const <SrsBrowseChip>[];
  final List<String>? tokens = _tokenize(input);
  if (tokens == null) return <SrsBrowseChip>[SrsBrowseChip.syntax(input)];
  if (tokens.any((String t) => t.toLowerCase() == 'or')) {
    return <SrsBrowseChip>[SrsBrowseChip.syntax(input)];
  }
  return <SrsBrowseChip>[
    for (final String t in tokens)
      if (t.toLowerCase() != 'and') _classify(t),
  ];
}

/// 把用户可见的字面量（牌组全名 / 标签 / 笔记类型名）转成查询原文：通配符 `*` `_`、反斜杠与引号转义，
/// 与 `srsDeckQuery` 同一规则（层级分隔 `::` 原样保留）。
String srsBrowseLiteral(String text) =>
    text.replaceAllMapped(RegExp(r'[\\*_"]'), (Match m) => '\\${m.group(0)}');

/// 查询原文 → 显示文字：去掉 `\x` 转义。
String srsBrowseUnescape(String raw) =>
    raw.replaceAllMapped(RegExp(r'\\(.)'), (Match m) => m.group(1)!);

/// 在 [chips] 里替换 / 删除第 [index] 块（[replacement] 为 null = 删除；取值删空的积木也删掉）。
List<SrsBrowseChip> srsBrowseReplaceChip(
  List<SrsBrowseChip> chips,
  int index,
  SrsBrowseChip? replacement,
) => <SrsBrowseChip>[
  for (int i = 0; i < chips.length; i++)
    if (i != index)
      chips[i]
    else if (replacement != null && replacement.toQuery().trim().isNotEmpty)
      replacement,
];

/// [chips] 是否包含 [subset] 的每一块（快捷视图的「选中」判据）。
bool srsBrowseChipsContain(
  List<SrsBrowseChip> chips,
  List<SrsBrowseChip> subset,
) => subset.isNotEmpty && subset.every(chips.contains);

/// 把输入框里还没变成积木的草稿并进积木：草稿按同一套规则拆开接在后面。
List<SrsBrowseChip> srsBrowseCommitDraft(
  List<SrsBrowseChip> chips,
  String draft,
) {
  final List<SrsBrowseChip> extra = srsParseBrowseChips(draft);
  if (extra.isEmpty) return chips;
  return <SrsBrowseChip>[...chips, ...extra];
}

// ---------------------------------------------------------------- 补全

/// 补全候选的种类（UI 据此选图标 / 说明文字）。
enum SrsBrowseSuggestionKind { deck, tag, noteType, state, property, syntax }

/// 一条补全候选：选中后追加 [chip]。
class SrsBrowseSuggestion {
  const SrsBrowseSuggestion(this.kind, this.chip, this.label);

  final SrsBrowseSuggestionKind kind;
  final SrsBrowseChip chip;

  /// 显示用的主文字（牌组名 / 标签 / 语法原文）；状态 / 属性的人话说明由 UI 按 [chip] 再配。
  final String label;

  @override
  bool operator ==(Object other) =>
      other is SrsBrowseSuggestion &&
      other.kind == kind &&
      other.chip == chip &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, chip, label);
}

/// 补全里列的卡片状态（`is:` 的值）。
const List<String> kSrsBrowseStates = <String>[
  'due',
  'new',
  'learn',
  'review',
  'suspended',
  'buried',
];

/// 补全里列的常用属性条件。
const List<String> kSrsBrowseCommonProperties = <String>[
  'prop:lapses>=4',
  'prop:ivl>=21',
  'prop:due<=0',
  'prop:r<0.7',
  'added:7',
  'rated:1',
  'flag:1',
];

/// 输入框草稿 [draft] 的补全：牌组 / 标签 / 笔记类型按包含匹配（不区分大小写），状态 / 常用属性按前缀，
/// 最后一条恒是「写成语法」（草稿原样拆成积木）。`deck:` / `tag:` / `note:` / `is:` 前缀只在那一类里找。
/// 草稿为空时不出补全。
List<SrsBrowseSuggestion> srsBrowseSuggestions(
  String draft, {
  required List<String> decks,
  required List<String> tags,
  required List<String> noteTypes,
  int perKind = 5,
}) {
  final String text = draft.trim();
  if (text.isEmpty) return const <SrsBrowseSuggestion>[];
  final int colon = text.indexOf(':');
  final String prefix = colon < 0 ? '' : text.substring(0, colon).toLowerCase();
  final String needle = (colon < 0 ? text : text.substring(colon + 1))
      .toLowerCase();
  bool only(String key) => prefix.isEmpty || prefix == key;
  Iterable<String> match(List<String> pool) =>
      pool.where((String v) => v.toLowerCase().contains(needle)).take(perKind);
  final List<SrsBrowseSuggestion> out = <SrsBrowseSuggestion>[
    if (only('deck'))
      for (final String d in match(decks))
        SrsBrowseSuggestion(
          SrsBrowseSuggestionKind.deck,
          SrsBrowseChip(SrsBrowseChipKind.deck, <String>[srsBrowseLiteral(d)]),
          d,
        ),
    if (only('tag'))
      for (final String g in match(tags))
        SrsBrowseSuggestion(
          SrsBrowseSuggestionKind.tag,
          SrsBrowseChip(SrsBrowseChipKind.tag, <String>[srsBrowseLiteral(g)]),
          g,
        ),
    if (only('note'))
      for (final String n in match(noteTypes))
        SrsBrowseSuggestion(
          SrsBrowseSuggestionKind.noteType,
          SrsBrowseChip(SrsBrowseChipKind.noteType, <String>[
            srsBrowseLiteral(n),
          ]),
          n,
        ),
    if (only('is'))
      for (final String s
          in kSrsBrowseStates
              .where(
                (String s) =>
                    s.startsWith(needle) ||
                    (prefix.isEmpty && 'is:$s'.startsWith(text.toLowerCase())),
              )
              .take(perKind))
        SrsBrowseSuggestion(
          SrsBrowseSuggestionKind.state,
          SrsBrowseChip(SrsBrowseChipKind.state, <String>[s]),
          'is:$s',
        ),
    for (final String p
        in kSrsBrowseCommonProperties
            .where((String p) => p.startsWith(text.toLowerCase()))
            .take(perKind))
      SrsBrowseSuggestion(
        SrsBrowseSuggestionKind.property,
        SrsBrowseChip(SrsBrowseChipKind.property, <String>[p]),
        p,
      ),
  ];
  final List<SrsBrowseChip> asIs = srsParseBrowseChips(text);
  if (asIs.length == 1) {
    out.add(
      SrsBrowseSuggestion(SrsBrowseSuggestionKind.syntax, asIs.single, text),
    );
  } else if (asIs.isNotEmpty) {
    out.add(
      SrsBrowseSuggestion(
        SrsBrowseSuggestionKind.syntax,
        SrsBrowseChip.syntax(text),
        text,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------- 内部

/// 值需不需要加引号：含空白、括号、引号，或为空。
String _quoteValue(String raw) {
  if (raw.isEmpty || RegExp(r'[\s()"　]').hasMatch(raw)) return '"$raw"';
  return raw;
}

/// 顶层分词（括号成组、引号内不断开、`\x` 成对）。括号 / 引号不配对返回 null。
List<String>? _tokenize(String input) {
  final List<String> out = <String>[];
  final StringBuffer cur = StringBuffer();
  int depth = 0;
  bool quoted = false;
  int i = 0;
  void flush() {
    if (cur.isNotEmpty) out.add(cur.toString());
    cur.clear();
  }

  while (i < input.length) {
    final String c = input[i];
    if (c == r'\' && i + 1 < input.length) {
      cur
        ..write(c)
        ..write(input[i + 1]);
      i += 2;
      continue;
    }
    if (c == '"') {
      quoted = !quoted;
      cur.write(c);
    } else if (quoted) {
      cur.write(c);
    } else if (c == '(') {
      // `a(b)`：无引号词停在括号前（与解析器同口径）；`-(` 是取反组，不断开。
      if (depth == 0 && cur.isNotEmpty && cur.toString() != '-') flush();
      depth++;
      cur.write(c);
    } else if (c == ')') {
      depth--;
      if (depth < 0) return null;
      cur.write(c);
      // `a)(b` 之类：括号闭合后紧跟的内容另起一块。
      if (depth == 0) flush();
    } else if ((c == ' ' || c == '　' || c == '\t' || c == '\n') && depth == 0) {
      flush();
    } else {
      cur.write(c);
    }
    i++;
  }
  if (quoted || depth != 0) return null;
  flush();
  return out;
}

/// 一个顶层词 → 积木。
SrsBrowseChip _classify(String token) {
  final bool neg = token.length > 1 && token.startsWith('-');
  final String body = neg ? token.substring(1) : token;
  if (body.startsWith('(') && body.endsWith(')')) {
    final SrsBrowseChip? group = _group(
      body.substring(1, body.length - 1),
      neg,
    );
    return group ?? SrsBrowseChip.syntax(token);
  }
  final ({String key, String value})? kv = _keyValue(body);
  if (kv == null) {
    // 没有 `key:`：自由文本（任一字段包含）。
    if (body.isEmpty || body.startsWith('-')) {
      return SrsBrowseChip.syntax(token);
    }
    return SrsBrowseChip(SrsBrowseChipKind.text, <String>[body], negated: neg);
  }
  final String key = kv.key.toLowerCase();
  for (final MapEntry<SrsBrowseChipKind, String> e
      in kSrsBrowseChipKeys.entries) {
    if (e.value == key) {
      if (kv.value.isEmpty) return SrsBrowseChip.syntax(token);
      return SrsBrowseChip(e.key, <String>[kv.value], negated: neg);
    }
  }
  if (kSrsBrowsePropertyKeys.contains(key)) {
    return SrsBrowseChip(SrsBrowseChipKind.property, <String>[
      body,
    ], negated: neg);
  }
  return SrsBrowseChip.syntax(token);
}

/// `k:a or k:b or …`（同一可多选关键字、都不取反）→ 一块多值积木；其它形状 null。
SrsBrowseChip? _group(String inner, bool negated) {
  final List<String>? tokens = _tokenize(inner.trim());
  if (tokens == null || tokens.isEmpty || tokens.length.isEven) return null;
  SrsBrowseChipKind? kind;
  final List<String> values = <String>[];
  for (int i = 0; i < tokens.length; i++) {
    final String t = tokens[i];
    if (i.isOdd) {
      if (t.toLowerCase() != 'or') return null;
      continue;
    }
    if (t.startsWith('-') || t.startsWith('(')) return null;
    final ({String key, String value})? kv = _keyValue(t);
    if (kv == null || kv.value.isEmpty) return null;
    SrsBrowseChipKind? k;
    for (final MapEntry<SrsBrowseChipKind, String> e
        in kSrsBrowseChipKeys.entries) {
      if (e.value == kv.key.toLowerCase()) k = e.key;
    }
    if (k == null || (kind != null && kind != k)) return null;
    kind = k;
    values.add(kv.value);
  }
  if (kind == null) return null;
  return SrsBrowseChip(kind, values, negated: negated);
}

/// 拆 `key:value` / `key:"value"` / `"key:value"`，值是去掉外层引号的原文；没有未转义的 `:` 返回 null。
({String key, String value})? _keyValue(String term) {
  String s = term;
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    s = s.substring(1, s.length - 1);
  }
  int i = 0;
  while (i < s.length && s[i] != ':') {
    i += s[i] == r'\' && i + 1 < s.length ? 2 : 1;
  }
  if (i == 0 || i >= s.length) return null;
  final String key = s.substring(0, i);
  if (key.contains('"')) return null;
  String value = s.substring(i + 1);
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1);
  }
  return (key: key, value: value);
}
