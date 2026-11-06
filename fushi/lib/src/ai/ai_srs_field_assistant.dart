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
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/ai/ai_srs_template_assistant.dart'
    show AiSrsFieldBrief, aiSrsPlainText;

/// 字段新内容的长度上限（字符，清洗后）。
const int kAiSrsFieldMax = 2000;

/// 预设任务。
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

String _taskLine(AiSrsFieldTask task, String outputLanguage) => switch (task) {
  AiSrsFieldTask.define =>
    'Task: write a concise definition of the headword for this field, in '
        '$outputLanguage. Number senses if there are several.',
  AiSrsFieldTask.translate =>
    'Task: translate the example sentence into $outputLanguage. Keep the '
        'target word recognisable (wrap its translation in <b>).',
  AiSrsFieldTask.rewrite =>
    'Task: fill in or improve this field using the other fields of the note: '
        'keep the meaning, make it clearer and shorter.',
  AiSrsFieldTask.custom => 'Task: follow the user instruction below.',
};

/// 系统提示。
const String kAiSrsFieldSystemPrompt = '''
You help a language learner edit ONE field of a flashcard note (Anki-compatible).
You get the note type, every field with its meaning and current content, the
field to write, and a task. Write only that field's new content.

Formatting: plain text or simple inline HTML only: <b>, <i>, <u>, <br>, <ul>,
<ol>, <li>, <ruby>/<rt>. No attributes, no styles, no scripts, no links.

Answer with a single JSON object and nothing else:
{"value": "<new field content>", "explanation": "<one short sentence>"}
The explanation must be written in the same language as the user instruction
(or the output language if there is no instruction).
''';

/// 用户侧提示。
String buildAiSrsFieldUserPrompt({
  required String noteTypeName,
  required List<AiSrsFieldBrief> fields,
  required String targetFieldId,
  required AiSrsFieldTask task,
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
    ..writeln(_taskLine(task, outputLanguage));
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

/// 跑一次。失败原样抛 [AiChatFailure]（文案已脱敏）或 [AiSrsFieldEmpty]，由 UI 转成提示。
Future<AiSrsFieldSuggestion> requestAiSrsField({
  required AiChatClient client,
  required AiProviderConfig provider,
  required SrsNoteTypeView noteType,
  required Map<String, String> valuesById,
  required String targetFieldId,
  required AiSrsFieldTask task,
  String instruction = '',
  required String outputLanguage,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      const AiChatMessage.system(kAiSrsFieldSystemPrompt),
      AiChatMessage.user(
        buildAiSrsFieldUserPrompt(
          noteTypeName: noteType.name,
          fields: <AiSrsFieldBrief>[
            for (final SrsFieldDef f in noteType.fields)
              AiSrsFieldBrief.of(
                f,
                sample: aiSrsPlainText(valuesById[f.id] ?? '', 300),
              ),
          ],
          targetFieldId: targetFieldId,
          task: task,
          instruction: instruction,
          outputLanguage: outputLanguage,
        ),
      ),
    ],
  );
  return parseAiSrsFieldSuggestion(reply);
}
