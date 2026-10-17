/// Anki 搜索语法子集解析器，结构逐函数对应 rslib `search/parser.rs`
/// （`group_inner` / `node` / `negated_node` / `group` / `text` /
/// `quoted_term` / `partially_quoted_term` / `unquoted_term` /
/// `search_node_for_text` / `unescape`）。
///
/// 优先级与 Anki 一致：隐式 AND（空格）与显式 AND 绑得比 OR 紧。
library;

import 'search_node.dart';

/// 解析 Anki 搜索串。语法错误与本子集不支持的语法都抛 [SrsSearchUnsupported]
/// （见 [SrsSearchErrorKind]），**绝不静默返回空集 / 全集**。空串 → [SrsSearchAll]。
SrsSearchNode parseAnkiSearch(String query) {
  final String input = query.replaceAll(RegExp(r'\s'), ' ').trim();
  if (input.isEmpty) return const SrsSearchAll();
  final _Parser parser = _Parser(input);
  final List<Object> items = parser.groupInner();
  if (parser.pos != input.length) {
    throw parser.fail(
      input.substring(parser.pos),
      'unopened group: unmatched ")"',
    );
  }
  return _combine(items);
}

/// 内部用的 AND / OR 记号（组内平铺列表里与节点交替出现）。
enum _Op { and, or }

/// 「这条路走不通，回溯试下一个分支」（nom 的 `Err::Error`）。
class _Backtrack implements Exception {
  const _Backtrack();
}

/// 平铺的 `[node, op, node, op, node…]` → AND 先于 OR 的树。
SrsSearchNode _combine(List<Object> items) {
  final List<SrsSearchNode> ors = <SrsSearchNode>[];
  List<SrsSearchNode> ands = <SrsSearchNode>[];
  SrsSearchNode flush(List<SrsSearchNode> group) =>
      group.length == 1 ? group.single : SrsSearchAnd(group);
  for (final Object item in items) {
    if (item == _Op.or) {
      ors.add(flush(ands));
      ands = <SrsSearchNode>[];
    } else if (item is SrsSearchNode) {
      ands.add(item);
    }
  }
  ors.add(flush(ands));
  return ors.length == 1 ? ors.single : SrsSearchOr(ors);
}

class _Parser {
  _Parser(this.input);

  final String input;
  int pos = 0;

  SrsSearchUnsupported fail(String at, String reason) =>
      SrsSearchUnsupported(at, reason, SrsSearchErrorKind.syntax);

  SrsSearchUnsupported unsupported(String at, String reason) =>
      SrsSearchUnsupported(at, reason, SrsSearchErrorKind.unsupported);

  bool get atEnd => pos >= input.length;
  String get cur => input[pos];

  void skipWhitespace() {
    while (!atEnd && (cur == ' ' || cur == '　')) {
      pos++;
    }
  }

  /// 括号内（或顶层）的零个以上节点，返回 `[node, op, node…]`。
  List<Object> groupInner() {
    final int start = pos;
    final List<Object> items = <Object>[];
    while (true) {
      final int save = pos;
      final Object node;
      try {
        node = this.node();
      } on _Backtrack {
        pos = save;
        break;
      }
      if (items.length.isEven) {
        if (node == _Op.and)
          throw fail(input.substring(start), 'misplaced AND');
        if (node == _Op.or) throw fail(input.substring(start), 'misplaced OR');
      } else if (node is! _Op) {
        items.add(_Op.and);
      }
      items.add(node);
    }
    if (items.isNotEmpty) {
      if (items.last == _Op.and) {
        throw fail(input.substring(start), 'misplaced AND');
      }
      if (items.last == _Op.or) {
        throw fail(input.substring(start), 'misplaced OR');
      }
    }
    skipWhitespace();
    return items;
  }

  /// 可选前导空白，然后 取反节点 | 括号组 | 文本。
  Object node() {
    skipWhitespace();
    final int save = pos;
    try {
      return negated();
    } on _Backtrack {
      pos = save;
    }
    try {
      return group();
    } on _Backtrack {
      pos = save;
    }
    return text();
  }

