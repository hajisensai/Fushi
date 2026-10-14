/// Anki 卡模板渲染。两种模式共用同一套分词 / 解析（照 rslib `template.rs`）：
///
/// **预览模式**（[renderAnkiTemplate]，给编辑器预览用）：
/// 预览过去是一份手写的 DOM mock，只是「长得像」Lapis。用户换了 Lapis 版本、或
/// 自己改过模板，预览就和真卡对不上（反馈原话「调整器里面默认的 lapis 和默认的
/// lapis 不一样」）。改成拿**用户自己的模板**渲染示例数据之后，预览的结构天然
/// 与真卡一致。预览只渲染示例数据、不参与任何写入，所以刻意宽松：
/// * 过滤器一律按「取字段原值」处理（示例数据本来就是给人看形状的）；
/// * 未知字段渲染成空串、`{{FrontSide}}` 渲染成空；
/// * 标签不配对不抛错，尽量把卡画出来。
///
/// **Anki 模式**（[renderAnkiCard] / [renderAnkiCardSide]，内置 SRS 复习用）：
/// 行为对齐 rslib（`template.rs` / `cloze.rs` / `template_filters.rs`）：
/// 段的真假按「字段去掉空白与空 `<br>`/`<div>` 后是否为空」、`{{FrontSide}}`、
/// 特殊字段（Tags/Type/Deck/Subdeck/CardFlag/Card/CardID/cN）、过滤器链
/// （text / furigana / kana / kanji / cloze / cloze-only / hint / tts / type）、
/// 未知过滤器透传、模板语法错误与未知字段抛 [AnkiTemplateError]。
///
/// 另有字段引用「名字 ↔ `fld:<id>`」互转（[templateNamesToIds] /
/// [templateIdsToNames]）、空卡判定 [isAnkiCardEmpty]、cloze 序号
/// [clozeOrdinalsIn] 与卡面 `lang` 容器 [wrapAnkiCardHtmlWithLang]。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

// ---------------------------------------------------------------------------
// 预览模式（旧 API，行为保持不变）
// ---------------------------------------------------------------------------

/// 一段模板里被引用到的全部字段名（含过滤器前缀的取字段名后的结果）。
///
/// 用途：让预览知道「这份模板到底会用到哪些字段」，从而只为它们准备示例值。
Set<String> ankiTemplateReferencedFields(String template) {
  final Set<String> names = <String>{};
  for (final RegExpMatch m in _tagPattern.allMatches(template)) {
    final String raw = m.group(1)!.trim();
    if (raw.isEmpty) continue;
    final String body =
        raw.startsWith('#') || raw.startsWith('^') || raw.startsWith('/')
        ? raw.substring(1).trim()
        : raw;
    final String field = _stripFilters(body);
    if (field.isNotEmpty && field != 'FrontSide') names.add(field);
  }
  return names;
}

/// 预览渲染 [template]，用 [fields] 取值；缺失字段按空串处理。
///
/// 与 Anki 模式共用分词与解析（含 `<!-- -->` 注释内不展开、`{{=<% %>=}}` 旧语法），
/// 但解析走宽松恢复：多余的闭合标签忽略、未闭合的段在模板末尾自动闭合、闭合
/// 标签不核对名字（关掉当前最内层段）。预览的职责是尽量把卡画出来，不是校验模板。
String renderAnkiTemplate(String template, Map<String, String> fields) {
  final List<_Node> nodes = _parse(_tokenize(template), strict: false);
  final StringBuffer out = StringBuffer();
  _renderPreview(nodes, fields, out);
  return out.toString();
}

void _renderPreview(
  List<_Node> nodes,
  Map<String, String> fields,
  StringBuffer out,
) {
  for (final _Node node in nodes) {
    switch (node) {
      case _TextNode(:final String text):
        out.write(text);
      case _CommentNode(:final String text):
        out.write('$_commentStart$text$_commentEnd');
      case _ReplacementNode(:final String key):
        final String field = key.trim();
        if (field == 'FrontSide') continue;
        out.write(fields[field] ?? '');
      case _ConditionalNode(
        :final String key,
        :final bool negated,
        :final List<_Node> children,
      ):
        final String field = _stripFilters(key);
        final bool has = (fields[field] ?? '').trim().isNotEmpty;
        if (has != negated) _renderPreview(children, fields, out);
    }
  }
}

/// `{{ … }}`。非贪婪，且不跨越 `}}`。
final RegExp _tagPattern = RegExp(r'\{\{(.*?)\}\}', dotAll: true);

/// 去掉 `filter:` 前缀链（`{{furigana:kana:Field}}` → `Field`）。
String _stripFilters(String body) {
  final int last = body.lastIndexOf(':');
  return (last < 0 ? body : body.substring(last + 1)).trim();
}

// ---------------------------------------------------------------------------
// 分词（rslib template.rs `tokens` / `classify_handle`）
// ---------------------------------------------------------------------------

const String _commentStart = '<!--';
const String _commentEnd = '-->';
const String _altDirective = '{{=<% %>=}}';

enum _TokKind { text, comment, replacement, open, openNegated, close, prelude }

