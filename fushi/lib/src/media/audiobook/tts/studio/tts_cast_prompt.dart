/// 说话人标注的纯逻辑：分块、提示词、回复解析。不碰网络 / AppModel，可单测。
///
/// 一章切成若干块，每块句子从 1 编号；块前后各带几句只作参考的上下文（「…」と
/// スバルは言った 这类归属常落在下一块开头）。模型只回台词行，没回的一律旁白。
library;

import 'dart:convert';

import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// 一块的句数上限。
const int kTtsCastChunkMaxSentences = 100;

/// 一块的字数上限（显示文本 UTF-16 长度合计）。
const int kTtsCastChunkMaxChars = 6000;

/// 块前 / 块后各带几句参考上下文。
const int kTtsCastContextSentences = 4;

/// 已知角色名最多带多少个进提示词（按台词数降序截断）。
const int kTtsCastMaxKnownSpeakers = 150;

/// 情绪提示的长度上限；超长的多半是模型把整句解释塞进来了，丢弃。
const int _kMaxEmotionLength = 24;

class TtsCastChunk {
  const TtsCastChunk({
    required this.sentences,
    required this.before,
    required this.after,
  });

  /// 要标注的句子，提示词里编号为 1..n。
  final List<TtsPlanSentence> sentences;

  /// 只作参考的前文 / 后文（不编号，不标注）。
  final List<TtsPlanSentence> before;
  final List<TtsPlanSentence> after;

  /// 有没有以引号开头的句子（台词）。句中引号多是强调 / 书名，不算。
  bool get hasDialogue =>
      sentences.any((TtsPlanSentence s) => ttsCastLooksLikeDialogue(s.text));
}

const Set<String> _kOpenQuotes = <String>{'「', '『', '“', '"', '＂', '«', '‘'};

bool ttsCastLooksLikeDialogue(String text) {
  final String trimmed = text.trimLeft().replaceFirst(
    RegExp(r'^[\u3000]+'),
    '',
  );
  return trimmed.isNotEmpty && _kOpenQuotes.contains(trimmed[0]);
}

/// 把一章的句子（计划顺序）切块。
List<TtsCastChunk> chunkTtsCastSection(
  List<TtsPlanSentence> sentences, {
  int maxSentences = kTtsCastChunkMaxSentences,
  int maxChars = kTtsCastChunkMaxChars,
  int contextSentences = kTtsCastContextSentences,
}) {
  final List<TtsCastChunk> chunks = <TtsCastChunk>[];
  int start = 0;
  while (start < sentences.length) {
    int end = start;
    int chars = 0;
    while (end < sentences.length && end - start < maxSentences) {
      final int len = sentences[end].text.length;
      if (end > start && chars + len > maxChars) break;
      chars += len;
      end++;
    }
    chunks.add(
      TtsCastChunk(
        sentences: sentences.sublist(start, end),
        before: sentences.sublist(
          (start - contextSentences).clamp(0, start),
          start,
        ),
        after: sentences.sublist(
          end,
          (end + contextSentences).clamp(end, sentences.length),
        ),
      ),
    );
    start = end;
  }
  return chunks;
}

const String kTtsCastSystemPrompt = '''
You label speakers in a novel so an audiobook can give each character a different voice.

You get numbered lines from one chapter (lines marked "context" are only there to help you infer speakers; never label them). Return ONLY a JSON array, no prose, no code fence:
[{"i":3,"s":"エミリア","e":"怒り"},{"i":7,"s":"スバル"}]
- "i": the line number.
- "s": the character who speaks that line.
- "e": optional short emotion / tone hint in the book's language (e.g. 怒り, 囁き, 笑い); omit when neutral.

Rules:
- Include ONLY lines that are spoken (or clearly voiced aloud) by a character: dialogue, usually inside 「」 or 『』 (or “” / "" in Western text). Everything else — narration, descriptions, inner monologue written as narration, chapter titles — is the narrator: do NOT include it.
- A long utterance may be split across several consecutive lines; label every line of it.
- Infer the speaker from context: attributions like 「…」とスバルは言った / と彼女は答えた, turn-taking in a conversation, how characters address each other, speech style, and the surrounding narration (including the context lines).
- Write names exactly as the book writes them, in the book's original script. Never translate or romanize.
- Use ONE canonical name per character (prefer the name the book uses most, usually the given name or how the narration refers to them). If a character matches a name in the known-characters list, reuse that exact spelling.
- If a speaker cannot be identified by name, use a short descriptive label from the text (e.g. 少女, 店主, 男の声). If you truly cannot tell who speaks, omit the line.
- If there is no dialogue at all, return [].
''';