  SrsSearchNode negated() {
    if (atEnd || cur != '-') throw const _Backtrack();
    final int start = pos;
    pos++;
    final int save = pos;
    Object inner;
    try {
      inner = group();
    } on _Backtrack {
      pos = save;
      inner = text();
    }
    if (inner is _Op) {
      throw fail(input.substring(start), 'cannot negate AND / OR');
    }
    return SrsSearchNot(inner as SrsSearchNode);
  }

  SrsSearchNode group() {
    if (atEnd || cur != '(') throw const _Backtrack();
    final int start = pos;
    pos++;
    final List<Object> inner = groupInner();
    if (!atEnd && cur == ')') {
      if (inner.isEmpty) throw fail(input.substring(start), 'empty group');
      pos++;
      return _combine(inner);
    }
    throw fail(input.substring(start), 'unclosed group: missing ")"');
  }

  /// 引号文本 | 部分引号（`deck:"a b"`）| 无引号文本。
  Object text() {
    final int save = pos;
    try {
      return quotedTerm();
    } on _Backtrack {
      pos = save;
    }
    try {
      return partiallyQuotedTerm();
    } on _Backtrack {
      pos = save;
    }
    return unquotedTerm();
  }

  SrsSearchNode quotedTerm() => _searchNodeForText(quotedTermStr());

  /// 非空、两端是未转义 `"` 的串，返回引号内原文（转义保留）。
  String quotedTermStr() {
    if (atEnd || cur != '"') throw const _Backtrack();
    final int start = pos;
    pos++;
    final int innerStart = pos;
    while (!atEnd && cur != '"') {
      if (cur == r'\') {
        if (pos + 1 >= input.length) {
          throw fail(input.substring(start), 'unclosed quote');
        }
        pos += _charLen(pos + 1) + 1;
      } else {
        pos += _charLen(pos);
      }
    }
    if (atEnd) throw fail(input.substring(start), 'unclosed quote');
    if (pos == innerStart) throw fail(input.substring(start), 'empty quote');
    final String inner = input.substring(innerStart, pos);
    pos++;
    return inner;
  }

  /// `key:"quoted value"`（引号只能在冒号之后）。
  SrsSearchNode partiallyQuotedTerm() {
    final String key = _escapedRun(
      r'"(): '
      '　\\',
    );
    if (key.isEmpty || atEnd || cur != ':') throw const _Backtrack();
    pos++;
    final String value = quotedTermStr();
    return _searchNodeForTextWithArgument(key, value);
  }

