/// 笔记编辑页的「AI 改写 / 补全」：对**一个字段**按预设任务（写释义、翻译例句、改写）或用户
/// 一句话，参考同一条笔记的其它字段，产出这个字段的新内容。
///
/// 边界（与其它助手一致）：
/// - 只在用户点了按钮、选了任务之后发一次请求；没有指派提供商时一个请求都不发（BUG-2694）。
/// - 产物只进编辑页草稿：先在抽屉里预览，用户点「替换 / 追加」才写进字段，点保存才落库。
/// - 本地校验：回复必须是 `{"value": "..."}`；值经 [aiSrsSanitizeFieldHtml] 收窄到行内排版
///   白名单（去掉所有属性、脚本 / 样式整段丢弃），截断到 [kAiSrsFieldMax]；空值 = 失败。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart'
    show AiSrsFieldBrief, aiSrsPlainText;

/// 字段新内容的长度上限（字符，清洗后）。
const int kAiSrsFieldMax = 2000;

/// 预设任务（各自的内置任务模板见 `ai_srs_field_actions.dart`）。
enum AiSrsFieldTask {
  /// 给词条写释义。
  define,

  /// 把例句翻译成目标语言。
  translate,

  /// 按笔记其它字段补全 / 改写这个字段（更清楚、更简洁）。
  rewrite,

  /// 只按用户的一句话。
  custom,
}

/// AI 给出的字段新内容。
class AiSrsFieldSuggestion {
  const AiSrsFieldSuggestion({required this.value, this.explanation = ''});

  /// 清洗后的 HTML（行内白名单）。
  final String value;

  /// 一句话说明，显示给用户。
  final String explanation;
}

/// 模型回复里认不出内容（JSON 不合法、value 为空）。
class AiSrsFieldEmpty implements Exception {
  const AiSrsFieldEmpty();
}

const Set<String> _kAllowedTags = <String>{
  'b',
  'strong',
  'i',
  'em',
  'u',
  'br',
  'div',
  'p',
  'ul',
  'ol',
  'li',
  'ruby',
  'rt',
  'rp',
  'mark',
  'span',
};

final RegExp _dropBlocks = RegExp(
  r'<(script|style|iframe|object|embed|template)\b[\s\S]*?</\1\s*>',
  caseSensitive: false,
);
final RegExp _comment = RegExp(r'<!--[\s\S]*?-->');
final RegExp _tag = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>');

/// 把 AI 产出的 HTML 收窄到行内排版白名单：白名单标签去掉全部属性（`on*`、`style`、`href`
/// 一概不留），其余标签去掉、保留里面的文字；脚本 / 样式等整段丢弃；注释丢弃；`<`、`>`
/// 残片转义。结果截断到 [kAiSrsFieldMax]。
String aiSrsSanitizeFieldHtml(String raw) {
  String s = raw.replaceAll(_dropBlocks, '').replaceAll(_comment, '');
  final StringBuffer out = StringBuffer();
  int last = 0;
  String text(String t) => t.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  for (final RegExpMatch m in _tag.allMatches(s)) {
    out.write(text(s.substring(last, m.start)));
    last = m.end;
    final String name = m.group(2)!.toLowerCase();
    if (!_kAllowedTags.contains(name)) continue;
    final bool closing = m.group(1)!.isNotEmpty;
    if (name == 'br') {
      if (!closing) out.write('<br>');
      continue;
    }
    out.write(closing ? '</$name>' : '<$name>');
  }
  out.write(text(s.substring(last)));
  s = out.toString().trim();
  return s.length <= kAiSrsFieldMax ? s : s.substring(0, kAiSrsFieldMax);
}

/// 每个字段交给 AI 的内容上限（字符，整理后）。
const int kAiSrsFieldSampleMax = 300;

final RegExp _rubyReading = RegExp(
  r'<(rt|rp)\b[^>]*>[\s\S]*?</\1\s*>',
  caseSensitive: false,
);
final RegExp _clozeMark = RegExp(r'\{\{c\d+::([\s\S]*?)(?:::[\s\S]*?)?\}\}');
final RegExp _lineBreakTag = RegExp(
  r'<br\s*/?>|</(p|div|li)\s*>',
  caseSensitive: false,
);
final RegExp _boldTag = RegExp(
  r'<(/?)(b|strong)\b[^>]*>',
  caseSensitive: false,
);
// 除了已规整成 `<b>` / `</b>` 的加粗，其余标签一律去掉。
final RegExp _nonBoldTag = RegExp(r'<(?!/?b>)/?[a-zA-Z][^>]*>');
final RegExp _partialTail = RegExp(r'<[^>]*$');