/// 一个词元。`raw` 是它在源模板里的原文（字段引用改写靠它保证往返无损）；
/// handlebar 词元另记 `inner`（定界符之间的原文）与 key 在 `inner` 里的区间。
class _Tok {
  _Tok(
    this.kind,
    this.raw, {
    this.inner = '',
    this.startTag = '',
    this.endTag = '',
    this.keyStart = 0,
    this.keyEnd = 0,
  });

  final _TokKind kind;
  final String raw;
  final String inner;
  final String startTag;
  final String endTag;
  final int keyStart;
  final int keyEnd;

  /// replacement：去掉首尾空白与前导 `{` 后的整段（含过滤器）；
  /// 条件 / 闭合：标记后的 key。
  String get body => inner.substring(_bodyStart, keyEnd);

  int get _bodyStart =>
      kind == _TokKind.replacement ? _replacementStart : keyStart;

  int get _replacementStart {
    final String s = _leadingTrimmed(inner);
    return inner.length - s.length;
  }
}

String _leadingTrimmed(String inner) {
  int i = 0;
  while (i < inner.length && inner.codeUnitAt(i) == 0x7B /* { */ ) {
    i++;
  }
  return inner.substring(i).trimLeft();
}

List<_Tok> _tokenize(String template) {
  final List<_Tok> out = <_Tok>[];
  String text = template;
  String startTag = '{{';
  String endTag = '}}';
  final String trimmedStart = template.trimLeft();
  if (trimmedStart.startsWith(_altDirective)) {
    String rest = trimmedStart;
    while (rest.startsWith(_altDirective)) {
      rest = rest.substring(_altDirective.length);
    }
    out.add(
      _Tok(
        _TokKind.prelude,
        template.substring(0, template.length - rest.length),
      ),
    );
    text = rest;
    startTag = '<%';
    endTag = '%>';
  }

  int textStart = 0;
  int i = 0;
  void flushText(int end) {
    if (end > textStart) {
      out.add(_Tok(_TokKind.text, text.substring(textStart, end)));
    }
  }

  while (i < text.length) {
    if (text.startsWith(startTag, i)) {
      final int close = text.indexOf(endTag, i + startTag.length);
      if (close >= 0) {
        flushText(i);
        final String inner = text.substring(i + startTag.length, close);
        out.add(_classifyHandle(inner, startTag, endTag));
        i = close + endTag.length;
        textStart = i;
        continue;
      }
    }
    if (text.startsWith(_commentStart, i)) {
      final int close = text.indexOf(_commentEnd, i + _commentStart.length);
      if (close >= 0) {
        flushText(i);
        final int end = close + _commentEnd.length;
        out.add(
          _Tok(
            _TokKind.comment,
            text.substring(i, end),
            inner: text.substring(i + _commentStart.length, close),
          ),
        );
        i = end;
        textStart = i;
        continue;
      }
    }
    i++;
  }
  flushText(text.length);
  return out;
}

_Tok _classifyHandle(String inner, String startTag, String endTag) {
  final String raw = '$startTag$inner$endTag';
  final String trimmedLeft = _leadingTrimmed(inner);
  final String start = trimmedLeft.trimRight();
  final int startOffset = inner.length - trimmedLeft.length;
  final int startEnd = startOffset + start.length;
  _Tok replacement() {
    final int colon = start.lastIndexOf(':');
    return _Tok(
      _TokKind.replacement,
      raw,
      inner: inner,
      startTag: startTag,
      endTag: endTag,
      keyStart: colon < 0 ? startOffset : startOffset + colon + 1,
      keyEnd: startEnd,
    );
  }

  if (start.length < 2) return replacement();
  final _TokKind? kind = switch (start[0]) {
    '#' => _TokKind.open,
    '/' => _TokKind.close,
    '^' => _TokKind.openNegated,
    _ => null,
  };
  if (kind == null) return replacement();
  final String stripped = start.substring(1).trimLeft();
  return _Tok(
    kind,
    raw,
    inner: inner,
    startTag: startTag,
    endTag: endTag,
    keyStart: startEnd - stripped.length,
    keyEnd: startEnd,
  );
}

// ---------------------------------------------------------------------------
// 解析（rslib template.rs `parse_inner`）
// ---------------------------------------------------------------------------

sealed class _Node {}

class _TextNode extends _Node {
  _TextNode(this.text);
  final String text;
}

class _CommentNode extends _Node {
  _CommentNode(this.text);
  final String text;
}

class _ReplacementNode extends _Node {
  _ReplacementNode(this.key, this.filters);
  final String key;

  /// 按应用顺序（最靠近字段名的先应用），与 rslib 一致。
  final List<String> filters;
}

class _ConditionalNode extends _Node {
  _ConditionalNode(this.key, this.children, {required this.negated});
  final String key;
  final List<_Node> children;
  final bool negated;
}

/// 模板语法错误 / 引用了不存在的字段（Anki 模式）。
///
/// 与 Anki 一致：Anki 遇到这些情况不出卡，而是在卡面上显示错误说明。
class AnkiTemplateError implements Exception {
  const AnkiTemplateError(this.message);

  final String message;

  @override
  String toString() => 'AnkiTemplateError: $message';
}