  /// 无引号文本：到空白或未转义的 `"` `(` `)` 为止。
  Object unquotedTerm() {
    final int start = pos;
    final String term = _escapedRun('"() 　\\');
    if (term.isEmpty) {
      if (!atEnd && cur == r'\') {
        throw fail(input.substring(start), r'unknown escape: \');
      }
      throw const _Backtrack();
    }
    if (!atEnd && cur == r'\') {
      // 结尾是奇数个反斜杠，或反斜杠后跟空白。
      throw fail(input.substring(start), r'unknown escape: \');
    }
    final String lower = term.toLowerCase();
    if (lower == 'and') return _Op.and;
    if (lower == 'or') return _Op.or;
    return _searchNodeForText(term);
  }

  /// nom `escaped(is_not(stop), '\\', none_of(" 　"))`：吃掉不在 [stop] 里
  /// 的字符，`\x`（x 非空白）成对吃掉。停在 [stop] 字符、或无法成对的 `\` 上。
  String _escapedRun(String stop) {
    final int start = pos;
    while (!atEnd) {
      final String c = cur;
      if (c == r'\') {
        if (pos + 1 < input.length &&
            input[pos + 1] != ' ' &&
            input[pos + 1] != '　') {
          pos += 1 + _charLen(pos + 1);
          continue;
        }
        break;
      }
      if (stop.contains(c)) break;
      pos += _charLen(pos);
    }
    return input.substring(start, pos);
  }

  int _charLen(int at) {
    final int c = input.codeUnitAt(at);
    return (c >= 0xD800 && c <= 0xDBFF && at + 1 < input.length) ? 2 : 1;
  }

  /// 判断是否带 `key:`，处理转义。
  SrsSearchNode _searchNodeForText(String s) {
    int i = 0;
    while (i < s.length && s[i] != ':') {
      i += s[i] == r'\' && i + 1 < s.length ? 2 : 1;
    }
    if (i == 0) throw fail(s, 'missing key before ":"');
    final String head = s.substring(0, i);
    if (i >= s.length) return SrsSearchText(_unescape(head));
    return _searchNodeForTextWithArgument(head, s.substring(i + 1));
  }

  SrsSearchNode _searchNodeForTextWithArgument(String key, String val) {
    switch (_asciiLower(key)) {
      case 'deck':
        final String deck = _unescape(val);
        if (deck == 'filtered' || deck == 'current') {
          throw unsupported('$key:$val', 'deck:$deck is not supported');
        }
        return SrsSearchDeck(deck);
      case 'note':
        return SrsSearchNoteType(_unescape(val));
      case 'tag':
        if (val.startsWith('re:') || val.startsWith('nc:')) {
          throw unsupported('$key:$val', 'tag:re: / tag:nc: is not supported');
        }
        return SrsSearchTag(_unescape(val));
      case 'is':
        return SrsSearchState(switch (val) {
          'new' => SrsSearchCardState.isNew,
          'learn' => SrsSearchCardState.learn,
          'review' => SrsSearchCardState.review,
          'due' => SrsSearchCardState.due,
          'suspended' => SrsSearchCardState.suspended,
          'buried' || 'buried-manually' => SrsSearchCardState.buried,
          'buried-sibling' => throw unsupported(
            '$key:$val',
            'is:$val is not supported',
          ),
          _ => throw fail('$key:$val', 'invalid state: is:$val'),
        });
      case 'nid':
        return SrsSearchNoteIds(_idList(key, val));
      case 'cid':
        return SrsSearchCardIds(_idList(key, val));
      case 'added':
        return SrsSearchAddedInDays(_dayCount(key, val));
      case 'edited':
        return SrsSearchEditedInDays(_dayCount(key, val));
      case 'flag':
        final int? flag = RegExp(r'^[0-7]$').hasMatch(val)
            ? int.parse(val)
            : null;
        if (flag == null) {
          throw fail('$key:$val', 'flag: expects a number from 0 to 7');
        }
        return SrsSearchFlag(flag);
      case 'card':
        if (RegExp(r'^\d+$').hasMatch(val)) {
          final int? n = int.tryParse(val);
          if (n == null) throw fail('$key:$val', 'card: number out of range');
          // rslib：`card:N` → 序号 N - 1（饱和减），所以 card:0 与 card:1 相同。
          return SrsSearchCardTemplate.ordinal(n < 1 ? 1 : n);
        }
        return SrsSearchCardTemplate.named(_unescape(val));
      case 'prop':
        return _prop(key, val);
      case 're':
        return SrsSearchRegex(val, _regex('$key:$val', val));
      case 'resched' ||
          'introduced' ||
          'rated' ||
          'did' ||
          'mid' ||
          'nc' ||
          'sc' ||
          'w' ||
          'dupe' ||
          'has-cd' ||
          'preset':
        throw unsupported('$key:$val', '${_asciiLower(key)}: is not supported');
    }
    if (val.startsWith('re:')) {
      final String source = val.substring(3);
      return SrsSearchFieldRegex(
        _unescape(key),
        source,
        _regex('$key:$val', source),
      );
    }
    if (val.startsWith('nc:')) {
      throw unsupported('$key:$val', 'field:nc: is not supported');
    }
    return SrsSearchField(_unescape(key), _unescape(val));
  }

  /// `edited:` / `added:` 的天数（至少 1）。
  int _dayCount(String key, String val) {
    if (!RegExp(r'^\d+$').hasMatch(val)) {
      throw fail('$key:$val', '$key: expects a positive whole number');
    }
    final int? days = int.tryParse(val);
    if (days == null || days > 0xFFFFFFFF) {
      throw fail('$key:$val', '$key: number out of range');
    }
    return days < 1 ? 1 : days;
  }

  /// `re:` 的正则（rslib：只解掉 `\"`，其余反斜杠原样交给正则引擎；默认不区分大小写，
  /// 开头写 `(?-i)` 改为区分大小写）。正则本身不合法 = 语法错误。
  RegExp _regex(String at, String raw) {
    String source = raw.replaceAll(r'\"', '"');
    bool caseSensitive = false;
    if (source.startsWith('(?-i)')) {
      source = source.substring(5);
      caseSensitive = true;
    } else if (source.startsWith('(?i)')) {
      source = source.substring(4);
    }
    if (source.isEmpty) throw fail(at, 'empty regular expression');
    try {
      return RegExp(source, caseSensitive: caseSensitive, unicode: true);
    } on FormatException catch (e) {
      throw fail(at, 'invalid regular expression: ${e.message}');
    }
  }

  /// `prop:属性 比较符 数值`（rslib `parse_prop`）。
  SrsSearchProp _prop(String key, String val) {
    final RegExpMatch? m = RegExp(
      r'^(ivl|due|reps|lapses|ease|pos|rated|resched|cdn:[^<>=!]*|'
      r'cds:[^<>=!]*|cdr:[^<>=!]*|r|s|d)(<=|>=|!=|=|<|>)(.*)$',
    ).firstMatch(val);
    if (m == null) throw fail('$key:$val', 'invalid property search');
    final String name = m.group(1)!;
    final SrsSearchProperty? property = switch (name) {
      'ivl' => SrsSearchProperty.interval,
      'due' => SrsSearchProperty.due,
      'reps' => SrsSearchProperty.reps,
      'lapses' => SrsSearchProperty.lapses,
      's' => SrsSearchProperty.stability,
      'd' => SrsSearchProperty.difficulty,
      _ => null,
    };
    if (property == null) {
      throw unsupported('$key:$val', 'prop:$name is not supported');
    }
    final SrsSearchCompare compare = switch (m.group(2)!) {
      '<=' => SrsSearchCompare.le,
      '>=' => SrsSearchCompare.ge,
      '!=' => SrsSearchCompare.ne,
      '<' => SrsSearchCompare.lt,
      '>' => SrsSearchCompare.gt,
      _ => SrsSearchCompare.eq,
    };
    final String text = m.group(3)!;
    final bool fractional =
        property == SrsSearchProperty.stability ||
        property == SrsSearchProperty.difficulty;
    final num? value = fractional
        ? (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(text)
              ? double.tryParse(text)
              : null)
        : (RegExp(r'^-?\d+$').hasMatch(text) ? int.tryParse(text) : null);
    if (value == null) {
      throw fail(
        '$key:$val',
        fractional
            ? 'prop:$name expects a number'
            : 'prop:$name expects a whole number',
      );
    }
    return SrsSearchProp(property, compare, value);
  }

  List<int> _idList(String key, String val) {
    if (!RegExp(r'^(\d+,)*\d+$').hasMatch(val)) {
      throw fail('$key:$val', 'expected only digits and commas in $key:');
    }
    return <int>[
      for (final String part in val.split(','))
        int.tryParse(part) ??
            (throw fail('$key:$val', 'id out of range in $key:')),
    ];
  }

  /// 校验转义并解掉解析器层面的转义（`\"` `\:` `\(` `\)` `\-`）；
  /// 通配转义 `\\` `\*` `\_` 原样保留给匹配阶段。
  String _unescape(String txt) {
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < txt.length; i++) {
      final String c = txt[i];
      if (c != r'\') {
        buf.write(c);
        continue;
      }
      if (i + 1 >= txt.length) throw fail(txt, r'unknown escape: \');
      final String next = txt[i + 1];
      switch (next) {
        case '"' || ':' || '(' || ')' || '-':
          buf.write(next);
        case r'\' || '*' || '_':
          buf
            ..write(c)
            ..write(next);
        default:
          throw fail(txt, 'unknown escape: \\$next');
      }
      i++;
    }
    return buf.toString();
  }
}

String _asciiLower(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (Match m) => m.group(0)!.toLowerCase());