/// 把字段的 HTML 整理成交给 AI 的内容：只留 `<b>`（字段里标出的目标词，挖空
/// `{{c1::词}}` 也记成 `<b>词</b>`）与换行，其余标签**原地去掉、不补空格**。
///
/// 以前统一走 `aiSrsPlainText`：每个标签换成一个空格。那样 `それに<b>気づいた</b>時` 变成
/// `それに 気づいた 時`——目标词标记没了（翻译任务要求把它的译文加粗，模型只能猜），日文里
/// 还平白多出空格；振假名 `<rt>` 的读音也混进正文（`漢字かんじ`）。振假名读音整段丢掉。
String aiSrsFieldSample(String raw, {int max = kAiSrsFieldSampleMax}) {
  String s = raw
      .replaceAll(_dropBlocks, '')
      .replaceAll(_comment, '')
      .replaceAll(_rubyReading, '')
      .replaceAllMapped(_clozeMark, (Match m) => '<b>${m.group(1)}</b>')
      .replaceAll(_lineBreakTag, '\n')
      .replaceAllMapped(_boldTag, (Match m) => '<${m.group(1)}b>')
      .replaceAll(_nonBoldTag, '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ')
      .replaceAll(RegExp(r' *\n\s*'), '\n')
      .trim();
  if (s.length > max) {
    s = s.substring(0, max).replaceFirst(_partialTail, '');
    if ('<b>'.allMatches(s).length > '</b>'.allMatches(s).length) {
      s = '$s</b>';
    }
  }
  return s;
}

/// 系统提示里**用户可改**的部分（角色、字段内容、语言规则）：内置的「总体说明」模板正文
/// （`ai_srs_field_actions.dart`），用户的覆盖代替它。
const String kAiSrsFieldGuidance = '''
You help a language learner edit ONE field of a flashcard note (Anki-compatible).
You get the note type, every field with its meaning and current content, the
field to write, and a task. Write only that field's new content.

Field contents are plain text with line breaks. <b>…</b> in them marks the
target word of the note.

Languages: definitions, translations and explanations are written in the
output language given in the request. New example sentences, and any text that
belongs to the language being learned, are written in the language of the
note's sentence and headword, unless the user instruction says otherwise.

Ground your answer in the note: prefer what its dictionary fields (definition,
glossary) say over your own knowledge, and never invent senses, readings or
facts that the note does not support.''';

/// 系统提示里**锁定**的契约（排版白名单、回复 JSON、说明的语言）：不论总体说明怎么改，
/// 代码都把它接在后面——回复的本地校验（[parseAiSrsFieldSuggestion]）依赖它。
const String kAiSrsFieldContract = '''
Formatting: plain text or simple inline HTML only: <b>, <i>, <u>, <br>, <ul>,
<ol>, <li>, <ruby>/<rt>. No attributes, no styles, no scripts, no links.

Answer with a single JSON object and nothing else:
{"value": "<new field content>", "explanation": "<one short sentence>"}
The explanation must be written in the same language as the user instruction
(or the output language if there is no instruction).
''';

/// 没有任何改动时的系统提示（= 总体说明 + 契约）。
const String kAiSrsFieldSystemPrompt =
    '$kAiSrsFieldGuidance\n\n$kAiSrsFieldContract';

/// 拼系统消息：[guidance]（已代入占位符）后面永远接上 [kAiSrsFieldContract]；
/// 说明为空就只有契约。
String aiSrsFieldSystemMessage(String guidance) {
  final String g = guidance.trimRight();
  return g.trim().isEmpty ? kAiSrsFieldContract : '$g\n\n$kAiSrsFieldContract';
}

/// 一次请求的两条消息。
class AiSrsFieldPrompt {
  const AiSrsFieldPrompt({required this.system, required this.user});

  final String system;
  final String user;
}

/// 用户侧提示。骨架固定（笔记类型、字段 JSON、要写的字段、输出语言），[taskText] 是已代入
/// 占位符的任务行（内置或用户改过的模板，见 `buildAiSrsFieldPrompt`），最后是用户一句话。
String buildAiSrsFieldUserPrompt({
  required String noteTypeName,
  required List<AiSrsFieldBrief> fields,
  required String targetFieldId,
  required String taskText,
  required String instruction,
  required String outputLanguage,
}) {
  final AiSrsFieldBrief? target = fields
      .where((AiSrsFieldBrief f) => f.id == targetFieldId)
      .firstOrNull;
  final StringBuffer b = StringBuffer()
    ..writeln('Note type: $noteTypeName')
    ..writeln(
      'Fields: ${jsonEncode(<Map<String, Object?>>[for (final AiSrsFieldBrief f in fields) f.toJson()])}',
    )
    ..writeln('Field to write: ${target?.name ?? targetFieldId}')
    ..writeln('Output language: $outputLanguage')
    ..writeln(taskText);
  if (instruction.trim().isNotEmpty) {
    b.writeln('User instruction: ${instruction.trim()}');
  }
  return b.toString();
}

/// 解析回复；认不出内容抛 [AiSrsFieldEmpty]。
AiSrsFieldSuggestion parseAiSrsFieldSuggestion(String reply) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? value = json?['value'];
  if (value is! String) throw const AiSrsFieldEmpty();
  final String clean = aiSrsSanitizeFieldHtml(value);
  if (clean.replaceAll(RegExp(r'<[^>]*>'), '').trim().isEmpty) {
    throw const AiSrsFieldEmpty();
  }
  final Object? explanation = json?['explanation'];
  return AiSrsFieldSuggestion(
    value: clean,
    explanation: explanation is String ? aiSrsPlainText(explanation, 300) : '',
  );
}

/// 跑一次（消息由 `buildAiSrsFieldPrompt` 拼好）。失败原样抛 [AiChatFailure]（文案已脱敏）或
/// [AiSrsFieldEmpty]，由 UI 转成提示。
Future<AiSrsFieldSuggestion> requestAiSrsField({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiSrsFieldPrompt prompt,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(prompt.system),
      AiChatMessage.user(prompt.user),
    ],
  );
  return parseAiSrsFieldSuggestion(reply);
}