List<_Node> _parse(List<_Tok> tokens, {required bool strict}) {
  int index = 0;
  List<_Node> parseInner(String? openTag) {
    final List<_Node> nodes = <_Node>[];
    while (index < tokens.length) {
      final _Tok tok = tokens[index++];
      switch (tok.kind) {
        case _TokKind.prelude:
          break;
        case _TokKind.text:
          nodes.add(_TextNode(tok.raw));
        case _TokKind.comment:
          nodes.add(_CommentNode(tok.inner));
        case _TokKind.replacement:
          final List<String> parts = tok.body.split(':');
          nodes.add(
            _ReplacementNode(
              parts.last,
              parts.sublist(0, parts.length - 1).reversed.toList(),
            ),
          );
        case _TokKind.open:
        case _TokKind.openNegated:
          final String key = tok.body;
          nodes.add(
            _ConditionalNode(
              key,
              parseInner(key),
              negated: tok.kind == _TokKind.openNegated,
            ),
          );
        case _TokKind.close:
          final String key = tok.body;
          if (openTag != null && (!strict || openTag == key)) return nodes;
          if (!strict) break; // 多余闭合：预览忽略
          if (openTag != null) {
            throw AnkiTemplateError(
              'Found {{/$key}}, but expected {{/$openTag}}',
            );
          }
          throw AnkiTemplateError(
            'Found {{/$key}}, but missing {{#$key}} or {{^$key}}',
          );
      }
    }
    if (openTag != null && strict) {
      throw AnkiTemplateError('Missing {{/$openTag}}');
    }
    return nodes;
  }

  return parseInner(null);
}

// ---------------------------------------------------------------------------
// Anki 模式：特殊字段 / 空判定 / 渲染
// ---------------------------------------------------------------------------

/// Anki 给每张卡补的特殊字段（rslib notetype/render.rs `add_special_fields`）。
///
/// 只在笔记里没有同名字段时生效（`or_insert`）。`{{FrontSide}}` 不在这里，由
/// 渲染背面时传入的正面结果决定。
class AnkiCardSpecialFields {
  const AnkiCardSpecialFields({
    this.tags = const <String>[],
    this.deckName = '',
    this.noteTypeName = '',
    this.cardName = '',
    this.cardFlag = 0,
    this.cardId = '',
  });

  final List<String> tags;

  /// 牌组全路径（`父::子`）。Subdeck 取最后一段。
  final String deckName;
  final String noteTypeName;

  /// 卡片模板名（`{{Card}}`）。
  final String cardName;

  /// 0–7；`{{CardFlag}}` 渲染成 `flag<n>`。
  final int cardFlag;
  final String cardId;
}

/// Anki 渲染用的完整字段表：笔记字段 + 特殊字段 + 当前卡的 `c<ord+1>`=`1`。
Map<String, String> ankiFieldMapWithSpecials({
  required Map<String, String> noteFields,
  required int cardOrd,
  AnkiCardSpecialFields specials = const AnkiCardSpecialFields(),
}) {
  final Map<String, String> map = Map<String, String>.of(noteFields);
  final String deck = specials.deckName.isEmpty ? '(Deck)' : specials.deckName;
  final List<String> deckParts = deck.split('::');
  map.putIfAbsent('Tags', () => specials.tags.join(' '));
  map.putIfAbsent('Type', () => specials.noteTypeName);
  map.putIfAbsent('Subdeck', () => deckParts.last);
  map.putIfAbsent('Deck', () => deck);
  map.putIfAbsent('CardFlag', () => 'flag${specials.cardFlag}');
  map.putIfAbsent('Card', () => specials.cardName);
  map.putIfAbsent('CardID', () => specials.cardId);
  map.putIfAbsent('c${cardOrd + 1}', () => '1');
  return map;
}

/// 字段是否算空（rslib `field_is_empty`）：只含 ASCII 空白与空 `<br>`/`<div>`。
bool ankiFieldIsEmpty(String text) => _fieldEmptyPattern.hasMatch(text);

final RegExp _fieldEmptyPattern = RegExp(
  r'^(?:[\t\n\x0B\f\r ]|</?(?:br|div) ?/?>)*$',
  caseSensitive: false,
);

Set<String> _nonEmptyFields(Map<String, String> fields) => <String>{
  for (final MapEntry<String, String> e in fields.entries)
    if (!ankiFieldIsEmpty(e.value)) e.key,
};

/// rslib `template_is_empty`（`check_negated = true`）。
bool _templateIsEmpty(Set<String> nonEmpty, List<_Node> nodes) {
  for (final _Node node in nodes) {
    switch (node) {
      case _TextNode() || _CommentNode():
        break;
      case _ReplacementNode(:final String key):
        if (nonEmpty.contains(key)) return false;
      case _ConditionalNode(
        :final String key,
        :final bool negated,
        :final List<_Node> children,
      ):
        if (!negated && !nonEmpty.contains(key)) continue;
        if (negated && nonEmpty.contains(key)) continue;
        if (!_templateIsEmpty(nonEmpty, children)) return false;
    }
  }
  return true;
}

