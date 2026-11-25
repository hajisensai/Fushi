/// 卡片字段 AI 的回复解析与字段 HTML 清洗。
///
/// 每个字段动作的回复有两种模式（[AiSrsFieldResponseMode]）：
/// - `plain`：整段回复就是字段新内容（容忍整段裹在一个 Markdown 代码围栏里）。
/// - `structured`：回复是 `{"value": "...", "explanation": "..."}`，多余的键忽略。
///
/// 两种模式都把纯文本换行转成 `<br>`，再经 [aiSrsFieldSanitizeHtml] 清洗：用 `package:html`
/// 解析成 DOM、按白名单**重建**，所以输出永远是配平、合法嵌套的 HTML（以前的正则清洗只删
/// 标签不配平，`<b>foo` 会把半截标签写进 Anki 字段）。
///
/// 结构化回复认不出时**不**拿原文顶替字段值：抛 [AiSrsFieldReplyError]（带原文），由 UI
/// 提供显式的「按文本使用」。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;

import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart'
    show aiSrsPlainText;

/// 字段动作期待的回复形态。wire 值 `plain` / `structured` 冻结（存进偏好）。
enum AiSrsFieldResponseMode {
  /// 整段回复 = 字段值。
  plain,

  /// JSON `{"value", "explanation"}`。
  structured,
}

/// [AiSrsFieldResponseMode] 的冻结 wire 值。
String aiSrsFieldResponseModeWire(AiSrsFieldResponseMode mode) =>
    switch (mode) {
      AiSrsFieldResponseMode.plain => 'plain',
      AiSrsFieldResponseMode.structured => 'structured',
    };

/// 从 wire 值还原；认不出（含 null）返回 null，由调用方取默认。
AiSrsFieldResponseMode? aiSrsFieldResponseModeFromWire(String? wire) =>
    switch (wire) {
      'plain' => AiSrsFieldResponseMode.plain,
      'structured' => AiSrsFieldResponseMode.structured,
      _ => null,
    };

/// 清洗后字段值的长度上限（HTML 字符串的字符数）。
const int kAiSrsFieldValueMax = 2000;

/// 一次字段 AI 的产物：字段新内容（已清洗的 HTML）+ 说明（纯文本，没有时为 `''`）。
class AiSrsFieldSuggestion {
  const AiSrsFieldSuggestion({required this.value, required this.explanation});

  final String value;
  final String explanation;
}

/// 回复解析失败的种类。
enum AiSrsFieldReplyErrorKind {
  /// 回复没有可见内容（或值清洗后为空）。
  empty,

  /// 结构化回复认不出：不是 JSON 对象、缺 `value`、`value` 不是字符串。
  malformed,
}

/// 回复解析失败；[raw] 是模型原样回复，供「查看回复」/「按文本使用」。
class AiSrsFieldReplyError implements Exception {
  const AiSrsFieldReplyError(this.kind, this.raw);

  final AiSrsFieldReplyErrorKind kind;
  final String raw;

  @override
  String toString() => 'AiSrsFieldReplyError(${kind.name})';
}

/// 解析模型回复。失败抛 [AiSrsFieldReplyError]。
AiSrsFieldSuggestion parseAiSrsFieldReply(
  String reply,
  AiSrsFieldResponseMode mode,
) {
  if (reply.trim().isEmpty) {
    throw AiSrsFieldReplyError(AiSrsFieldReplyErrorKind.empty, reply);
  }
  switch (mode) {
    case AiSrsFieldResponseMode.plain:
      final String value = _fieldValue(_unfence(reply.trim()));
      if (!_hasVisibleText(value)) {
        throw AiSrsFieldReplyError(AiSrsFieldReplyErrorKind.empty, reply);
      }
      return AiSrsFieldSuggestion(value: value, explanation: '');
    case AiSrsFieldResponseMode.structured:
      final Map<String, Object?>? json = decodeAiJsonObject(reply);
      final Object? rawValue = json?['value'];
      if (rawValue is! String) {
        throw AiSrsFieldReplyError(AiSrsFieldReplyErrorKind.malformed, reply);
      }
      final String value = _fieldValue(rawValue);
      if (!_hasVisibleText(value)) {
        throw AiSrsFieldReplyError(AiSrsFieldReplyErrorKind.empty, reply);
      }
      final Object? explanation = json!['explanation'];
      return AiSrsFieldSuggestion(
        value: value,
        explanation: explanation is String
            ? aiSrsPlainText(explanation, 300)
            : '',
      );
  }
}