/// 一块的用户消息。[knownSpeakers] = 选角表里已有的角色（含本章前几块新出现的），
/// 让模型沿用同一写法。
String buildTtsCastUserPrompt(
  TtsCastChunk chunk, {
  required List<String> knownSpeakers,
}) {
  final StringBuffer b = StringBuffer();
  final List<String> known = knownSpeakers
      .where((String s) => s != kTtsNarrator)
      .take(kTtsCastMaxKnownSpeakers)
      .toList();
  if (known.isNotEmpty) {
    b.writeln('Known characters (reuse these exact names): ${known.join('、')}');
    b.writeln();
  }
  if (chunk.before.isNotEmpty) {
    b.writeln('[context before]');
    for (final TtsPlanSentence s in chunk.before) {
      b.writeln('context: ${_oneLine(s.text)}');
    }
    b.writeln();
  }
  b.writeln('[lines to label]');
  for (int i = 0; i < chunk.sentences.length; i++) {
    b.writeln('${i + 1}: ${_oneLine(chunk.sentences[i].text)}');
  }
  if (chunk.after.isNotEmpty) {
    b.writeln();
    b.writeln('[context after]');
    for (final TtsPlanSentence s in chunk.after) {
      b.writeln('context: ${_oneLine(s.text)}');
    }
  }
  b.writeln();
  b.write('Return the JSON array for lines 1-${chunk.sentences.length} only.');
  return b.toString();
}

String _oneLine(String text) => text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

/// 模型给的一行标注；[index] 是块内编号（1 起）。
class TtsCastLabel {
  const TtsCastLabel({
    required this.index,
    required this.speaker,
    this.emotion,
  });

  final int index;
  final String speaker;
  final String? emotion;
}

/// 解析结果：[rawCount] = 数组里的元素数（含不合格的），用来区分「模型说没有
/// 台词」与「模型回了一堆认不出的东西」。
typedef TtsCastParseResult = ({List<TtsCastLabel> labels, int rawCount});

/// 从回复里找第一个 JSON 数组并校验。找不到可解析的数组返回 null。
/// 编号越界 / 重复（取第一个）/ 缺说话人的元素丢弃；说话人为旁白别名的不收（旁白
/// 是默认值）。
TtsCastParseResult? parseTtsCastReply(String reply, int lineCount) {
  final List<Object?>? array = _firstJsonArray(_stripFences(reply));
  if (array == null) return null;
  final Map<int, TtsCastLabel> byIndex = <int, TtsCastLabel>{};
  for (final Object? entry in array) {
    if (entry is! Map) continue;
    final int? index = _asIndex(entry['i']);
    if (index == null || index < 1 || index > lineCount) continue;
    if (byIndex.containsKey(index)) continue;
    final Object? rawSpeaker = entry['s'];
    if (rawSpeaker is! String) continue;
    final String speaker = rawSpeaker.trim();
    if (speaker.isEmpty || _isNarratorAlias(speaker)) continue;
    final Object? rawEmotion = entry['e'];
    final String? emotion = rawEmotion is String ? rawEmotion.trim() : null;
    byIndex[index] = TtsCastLabel(
      index: index,
      speaker: speaker,
      emotion:
          emotion == null ||
              emotion.isEmpty ||
              emotion.length > _kMaxEmotionLength
          ? null
          : emotion,
    );
  }
  final List<TtsCastLabel> labels = byIndex.values.toList()
    ..sort((TtsCastLabel a, TtsCastLabel b) => a.index.compareTo(b.index));
  return (labels: labels, rawCount: array.length);
}

/// 一块的整套行标注：模型回了的行归角色，其余行记成旁白（同为 llm 来源，重新标注
/// 时口径一致）。
Map<String, TtsCastLine> ttsCastLinesForChunk(
  TtsCastChunk chunk,
  List<TtsCastLabel> labels,
) {
  final Map<int, TtsCastLabel> byIndex = <int, TtsCastLabel>{
    for (final TtsCastLabel l in labels) l.index: l,
  };
  return <String, TtsCastLine>{
    for (int i = 0; i < chunk.sentences.length; i++)
      ttsLineKey(
        chunk.sentences[i].section,
        chunk.sentences[i].matchStart,
      ): switch (byIndex[i + 1]) {
        final TtsCastLabel l => TtsCastLine(
          speaker: l.speaker,
          source: TtsCastSource.llm,
          emotion: l.emotion,
        ),
        null => const TtsCastLine(
          speaker: kTtsNarrator,
          source: TtsCastSource.llm,
        ),
      },
  };
}

const Set<String> _kNarratorAliases = <String>{
  kTtsNarrator,
  'narrator',
  'narration',
  '旁白',
  'ナレーター',
  'ナレーション',
  '地の文',
  '語り手',
};

bool _isNarratorAlias(String speaker) =>
    _kNarratorAliases.contains(speaker.toLowerCase());

int? _asIndex(Object? raw) => switch (raw) {
  final int v => v,
  final double v when v == v.roundToDouble() => v.toInt(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};

String _stripFences(String reply) =>
    reply.replaceAll(RegExp(r'```[a-zA-Z]*'), '');

/// 逐个 `[` 起点做括号配对（跳过字符串字面量），第一个能解码成数组的胜出。
List<Object?>? _firstJsonArray(String text) {
  for (
    int start = text.indexOf('[');
    start >= 0;
    start = text.indexOf('[', start + 1)
  ) {
    final int? end = _matchingBracket(text, start);
    if (end == null) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      continue;
    }
    if (decoded is List) return decoded;
  }
  return null;
}

int? _matchingBracket(String text, int start) {
  int depth = 0;
  bool inString = false;
  for (int i = start; i < text.length; i++) {
    final String c = text[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    switch (c) {
      case '"':
        inString = true;
      case '[' || '{':
        depth++;
      case ']' || '}':
        depth--;
        if (depth == 0) return c == ']' ? i : null;
        if (depth < 0) return null;
    }
  }
  return null;
}