/// 正面是否为空卡（rslib `render_card` 的空判定）：
/// * cloze 笔记类型：当前卡的序号（`cardOrd + 1`）不在任何字段的 cloze 里；
/// * 普通笔记类型：正面模板里没有任何「引用非空字段」的替换能被输出
///   （`renders_with_fields`）——注意这是按**字段引用**判，不是按渲染后的文本判：
///   `test{{Empty}}` 渲染出 `test`，但照样是空卡。
///
/// 模板语法错误抛 [AnkiTemplateError]。
bool isAnkiCardEmpty({
  required String questionTemplate,
  required Map<String, String> noteFields,
  required int cardOrd,
  required bool isCloze,
  AnkiCardSpecialFields specials = const AnkiCardSpecialFields(),
}) {
  final Map<String, String> fields = ankiFieldMapWithSpecials(
    noteFields: noteFields,
    cardOrd: cardOrd,
    specials: specials,
  );
  final List<_Node> nodes = _parse(_tokenize(questionTemplate), strict: true);
  if (isCloze) {
    final Set<int> ords = <int>{};
    for (final String value in fields.values) {
      ords.addAll(clozeOrdinalsIn(value));
    }
    return !ords.contains(cardOrd + 1);
  }
  return _templateIsEmpty(_nonEmptyFields(fields), nodes);
}

/// 一张卡两面的渲染结果。
class AnkiRenderedCard {
  const AnkiRenderedCard({
    required this.question,
    required this.answer,
    required this.isEmpty,
  });

  final String question;

  /// 空卡时为空串（Anki 此时两面都只显示「正面为空」说明，由宿主负责）。
  final String answer;
  final bool isEmpty;
}

/// 渲染一张卡的正反两面（rslib `render_card`，非 partial 模式）。
///
/// [noteFields] 只给笔记字段即可，特殊字段由 [specials] 补齐。空卡时
/// [AnkiRenderedCard.isEmpty] 为 true、不渲染背面。模板语法错误 / 未知字段抛
/// [AnkiTemplateError]。
AnkiRenderedCard renderAnkiCard({
  required String questionTemplate,
  required String answerTemplate,
  required Map<String, String> noteFields,
  required int cardOrd,
  required bool isCloze,
  AnkiCardSpecialFields specials = const AnkiCardSpecialFields(),
}) {
  final Map<String, String> fields = ankiFieldMapWithSpecials(
    noteFields: noteFields,
    cardOrd: cardOrd,
    specials: specials,
  );
  final Set<String> nonEmpty = _nonEmptyFields(fields);
  final List<_Node> qNodes = _parse(_tokenize(questionTemplate), strict: true);
  final _RenderContext qCtx = _RenderContext(
    fields: fields,
    nonEmpty: nonEmpty,
    cardOrd: cardOrd,
    frontSide: null,
  );
  final StringBuffer q = StringBuffer();
  _renderStrict(qNodes, qCtx, q);
  final String question = q.toString();

  final bool empty;
  if (isCloze) {
    final Set<int> ords = <int>{};
    for (final String value in fields.values) {
      ords.addAll(clozeOrdinalsIn(value));
    }
    empty = !ords.contains(cardOrd + 1);
  } else {
    empty = _templateIsEmpty(nonEmpty, qNodes);
  }
  if (empty) {
    return AnkiRenderedCard(question: question, answer: '', isEmpty: true);
  }

  final List<_Node> aNodes = _parse(_tokenize(answerTemplate), strict: true);
  final StringBuffer a = StringBuffer();
  _renderStrict(
    aNodes,
    _RenderContext(
      fields: fields,
      nonEmpty: nonEmpty,
      cardOrd: cardOrd,
      frontSide: question,
    ),
    a,
  );
  return AnkiRenderedCard(
    question: question,
    answer: a.toString(),
    isEmpty: false,
  );
}

/// 只渲染一面。[fields] 须是**完整字段表**（一般用 [ankiFieldMapWithSpecials]
/// 生成）；[frontSide] 为 null 表示正面（cloze 挖空、`{{FrontSide}}` 为空），
/// 非 null 表示背面，`{{FrontSide}}` 展开为它。
String renderAnkiCardSide({
  required String template,
  required Map<String, String> fields,
  required int cardOrd,
  String? frontSide,
}) {
  final StringBuffer out = StringBuffer();
  _renderStrict(
    _parse(_tokenize(template), strict: true),
    _RenderContext(
      fields: fields,
      nonEmpty: _nonEmptyFields(fields),
      cardOrd: cardOrd,
      frontSide: frontSide,
    ),
    out,
  );
  return out.toString();
}

class _RenderContext {
  _RenderContext({
    required this.fields,
    required this.nonEmpty,
    required this.cardOrd,
    required this.frontSide,
  });

  final Map<String, String> fields;
  final Set<String> nonEmpty;
  final int cardOrd;
  final String? frontSide;

  bool get isQuestion => frontSide == null;

  bool evaluateConditional(String key, {required bool negated}) {
    if (nonEmpty.contains(key)) return !negated;
    if (fields.containsKey(key) || _isClozeConditional(key)) return negated;
    throw AnkiTemplateError(
      'Found {{${negated ? '^' : '#'}$key}}, but there is no field called '
      "'$key'",
    );
  }
}

bool _isClozeConditional(String key) => _clozeConditionalPattern.hasMatch(key);

final RegExp _clozeConditionalPattern = RegExp(r'^c\d+$');

