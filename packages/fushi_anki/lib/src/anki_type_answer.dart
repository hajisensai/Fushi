/// Anki「打字输入答案」（`{{type:Field}}`）在内置复习里的落地，对齐 Anki 复习器（`reviewer.py`
/// 的 `typeAnsQuestionFilter` / `typeAnsAnswerFilter` 与 rslib `typeanswer.rs`）：
///
/// 1. 模板渲染（[renderAnkiCard]）与 rslib 一样把 `{{type:…}}` 输出成 `[[type:…]]` 标记；
/// 2. [ankiResolveTypeAnswer] 按字段值把标记换掉：**问题面**第一个标记 → 输入框
///    （`<input id="typeans">`，其余标记去掉，Anki 一张卡只支持一个打字框）；**答案面**每个标记 →
///    带期望答案的占位（[kAnkiTypeAnswerSlotClass]，期望答案已按 Anki 口径算好：去 HTML、`cloze:`
///    取本卡的挖空内容、`nc:` 比对时忽略组合附加符号）；
/// 3. 卡面拿到用户在问题面打的字后，[ankiFillTypeAnswer] 把答案面占位换成比对结果
///    （逐字对齐：打对的 `typeGood`、打错的 `typeBad`、漏打的 `typeMissed`，与 Anki 同一组类名，
///    卡片 CSS 里给这些类写的样式照样生效）。
///
/// 字段不存在时与 Anki 一样在卡面上写出提示，不抛错。
library;

import 'dart:convert' show HtmlEscape, HtmlEscapeMode;

import 'package:fushi_anki/src/anki_template_render.dart'
    show ankiClozeOnlyFilter, ankiStripHtml;

/// 答案面占位元素的类名（[ankiResolveTypeAnswer] 写出、[ankiFillTypeAnswer] 换掉）。
const String kAnkiTypeAnswerSlotClass = 'fushi-typeans-slot';

/// 问题面输入框的 id（与 Anki 相同，模板脚本 / CSS 里写 `#typeans` 的照样命中）。
const String kAnkiTypeAnswerInputId = 'typeans';

final RegExp _marker = RegExp(r'\[\[type:(.+?)\]\]');

final RegExp _slot = RegExp(
  '<span class="$kAnkiTypeAnswerSlotClass" data-expected="([^"]*)"'
  ' data-combining="([01])"></span>',
);

const HtmlEscape _attr = HtmlEscape();
const HtmlEscape _text = HtmlEscape(HtmlEscapeMode.element);

/// 这面卡有没有打字框（问题面渲染结果里有 `[[type:…]]` 标记）。
bool ankiHasTypeAnswer(String html) => _marker.hasMatch(html);

/// 一个 `[[type:…]]` 标记解析出的字段与比对方式。
({String field, bool cloze, bool combining}) _parseMarker(String body) {
  bool cloze = false;
  bool combining = true;
  String rest = body;
  while (true) {
    if (rest.startsWith('cloze:')) {
      cloze = true;
      rest = rest.substring(6);
    } else if (rest.startsWith('nc:')) {
      combining = false;
      rest = rest.substring(3);
    } else {
      break;
    }
  }
  return (field: rest, cloze: cloze, combining: combining);
}