// 整段回复恰好裹在一个代码围栏里（可带语言标记）。
final RegExp _wholeFence = RegExp(
  r'^```[A-Za-z0-9_+.\-]*[ \t]*\r?\n([\s\S]*?)\r?\n?[ \t]*```$',
);

String _unfence(String trimmed) {
  final RegExpMatch? m = _wholeFence.firstMatch(trimmed);
  if (m == null) return trimmed;
  final String inner = m.group(1)!;
  // 里面还有围栏 = 不是「整段一个围栏」，原样交给清洗。
  if (inner.contains('```')) return trimmed;
  return inner;
}

final RegExp _lineStructureTag = RegExp(
  r'<(?:br|li|p|div)\b',
  caseSensitive: false,
);

/// 换行规整 + 清洗：值里没有表达换行的标签时，把纯文本换行转成 `<br>`。
String _fieldValue(String raw) {
  String s = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (!_lineStructureTag.hasMatch(s)) {
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n').replaceAll('\n', '<br>');
  }
  return aiSrsFieldSanitizeHtml(s);
}

final RegExp _anyTag = RegExp(r'<[^>]*>');

// 清洗后的输出是规范 HTML（文字里的 `<`/`>` 都已转义），去标签即是可见文字。
bool _hasVisibleText(String sanitized) =>
    sanitized.replaceAll(_anyTag, '').trim().isNotEmpty;

// ---------------------------------------------------------------------------
// 清洗
// ---------------------------------------------------------------------------

/// 白名单元素：重建时不带任何属性。
const Set<String> _kAllowed = <String>{
  'b',
  'i',
  'u',
  'br',
  'ul',
  'ol',
  'li',
  'ruby',
  'rt',
  'rp',
  'div',
  'p',
  'span',
  'mark',
  'sub',
  'sup',
};

/// 换名后进白名单。
const Map<String, String> _kRenamed = <String, String>{
  'strong': 'b',
  'em': 'i',
};

/// 连同内容整段丢弃。
const Set<String> _kDropped = <String>{
  'script',
  'style',
  'iframe',
  'object',
  'embed',
  'template',
  'noscript',
  'svg',
  'math',
  'head',
  'title',
  'textarea',
  'select',
  'button',
  'input',
  'form',
  'link',
  'meta',
  'base',
};

/// 打开时会关掉外层 `<p>` 的块元素（HTML 解析规则），不能出现在 `<p>` 里。
const Set<String> _kClosesP = <String>{'div', 'p', 'ul', 'ol', 'li'};

/// `<rt>` / `<rp>` 打开时（外层有 `<ruby>`）会被隐式关掉的父元素。
const Set<String> _kRubyImpliedEnd = <String>{'li', 'p', 'rt', 'rp'};

sealed class _Node {}

final class _Text extends _Node {
  _Text(this.data);
  final String data;
}

final class _Elem extends _Node {
  _Elem(this.name, this.children);
  final String name;
  final List<_Node> children;
}