void _renderStrict(List<_Node> nodes, _RenderContext ctx, StringBuffer out) {
  for (final _Node node in nodes) {
    switch (node) {
      case _TextNode(:final String text):
        out.write(text);
      case _CommentNode(:final String text):
        out.write('$_commentStart$text$_commentEnd');
      case _ReplacementNode(:final String key) when key == 'FrontSide':
        out.write(ctx.frontSide ?? '');
      case _ReplacementNode(:final String key, :final List<String> filters):
        if (key.isEmpty && filters.isNotEmpty) continue;
        final String? value = ctx.fields[key];
        if (value == null) {
          final String prefix = filters.reversed
              .map((String f) => '$f:')
              .join();
          throw AnkiTemplateError(
            'Found {{$prefix$key}}, but there is no field called \'$key\'',
          );
        }
        out.write(_applyFilters(value, filters, key, ctx));
      case _ConditionalNode(
        :final String key,
        :final bool negated,
        :final List<_Node> children,
      ):
        if (ctx.evaluateConditional(key, negated: negated)) {
          _renderStrict(children, ctx, out);
        } else {
          // 与 rslib 一致：不输出，但照样检查子树的错误。
          _renderStrict(children, ctx, StringBuffer());
        }
    }
  }
}

// ---------------------------------------------------------------------------
// 过滤器（rslib template_filters.rs）
// ---------------------------------------------------------------------------

String _applyFilters(
  String text,
  List<String> filters,
  String fieldName,
  _RenderContext ctx,
) {
  // 最外层是 type: —— 类型答案暂不支持，输出空串（rslib 输出 [[type:…]]）。
  if (filters.isNotEmpty && filters.last == 'type') return '';
  String current = text;
  for (final String filter in filters) {
    current = _applyFilter(filter, current, fieldName, ctx);
  }
  return current;
}

String _applyFilter(
  String filter,
  String text,
  String fieldName,
  _RenderContext ctx,
) {
  switch (filter) {
    case 'text':
      return ankiStripHtml(text);
    case 'furigana':
      return ankiFuriganaFilter(text);
    case 'kanji':
      return ankiKanjiFilter(text);
    case 'kana':
      return ankiKanaFilter(text);
    case 'type' || 'type-cloze' || 'type-nc':
      return '';
    case 'hint':
      return ankiHintFilter(text, fieldName);
    case 'cloze':
      return ankiClozeFilter(text, ctx.cardOrd, question: ctx.isQuestion);
    case 'cloze-only':
      return ankiClozeOnlyFilter(text, ctx.cardOrd, question: ctx.isQuestion);
    case '':
      return text;
  }
  if (filter.startsWith('tts ')) {
    return ankiTtsFilter(filter.substring(4), text);
  }
  // 未知过滤器：非 partial 模式下 Anki 直接忽略，文本原样往下传。
  return text;
}

final RegExp _furiganaPattern = RegExp(r' ?([^ >]+?)\[(.+?)\]', unicode: true);

String _rubyReplace(String text, String Function(RegExpMatch m) build) {
  return text.replaceAll('&nbsp;', ' ').replaceAllMapped(_furiganaPattern, (
    Match m,
  ) {
    final RegExpMatch match = m as RegExpMatch;
    if (match.group(2)!.startsWith('sound:')) return match.group(0)!;
    return build(match);
  });
}

/// `furigana:` —— `漢字[かんじ]` → `<ruby><rb>漢字</rb><rt>かんじ</rt></ruby>`。
String ankiFuriganaFilter(String text) => _rubyReplace(
  text,
  (RegExpMatch m) =>
      '<ruby><rb>${m.group(1)}</rb><rt>${m.group(2)}</rt></ruby>',
);

/// `kana:` —— 只留读音。
String ankiKanaFilter(String text) =>
    _rubyReplace(text, (RegExpMatch m) => m.group(2)!);

/// `kanji:` —— 只留汉字。
String ankiKanjiFilter(String text) =>
    _rubyReplace(text, (RegExpMatch m) => m.group(1)!);

/// `tts <选项>:` —— 输出宿主处理的 TTS 标记。
String ankiTtsFilter(String options, String text) =>
    '[anki:tts lang=$options]$text[/anki:tts]';

/// `hint:` —— 点击展开的提示。DOM id 用 sha256 前 8 字节（rslib 用 blake3，
/// id 只需唯一，不影响行为）。
String ankiHintFilter(String text, String fieldName) {
  if (text.trim().isEmpty) return text;
  final List<int> digest = sha256
      .convert(<int>[...utf8.encode(text), ...utf8.encode(fieldName)])
      .bytes
      .sublist(0, 8);
  final String id = digest
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '\n<a class=hint href="#"\n'
      "onclick=\"this.style.display='none';\n"
      "document.getElementById('hint$id').style.display='block';\n"
      'return false;" draggable=false>\n'
      '$fieldName</a>\n'
      '<div id="hint$id" class=hint style="display: none">$text</div>\n';
}

// ---------------------------------------------------------------------------
// HTML 去除（rslib text.rs `strip_html`）
// ---------------------------------------------------------------------------

final RegExp _htmlPattern = RegExp(
  r'(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)|(<.*?>)',
  caseSensitive: false,
  dotAll: true,
);