/// 期望答案：字段去 HTML（`cloze:` 时取本卡 [cardOrd] 的挖空内容），首尾空白去掉。
String _expected(String value, {required bool cloze, required int cardOrd}) {
  final String raw = cloze
      ? ankiClozeOnlyFilter(value, cardOrd, question: false)
      : value;
  return ankiStripHtml(
    raw.replaceAll(RegExp(r'\[sound:[^\]]*\]'), ''),
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 按字段值把 `[[type:…]]` 标记换成问题面的输入框 / 答案面的期望答案占位。
///
/// [fields] 是按字段名的字段值（与渲染用的同一份）；[cardOrd] 0 起（填空卡 = cN − 1）。
({String question, String answer}) ankiResolveTypeAnswer({
  required String question,
  required String answer,
  required Map<String, String> fields,
  required int cardOrd,
}) {
  if (!ankiHasTypeAnswer(question) && !ankiHasTypeAnswer(answer)) {
    return (question: question, answer: answer);
  }
  String missing(String field) =>
      '<span class="fushi-typeans-error">'
      '${_text.convert('Type answer: unknown field $field')}</span>';

  bool inputPlaced = false;
  final String q = question.replaceAllMapped(_marker, (Match m) {
    final ({String field, bool cloze, bool combining}) spec = _parseMarker(
      m.group(1)!,
    );
    if (!fields.containsKey(spec.field)) return missing(spec.field);
    if (inputPlaced) return '';
    inputPlaced = true;
    return '<input type="text" id="$kAnkiTypeAnswerInputId" '
        'class="fushi-typeans-input" autocomplete="off" autocorrect="off" '
        'autocapitalize="off" spellcheck="false">';
  });
  final String a = answer.replaceAllMapped(_marker, (Match m) {
    final ({String field, bool cloze, bool combining}) spec = _parseMarker(
      m.group(1)!,
    );
    final String? value = fields[spec.field];
    if (value == null) return missing(spec.field);
    final String expected = _expected(
      value,
      cloze: spec.cloze,
      cardOrd: cardOrd,
    );
    return '<span class="$kAnkiTypeAnswerSlotClass" '
        'data-expected="${_attr.convert(expected)}" '
        'data-combining="${spec.combining ? 1 : 0}"></span>';
  });
  return (question: q, answer: a);
}

/// 答案面有没有待填的比对占位。
bool ankiHasTypeAnswerSlot(String html) => _slot.hasMatch(html);

/// 把答案面的比对占位换成 [typed]（用户在问题面打的字）与期望答案的比对结果。
String ankiFillTypeAnswer(String answerHtml, String typed) =>
    answerHtml.replaceAllMapped(_slot, (Match m) {
      final String expected = _unescapeAttr(m.group(1)!);
      return ankiTypeAnswerComparison(
        typed,
        expected,
        combining: m.group(2) == '1',
      );
    });

String _unescapeAttr(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#47;', '/')
    .replaceAll('&amp;', '&');

/// 比对时忽略的组合附加符号（`nc:`）：拉丁 / 通用组合附加符号区段。
bool _isCombining(int rune) =>
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE20 && rune <= 0xFE2F);

/// 比对结果 HTML（与 Anki 同形）：
/// - 没打字：只显示期望答案；
/// - 完全打对：期望答案整段 `typeGood`；
/// - 否则：上行是打的字（对的 `typeGood`、错的 `typeBad`），箭头，下行是期望答案（对上的
///   `typeGood`、漏打的 `typeMissed`）。逐字按最长公共子序列对齐。
///
/// [combining] = false（`nc:`）时比对前去掉组合附加符号（显示的仍是原文）。
String ankiTypeAnswerComparison(
  String typed,
  String expected, {
  bool combining = true,
}) {
  final String given = typed.replaceAll(RegExp(r'\s+'), ' ').trim();
  String open(String inner) =>
      '<code id="$kAnkiTypeAnswerInputId" class="fushi-typeans-result">'
      '$inner</code>';
  if (given.isEmpty) return open(_text.convert(expected));
  final List<int> a = given.runes.toList();
  final List<int> b = expected.runes.toList();
  List<int> key(List<int> r) =>
      combining ? r : <int>[for (final int c in r) _isCombining(c) ? -1 : c];
  final List<int> ka = key(a), kb = key(b);
  bool same() {
    final List<int> x = ka.where((int c) => c != -1).toList();
    final List<int> y = kb.where((int c) => c != -1).toList();
    if (x.length != y.length) return false;
    for (int i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  if (same()) {
    return open(_span('typeGood', String.fromCharCodes(b)));
  }
  final (List<bool> goodA, List<bool> goodB) = _align(ka, kb);
  return open(
    '${_runs(a, goodA, good: 'typeGood', bad: 'typeBad')}'
    '<br><span id="typearrow">&darr;</span><br>'
    '${_runs(b, goodB, good: 'typeGood', bad: 'typeMissed')}',
  );
}

String _span(String cls, String text) =>
    '<span class="$cls">${_text.convert(text)}</span>';

/// 连续同类的字并成一段。
String _runs(
  List<int> runes,
  List<bool> ok, {
  required String good,
  required String bad,
}) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < runes.length) {
    final bool g = ok[i];
    int j = i;
    while (j < runes.length && ok[j] == g) {
      j++;
    }
    out.write(_span(g ? good : bad, String.fromCharCodes(runes.sublist(i, j))));
    i = j;
  }
  return out.toString();
}

/// 最长公共子序列对齐：两边各自哪些字在公共子序列里（-1 = 被忽略的组合符号，算「对」）。
/// 超长输入（> 2000 字）不做 O(n·m) 对齐，整段按不对处理。
(List<bool>, List<bool>) _align(List<int> a, List<int> b) {
  final int n = a.length, m = b.length;
  final List<bool> ga = List<bool>.filled(n, false);
  final List<bool> gb = List<bool>.filled(m, false);
  if (n > 2000 || m > 2000) return (ga, gb);
  final List<List<int>> dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j] && a[i] != -1
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  int i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == -1) {
      ga[i++] = true;
    } else if (b[j] == -1) {
      gb[j++] = true;
    } else if (a[i] == b[j]) {
      ga[i++] = true;
      gb[j++] = true;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  while (i < n) {
    if (a[i] == -1) ga[i] = true;
    i++;
  }
  while (j < m) {
    if (b[j] == -1) gb[j] = true;
    j++;
  }
  return (ga, gb);
}