/// 基于 DOM 的白名单清洗；输出永远配平，长度不超过 [max]。
///
/// - 白名单元素去掉全部属性重建；`strong`→`b`、`em`→`i`。
/// - 脚本 / 样式 / 嵌入 / 表单等连同内容丢弃；其它元素拆壳、保留子内容；注释丢弃。
/// - 文字转义 `&`、`<`、`>`；空的包裹元素（如 `<b></b>`）丢弃。
/// - 拆壳后会被 HTML 解析器重新排布的嵌套（`<p>` 里的块、`<li>` 直接套 `<li>` 等）也拆壳，
///   保证 `sanitize(sanitize(x)) == sanitize(x)`。
/// - 截断不破坏标记：预算用完就停，文字按字符截，已打开的标签照样关上。
String aiSrsFieldSanitizeHtml(String raw, {int max = kAiSrsFieldValueMax}) {
  if (max <= 0 || raw.isEmpty) return '';
  final dom.DocumentFragment fragment = parseFragment(raw);
  final List<_Node> tree = <_Node>[];
  _rebuild(fragment.nodes, tree, <String>[]);
  final _Writer writer = _Writer(max);
  writer.writeAll(tree);
  return writer.out.toString().trim();
}

void _rebuild(List<dom.Node> nodes, List<_Node> into, List<String> stack) {
  for (final dom.Node node in nodes) {
    if (node is dom.Text) {
      if (node.data.isNotEmpty) into.add(_Text(node.data));
      continue;
    }
    if (node is! dom.Element) continue; // 注释等
    final String tag = (node.localName ?? '').toLowerCase();
    if (_kDropped.contains(tag)) continue;
    final String name = _kRenamed[tag] ?? tag;
    if (!_kAllowed.contains(name) || !_canNest(name, stack)) {
      _rebuild(node.nodes, into, stack); // 拆壳
      continue;
    }
    if (name == 'br') {
      into.add(_Elem('br', const <_Node>[]));
      continue;
    }
    final List<_Node> children = <_Node>[];
    stack.add(name);
    _rebuild(node.nodes, children, stack);
    stack.removeLast();
    if (children.isNotEmpty) into.add(_Elem(name, children));
  }
}

/// 在 [stack]（已输出的祖先，栈顶是直接父元素）下放 [name]，重新解析后结构是否不变。
bool _canNest(String name, List<String> stack) {
  if (_kClosesP.contains(name) && stack.contains('p')) return false;
  if (name == 'li') {
    for (int i = stack.length - 1; i >= 0; i -= 1) {
      final String a = stack[i];
      if (a == 'li') return false;
      if (a == 'ul' || a == 'ol') break;
    }
  }
  if ((name == 'rt' || name == 'rp') &&
      stack.isNotEmpty &&
      stack.contains('ruby') &&
      _kRubyImpliedEnd.contains(stack.last)) {
    return false;
  }
  return true;
}

class _Writer {
  _Writer(this.remaining);

  final StringBuffer out = StringBuffer();
  int remaining;
  bool stopped = false;

  void writeAll(List<_Node> nodes) => _nodes(nodes, out);

  void _nodes(List<_Node> nodes, StringBuffer sink) {
    for (final _Node node in nodes) {
      if (stopped) return;
      switch (node) {
        case _Text(:final String data):
          _text(data, sink);
        case _Elem(name: 'br'):
          if (remaining < 4) {
            stopped = true;
            return;
          }
          sink.write('<br>');
          remaining -= 4;
        case _Elem(:final String name, :final List<_Node> children):
          final String open = '<$name>';
          final String close = '</$name>';
          final int overhead = open.length + close.length;
          if (remaining <= overhead) {
            stopped = true;
            return;
          }
          remaining -= overhead;
          final StringBuffer inner = StringBuffer();
          _nodes(children, inner);
          if (inner.isEmpty) {
            remaining += overhead; // 内容一个字都没放下：整个元素不输出
          } else {
            sink
              ..write(open)
              ..write(inner)
              ..write(close);
          }
      }
    }
  }

  void _text(String data, StringBuffer sink) {
    for (final int rune in data.runes) {
      final String piece = switch (rune) {
        0x26 => '&amp;',
        0x3C => '&lt;',
        0x3E => '&gt;',
        _ => String.fromCharCode(rune),
      };
      if (piece.length > remaining) {
        stopped = true;
        return;
      }
      sink.write(piece);
      remaining -= piece.length;
    }
  }
}