/// 去掉 HTML 标签（含注释、style、script 整段）但保留实体。
String ankiStripHtmlPreservingEntities(String html) =>
    html.replaceAll(_htmlPattern, '');

/// 去掉 HTML 标签并解码实体（`&nbsp;` 解成普通空格）。
String ankiStripHtml(String html) =>
    _decodeEntities(ankiStripHtmlPreservingEntities(html));

const Map<String, String> _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ensp': ' ',
  'emsp': ' ',
  'thinsp': ' ',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'middot': '·',
  'times': '×',
  'divide': '÷',
  'copy': '©',
  'reg': '®',
  'deg': '°',
  'laquo': '«',
  'raquo': '»',
  'shy': '­',
  'zwj': '‍',
  'zwnj': '‌',
};

final RegExp _entityPattern = RegExp(
  r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);',
);

/// 实体解码。只认数字实体与常用命名实体；不认得的原样保留
/// （rslib 用 htmlescape 全表，遇不认得的实体会整段放弃解码）。
String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entityPattern, (Match m) {
    final String body = m.group(1)!;
    if (body.startsWith('#')) {
      final bool hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final int? code = int.tryParse(
        hex ? body.substring(2) : body.substring(1),
        radix: hex ? 16 : 10,
      );
      if (code == null || code > 0x10FFFF) return m.group(0)!;
      return code == 0xA0 ? ' ' : String.fromCharCode(code);
    }
    return _namedEntities[body] ?? m.group(0)!;
  });
}

// ---------------------------------------------------------------------------
// Cloze（rslib cloze.rs）
// ---------------------------------------------------------------------------

sealed class _ClozeTok {}

class _ClozeOpen extends _ClozeTok {
  _ClozeOpen(this.ordinals);
  final List<int> ordinals;
}

class _ClozeText extends _ClozeTok {
  _ClozeText(this.text);
  final String text;
}

class _ClozeClose extends _ClozeTok {}

/// 解析 `{{c1,2::` 开头；成功返回 (序号, 消耗长度)。
(List<int>, int)? _openCloze(String text, int at) {
  if (!text.startsWith('{{c', at)) return null;
  int i = at + 3;
  while (i < text.length) {
    final int c = text.codeUnitAt(i);
    if ((c >= 0x30 && c <= 0x39) || c == 0x2C) {
      i++;
    } else {
      break;
    }
  }
  final Set<int> set = <int>{};
  for (final String part in text.substring(at + 3, i).split(',')) {
    final int? n = int.tryParse(part);
    if (n != null && n >= 0 && n <= 0xFFFF) set.add(n);
  }
  if (set.isEmpty) return null;
  if (!text.startsWith('::', i)) return null;
  return (set.toList()..sort(), i + 2 - at);
}

/// MathJax 状态：表达式内的 `}}` 只能关掉在同一表达式里打开的 cloze。
class _MathJaxState {
  (String, int)? current;
  int nextId = 0;
  final List<int?> clozeRegions = <int?>[];

  int? get region => current?.$2;

  bool get canCloseCloze {
    final int? r = region;
    if (r == null) return true;
    return clozeRegions.isNotEmpty && clozeRegions.last == r;
  }

  int? consumeDelimiter(String text, int at) {
    final (String, int)? cur = current;
    if (cur == null) {
      for (final (String open, String close) in const <(String, String)>[
        (r'\(', r'\)'),
        (r'\[', r'\]'),
      ]) {
        if (text.startsWith(open, at) &&
            text.indexOf(close, at + open.length) >= 0) {
          current = (close, nextId);
          nextId++;
          return open.length;
        }
      }
      return null;
    }
    if (text.startsWith(cur.$1, at)) {
      current = null;
      return cur.$1.length;
    }
    return null;
  }
}

List<_ClozeTok> _clozeTokenize(String text) {
  final List<_ClozeTok> out = <_ClozeTok>[];
  final _MathJaxState state = _MathJaxState();
  int pos = 0;
  while (pos < text.length) {
    final (List<int>, int)? open = _openCloze(text, pos);
    if (open != null) {
      state.clozeRegions.add(state.region);
      out.add(_ClozeOpen(open.$1));
      pos += open.$2;
      continue;
    }
    if (state.canCloseCloze && text.startsWith('}}', pos)) {
      if (state.clozeRegions.isNotEmpty) state.clozeRegions.removeLast();
      out.add(_ClozeClose());
      pos += 2;
      continue;
    }
    int i = pos;
    while (i < text.length) {
      if (_openCloze(text, i) != null ||
          (state.canCloseCloze && text.startsWith('}}', i))) {
        break;
      }
      final int? consumed = state.consumeDelimiter(text, i);
      if (consumed != null) {
        i += consumed;
      } else {
        final int c = text.codeUnitAt(i);
        i += (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) ? 2 : 1;
      }
    }
    out.add(_ClozeText(text.substring(pos, i)));
    pos = i;
  }
  return out;
}

sealed class _ClozeNode {}

class _ClozeTextNode extends _ClozeNode {
  _ClozeTextNode(this.text);
  final String text;
}

class _Cloze extends _ClozeNode {
  _Cloze(this.ordinals);
  final List<int> ordinals;
  final List<_ClozeNode> nodes = <_ClozeNode>[];
  String? hintText;

  String get hint => hintText ?? '...';

  String get clozedText {
    final StringBuffer buf = StringBuffer();
    for (final _ClozeNode node in nodes) {
      switch (node) {
        case _ClozeTextNode(:final String text):
          buf.write(text);
        case _Cloze():
          buf.write(node.clozedText);
      }
    }
    return buf.toString();
  }

  String get ordinalsStr => ordinals.join(',');
}

List<_ClozeNode> _parseClozes(String text) {
  final List<_Cloze> open = <_Cloze>[];
  final List<_ClozeNode> output = <_ClozeNode>[];
  for (final _ClozeTok tok in _clozeTokenize(text)) {
    switch (tok) {
      case _ClozeOpen(:final List<int> ordinals):
        if (open.length < 10) open.add(_Cloze(ordinals));
      case _ClozeText(:final String text):
        if (open.isEmpty) {
          output.add(_ClozeTextNode(text));
          continue;
        }
        String body = text;
        if (!body.startsWith('image-occlusion:')) {
          final int sep = body.indexOf('::');
          if (sep >= 0) {
            open.last.hintText = body.substring(sep + 2);
            body = body.substring(0, sep);
          }
        }
        open.last.nodes.add(_ClozeTextNode(body));
      case _ClozeClose():
        if (open.isEmpty) {
          output.add(_ClozeTextNode('}}'));
          continue;
        }
        final _Cloze cloze = open.removeLast();
        (open.isEmpty ? output : open.last.nodes).add(cloze);
    }
  }
  return output;
}

/// htmlescape `encode_attribute`：`"&'<>` 用实体，其余 <256 的非字母数字转 `&#xHH;`。
String _encodeAttribute(String s) {
  final StringBuffer buf = StringBuffer();
  for (final int c in s.runes) {
    switch (c) {
      case 0x22:
        buf.write('&quot;');
      case 0x26:
        buf.write('&amp;');
      case 0x27:
        buf.write('&#x27;');
      case 0x3C:
        buf.write('&lt;');
      case 0x3E:
        buf.write('&gt;');
      default:
        final bool alnum =
            (c >= 0x30 && c <= 0x39) ||
            (c >= 0x41 && c <= 0x5A) ||
            (c >= 0x61 && c <= 0x7A);
        if (c < 256 && !alnum) {
          buf.write('&#x${c.toRadixString(16).toUpperCase().padLeft(2, '0')};');
        } else {
          buf.writeCharCode(c);
        }
    }
  }
  return buf.toString();
}

/// 返回本 cloze 树里是否出现了 [ord]。
bool _revealCloze(_Cloze cloze, int ord, bool question, StringBuffer buf) {
  final bool active = cloze.ordinals.contains(ord);
  bool found = active;
  void children(StringBuffer target) {
    for (final _ClozeNode node in cloze.nodes) {
      switch (node) {
        case _ClozeTextNode(:final String text):
          target.write(text);
        case _Cloze():
          found = _revealCloze(node, ord, question, target) || found;
      }
    }
  }

  if (question && active) {
    final StringBuffer content = StringBuffer();
    children(content);
    buf.write(
      '<span class="cloze" data-cloze="${_encodeAttribute(content.toString())}" '
      'data-ordinal="${cloze.ordinalsStr}">[${cloze.hint}]</span>',
    );
  } else if (!question && active) {
    buf.write('<span class="cloze" data-ordinal="${cloze.ordinalsStr}">');
    children(buf);
    buf.write('</span>');
  } else {
    buf.write(
      '<span class="cloze-inactive" data-ordinal="${cloze.ordinalsStr}">',
    );
    children(buf);
    buf.write('</span>');
  }
  return found;
}

/// rslib `reveal_cloze_text`：[ord] 是 1 起的 cloze 序号（c1 → 1）。
/// 文本里没有该序号的 cloze 时返回空串（Anki 据此把卡当空）。
String ankiRevealClozeText(String text, int ord, {required bool question}) {
  final StringBuffer buf = StringBuffer();
  bool found = false;
  for (final _ClozeNode node in _parseClozes(text)) {
    switch (node) {
      case _ClozeTextNode(:final String text):
        buf.write(text);
      case _Cloze():
        found = _revealCloze(node, ord, question, buf) || found;
    }
  }
  return found ? buf.toString() : '';
}

void _revealTextOnly(
  _ClozeNode node,
  int ord,
  bool question,
  List<String> out,
) {
  if (node is! _Cloze) return;
  if (node.ordinals.contains(ord)) {
    out.add(question ? node.hint : node.clozedText);
  }
  for (final _ClozeNode child in node.nodes) {
    _revealTextOnly(child, ord, question, out);
  }
}

/// rslib `reveal_cloze_text_only`（`cloze-only:` 过滤器）。
String ankiRevealClozeTextOnly(String text, int ord, {required bool question}) {
  final List<String> out = <String>[];
  for (final _ClozeNode node in _parseClozes(text)) {
    _revealTextOnly(node, ord, question, out);
  }
  return out.join(', ');
}

final RegExp _mathJaxPattern = RegExp(
  r'(\\[(\[])(.*?)(\\[\])])',
  caseSensitive: false,
  dotAll: true,
);

String _stripHtmlInsideMathJax(String text) => text.replaceAllMapped(
  _mathJaxPattern,
  (Match m) =>
      '${m.group(1)}${ankiStripHtmlPreservingEntities(m.group(2)!)}${m.group(3)}',
);

/// `cloze:` 过滤器。[cardOrd] 是 0 起的卡片序号（第 1 张卡 → c1）。
String ankiClozeFilter(String text, int cardOrd, {required bool question}) =>
    _stripHtmlInsideMathJax(
      ankiRevealClozeText(text, cardOrd + 1, question: question),
    );

/// `cloze-only:` 过滤器。
String ankiClozeOnlyFilter(
  String text,
  int cardOrd, {
  required bool question,
}) => ankiRevealClozeTextOnly(text, cardOrd + 1, question: question);

/// 文本里出现的全部 cloze 序号（`c0` 不算；`{{c1,2::x}}` 计 1、2；含嵌套）。
Set<int> clozeOrdinalsIn(String text) {
  final Set<int> set = <int>{};
  void walk(List<_ClozeNode> nodes) {
    for (final _ClozeNode node in nodes) {
      if (node is _Cloze) {
        for (final int o in node.ordinals) {
          if (o != 0) set.add(o);
        }
        walk(node.nodes);
      }
    }
  }

  walk(_parseClozes(text));
  return set;
}

// ---------------------------------------------------------------------------
// 字段引用：名字 ↔ fld:<id>
// ---------------------------------------------------------------------------

/// 不参与名字 ↔ id 互转的特殊字段（Anki 不允许笔记字段用这些名字）。
const Set<String> kAnkiSpecialFieldNames = <String>{
  'FrontSide',
  'Tags',
  'Type',
  'Deck',
  'Subdeck',
  'CardFlag',
  'Card',
  'CardID',
};

/// 模板里按 id 引用字段时 key 的前缀：`{{fld:<id>}}` / `{{#fld:<id>}}`。
const String kAnkiFieldIdPrefix = 'fld:';

/// 把模板里 `{{…}}`（含过滤器前缀与 `#`/`^`/`/` 段标记）引用的字段名换成
/// `fld:<id>`。注释内的标签与 Anki 一样不动；特殊字段、cN 段与表里没有的名字
/// 原样保留。与 [templateIdsToNames] 往返无损。
String templateNamesToIds(String template, Map<String, String> nameToId) {
  return _rewriteKeys(template, (String key, bool section) {
    if (kAnkiSpecialFieldNames.contains(key) || _isClozeConditional(key)) {
      return null;
    }
    final String? id = nameToId[key];
    return id == null ? null : '$kAnkiFieldIdPrefix$id';
  });
}

/// [templateNamesToIds] 的逆：`fld:<id>` → 字段名；表里没有的 id 原样保留。
String templateIdsToNames(String template, Map<String, String> idToName) {
  return _rewriteKeys(template, (String key, bool section) {
    if (!key.startsWith(kAnkiFieldIdPrefix)) return null;
    return idToName[key.substring(kAnkiFieldIdPrefix.length)];
  });
}

/// 逐个 handlebar 改写 key。replacement 的 key 是最后一个 `:` 之后的部分，
/// 但 `fld:<id>` 形式要把末两段当一个 key。
String _rewriteKeys(
  String template,
  String? Function(String key, bool section) rewrite,
) {
  final StringBuffer out = StringBuffer();
  for (final _Tok tok in _tokenize(template)) {
    if (tok.kind == _TokKind.text ||
        tok.kind == _TokKind.comment ||
        tok.kind == _TokKind.prelude) {
      out.write(tok.raw);
      continue;
    }
    int keyStart = tok.keyStart;
    final bool section = tok.kind != _TokKind.replacement;
    if (!section) {
      // `…:fld:<id>`：把 `fld:` 一起算进 key。
      final String before = tok.inner.substring(0, keyStart);
      if (before.endsWith(kAnkiFieldIdPrefix) &&
          before.length - kAnkiFieldIdPrefix.length >= tok._replacementStart) {
        keyStart -= kAnkiFieldIdPrefix.length;
      }
    }
    final String key = tok.inner.substring(keyStart, tok.keyEnd);
    final String? replaced = rewrite(key, section);
    if (replaced == null) {
      out.write(tok.raw);
      continue;
    }
    out
      ..write(tok.startTag)
      ..write(tok.inner.substring(0, keyStart))
      ..write(replaced)
      ..write(tok.inner.substring(tok.keyEnd))
      ..write(tok.endTag);
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// lang 容器
// ---------------------------------------------------------------------------

/// 给卡面 HTML 包一层带 `lang` 的容器（AnkiDroid #19431：没有 lang 时 WebView 按
/// 系统语言选字形，中日韩汉字会显示成错误地区的字形）。[languageCode] 为空时
/// 原样返回。
String wrapAnkiCardHtmlWithLang(String html, String? languageCode) {
  final String? code = languageCode?.trim();
  if (code == null || code.isEmpty) return html;
  return '<div lang="${const HtmlEscape(HtmlEscapeMode.attribute).convert(code)}">'
      '$html</div>';
}
