/// 说话人标注的纯逻辑：分块、两遍的提示词、回复解析、角色表操作。不碰网络 /
/// AppModel，可单测。
///
/// 两遍（参照 prakharsr/audiobook-creator 的做法）：
/// 1. **角色表**：逐章读正文，让模型回「新增 / 更新 / 合并」角色的操作（规范名、
///    别名、性别、年龄、一句人设），并入 [TtsCast.roster]。名字只在这一遍产生。
/// 2. **逐句归属**：每块句子从 1 编号，给出角色表（规范名 + 别名）与上一块已归属
///    的最近几句台词（滚动上下文，保持对话轮次连贯）；模型只能从角色表里选人或回
///    `unknown`。回了别名映射到规范名，角色表外的名字一律 [kTtsUnknown]——第二遍
///    不许造名字。没回的行是旁白；但台词行（引号开头或引号未闭合的续行）没回记
///    [kTtsUnknown] + 零把握，留给人复核，而不是悄悄算成旁白。
library;

import 'dart:convert';

import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// 第二遍一块的句数上限。
const int kTtsCastChunkMaxSentences = 100;

/// 第二遍一块的字数上限（显示文本 UTF-16 长度合计）。
const int kTtsCastChunkMaxChars = 6000;

/// 第一遍（角色表）一块的字数上限：不编号、回复短，块可以大一倍。
const int kTtsRosterChunkMaxChars = 12000;

/// 块前 / 块后各带几句参考上下文。
const int kTtsCastContextSentences = 4;

/// 滚动上下文：带上一块最后几句已归属的台词。
const int kTtsCastRecentDialogue = 6;

/// 角色表最多带多少人进提示词（调用方按台词数降序排好）。
const int kTtsCastMaxRosterInPrompt = 150;

/// 情绪提示的长度上限；超长的多半是模型把整句解释塞进来了，丢弃。
const int _kMaxEmotionLength = 24;

/// 人设描述的长度上限。
const int _kMaxDescriptionLength = 120;

/// 第一遍一块回复的操作数上限：一块正文里登场的说话人不可能更多，超了就是模型在
/// 循环复读。
const int _kMaxRosterOpsPerChunk = 80;

/// 引号未闭合时，最多把后面几句当作同一段台词的续行（防止漏掉的闭引号把整章都
/// 染成台词）。
const int _kMaxDialogueContinuation = 8;

// ---------------------------------------------------------------------------
// 分块
// ---------------------------------------------------------------------------

class TtsCastChunk {
  TtsCastChunk({
    required this.sentences,
    required this.before,
    required this.after,
    List<bool>? dialogue,
  }) : dialogue =
           dialogue ??
           <bool>[
             for (final TtsPlanSentence s in sentences)
               ttsCastLooksLikeDialogue(s.text),
           ];

  /// 要标注的句子，提示词里编号为 1..n。
  final List<TtsPlanSentence> sentences;

  /// 只作参考的前文 / 后文（不编号，不标注）。
  final List<TtsPlanSentence> before;
  final List<TtsPlanSentence> after;

  /// 与 [sentences] 等长：这一句是不是台词（引号开头，或上一句引号未闭合的续行）。
  final List<bool> dialogue;

  bool get hasDialogue => dialogue.contains(true);
}

const Set<String> _kOpenQuotes = <String>{'「', '『', '“', '"', '＂', '«', '‘'};
const Map<String, String> _kQuotePairs = <String, String>{
  '「': '」',
  '『': '』',
  '“': '”',
  '«': '»',
};

/// 句子是否以引号开头。句中引号多是强调 / 书名，不算。
bool ttsCastLooksLikeDialogue(String text) {
  final String trimmed = text.trimLeft().replaceFirst(RegExp(r'^\u3000+'), '');
  return trimmed.isNotEmpty && _kOpenQuotes.contains(trimmed[0]);
}

/// 整章逐句的台词标记：引号开头的句子是台词；计划按长度切开的长台词，后面几段
/// 不以引号开头，但开引号还没闭上，也算台词。
List<bool> ttsCastDialogueFlags(List<TtsPlanSentence> sentences) {
  final List<bool> flags = <bool>[];
  final List<String> open = <String>[];
  int continuation = 0;
  for (final TtsPlanSentence s in sentences) {
    final bool starts = ttsCastLooksLikeDialogue(s.text);
    if (starts) {
      open.clear();
      continuation = 0;
    } else if (open.isNotEmpty) {
      continuation++;
      if (continuation > _kMaxDialogueContinuation) open.clear();
    }
    flags.add(starts || open.isNotEmpty);
    for (final String ch in s.text.split('')) {
      if (_kQuotePairs.containsKey(ch)) {
        open.add(_kQuotePairs[ch]!);
      } else if (open.isNotEmpty && open.last == ch) {
        open.removeLast();
      }
    }
    if (open.isEmpty) continuation = 0;
  }
  return flags;
}

/// 把一章的句子（计划顺序）切块。
List<TtsCastChunk> chunkTtsCastSection(
  List<TtsPlanSentence> sentences, {
  int maxSentences = kTtsCastChunkMaxSentences,
  int maxChars = kTtsCastChunkMaxChars,
  int contextSentences = kTtsCastContextSentences,
}) {
  final List<bool> flags = ttsCastDialogueFlags(sentences);
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
        dialogue: flags.sublist(start, end),
      ),
    );
    start = end;
  }
  return chunks;
}

/// 第一遍的分块：大块、无上下文。
List<TtsCastChunk> chunkTtsRosterSection(List<TtsPlanSentence> sentences) =>
    chunkTtsCastSection(
      sentences,
      maxSentences: sentences.length,
      maxChars: kTtsRosterChunkMaxChars,
      contextSentences: 0,
    );

// ---------------------------------------------------------------------------
// 说话人名解析
// ---------------------------------------------------------------------------

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

const Set<String> _kUnknownAliases = <String>{
  kTtsUnknown,
  'unknown',
  '不明',
  '未知',
  '?',
  '？',
  '???',
};

String _normName(String name) => name.trim().toLowerCase();

bool _isReservedName(String name) {
  final String n = _normName(name);
  return _kNarratorAliases.contains(n) || _kUnknownAliases.contains(n);
}

/// 名字 → 规范名的索引（规范名优先于别名；别名撞名时先登记的赢）。
class TtsCastSpeakerIndex {
  TtsCastSpeakerIndex(Iterable<TtsCastCharacter> roster) {
    final List<TtsCastCharacter> list = roster.toList();
    for (final TtsCastCharacter c in list) {
      _byName.putIfAbsent(_normName(c.name), () => c.name);
    }
    for (final TtsCastCharacter c in list) {
      for (final String alias in c.aliases) {
        _byName.putIfAbsent(_normName(alias), () => c.name);
      }
    }
  }

  final Map<String, String> _byName = <String, String>{};

  /// 角色表里的规范名；认不出返回 null。
  String? canonicalOf(String name) => _byName[_normName(name)];

  /// 第二遍的说话人：规范名 / 别名 → 规范名；旁白别名 → [kTtsNarrator]；
  /// `unknown` 与角色表外的名字 → [kTtsUnknown]。
  String resolve(String raw) {
    final String n = _normName(raw);
    if (_kNarratorAliases.contains(n)) return kTtsNarrator;
    if (_kUnknownAliases.contains(n)) return kTtsUnknown;
    return _byName[n] ?? kTtsUnknown;
  }
}

// ---------------------------------------------------------------------------
// 第一遍：角色表
// ---------------------------------------------------------------------------

const String kTtsRosterSystemPrompt = '''
You build the cast list of a novel so an audiobook can give each character a different voice.

You get the current cast list and a passage of one chapter. Return ONLY a JSON array of operations that bring the cast list up to date for this passage — no prose, no code fence:
[{"op":"add","name":"エミリア","aliases":["エミリアたん","銀髪の少女"],"gender":"female","age":"teen","desc":"gentle half-elf, polite speech"},
 {"op":"update","name":"スバル","aliases":["菜月昴","スバルくん"]},
 {"op":"merge","name":"昴","into":"スバル"}]
- "add": a character who speaks (or clearly will speak) and is not in the list yet.
- "update": add aliases or fill in gender / age / desc of someone already in the list.
- "merge": "name" turned out to be the same person as "into" (an existing canonical name); the two entries become one.
- "gender": "female" | "male" | "unknown". "age": "child" | "teen" | "adult" | "elderly" | "unknown". "desc": one short phrase about persona and way of speaking, in the book's language.

Rules:
- Only characters who have spoken lines matter. Ignore people who are merely mentioned.
- Write names exactly as the book writes them, in the book's original script. Never translate or romanize.
- One canonical name per character: the name the book uses most for them (usually the given name or how the narration refers to them). Other forms — full name, nicknames, titles, name + honorific, descriptions the narration uses for them — go into "aliases".
- If a speaker is never named, add them under a short descriptive label from the text (e.g. 店主, 少女, 男の声) so their lines can be attributed later; when their name is revealed, merge the label into the name.
- Do not repeat what the list already says. If nothing changes, return [].
''';

/// 角色表提示词里的一行。
String _rosterLine(TtsCastCharacter c, {required bool withDescription}) {
  final List<String> parts = <String>[c.name];
  if (c.aliases.isNotEmpty) parts.add('aliases: ${c.aliases.join('、')}');
  if (c.gender != null) parts.add(c.gender!);
  if (c.age != null) parts.add(c.age!);
  if (withDescription && c.description != null) parts.add(c.description!);
  return '- ${parts.join(' | ')}';
}

/// 第一遍一块的用户消息。[roster] 由调用方按台词数降序排好。
String buildTtsRosterUserPrompt(
  TtsCastChunk chunk, {
  required List<TtsCastCharacter> roster,
}) {
  final StringBuffer b = StringBuffer();
  b.writeln('[current cast list]');
  if (roster.isEmpty) {
    b.writeln('(empty)');
  } else {
    for (final TtsCastCharacter c in roster.take(kTtsCastMaxRosterInPrompt)) {
      b.writeln(_rosterLine(c, withDescription: true));
    }
  }
  b.writeln();
  b.writeln('[passage]');
  for (final TtsPlanSentence s in chunk.sentences) {
    b.writeln(_oneLine(s.text));
  }
  b.writeln();
  b.write('Return the JSON array of operations.');
  return b.toString();
}

enum TtsRosterOpKind { add, update, merge }

/// 第一遍的一条操作。[kind] 为 merge 时只有 [name]（被并掉的）与 [into]。
class TtsRosterOp {
  const TtsRosterOp({
    required this.kind,
    required this.name,
    this.into,
    this.aliases = const <String>[],
    this.gender,
    this.age,
    this.description,
  });

  final TtsRosterOpKind kind;
  final String name;
  final String? into;
  final List<String> aliases;
  final String? gender;
  final String? age;
  final String? description;
}

/// 解析结果：[rawCount] = 数组元素数（含不合格的）；[looping] = 元素数离谱或
/// 大量重复，判定模型在复读。
typedef TtsRosterParseResult = ({
  List<TtsRosterOp> ops,
  int rawCount,
  bool looping,
});

const Set<String> _kGenders = <String>{'female', 'male'};
const Set<String> _kAges = <String>{'child', 'teen', 'adult', 'elderly'};

/// 解析第一遍回复。找不到可解析的 JSON 数组返回 null。
TtsRosterParseResult? parseTtsRosterReply(String reply) {
  final List<Object?>? array = _firstJsonArray(_stripFences(reply));
  if (array == null) return null;
  final List<TtsRosterOp> ops = <TtsRosterOp>[];
  for (final Object? entry in array) {
    if (entry is! Map) continue;
    final String? name = _cleanName(entry['name']);
    if (name == null) continue;
    final TtsRosterOpKind? kind = switch (entry['op']) {
      'add' => TtsRosterOpKind.add,
      'update' => TtsRosterOpKind.update,
      'merge' => TtsRosterOpKind.merge,
      _ => null,
    };
    if (kind == null) continue;
    if (kind == TtsRosterOpKind.merge) {
      final String? into = _cleanName(entry['into']);
      if (into == null || _normName(into) == _normName(name)) continue;
      ops.add(TtsRosterOp(kind: kind, name: name, into: into));
      continue;
    }
    final Object? rawAliases = entry['aliases'];
    final Set<String> seen = <String>{_normName(name)};
    ops.add(
      TtsRosterOp(
        kind: kind,
        name: name,
        aliases: <String>[
          if (rawAliases is List)
            for (final Object? a in rawAliases)
              if (_cleanName(a) case final String alias)
                if (seen.add(_normName(alias))) alias,
        ],
        gender: _pick(entry['gender'], _kGenders),
        age: _pick(entry['age'], _kAges),
        description: _cleanText(entry['desc'], _kMaxDescriptionLength),
      ),
    );
  }
  return (
    ops: ops,
    rawCount: array.length,
    looping: _looksLooping(array, _kMaxRosterOpsPerChunk),
  );
}

/// 把第一遍的操作依次并进 [cast]：
/// - add / update 同一口径：名字（或它的别名）已在表里就补别名 / 空特征（不覆盖
///   已有值——那可能是用户改的），否则新增；
/// - 别名若是另一个人的名字或别名就丢掉（那是 merge 的事，不能悄悄把两人并了）；
/// - merge 走 [TtsCast.renameSpeaker]：台词、声音、角色表一起并，旧名成为别名。
///   `into` 不在表里的 merge 忽略。
void applyTtsRosterOps(TtsCast cast, List<TtsRosterOp> ops) {
  for (final TtsRosterOp op in ops) {
    final TtsCastSpeakerIndex index = TtsCastSpeakerIndex(cast.roster.values);
    if (op.kind == TtsRosterOpKind.merge) {
      final String? into = index.canonicalOf(op.into!);
      if (into == null) continue;
      final String? from = index.canonicalOf(op.name);
      if (from == into) continue;
      if (from != null) {
        cast.renameSpeaker(from, into);
      } else {
        // 表里没有这个名字（可能只在旧台词里出现过）：台词照并，名字记成别名。
        cast.renameSpeaker(op.name, into);
        cast.mergeRoster(<TtsCastCharacter>[
          TtsCastCharacter(name: into, aliases: <String>[op.name]),
        ]);
      }
      continue;
    }
    final String name = index.canonicalOf(op.name) ?? op.name;
    final List<String> aliases = <String>[
      if (name != op.name) op.name,
      for (final String a in op.aliases)
        if (_normName(a) != _normName(name) &&
            (index.canonicalOf(a) == null || index.canonicalOf(a) == name))
          a,
    ];
    cast.mergeRoster(<TtsCastCharacter>[
      TtsCastCharacter(
        name: name,
        aliases: aliases,
        gender: op.gender,
        age: op.age,
        description: op.description,
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// 第二遍：逐句归属
// ---------------------------------------------------------------------------

const String kTtsCastLinesSystemPrompt = '''
You attribute dialogue in a novel to speakers so an audiobook can give each character a different voice.

You get the cast list, the last few lines already attributed (for turn-taking), and numbered lines from one chapter (lines marked "context" only help you infer speakers; never label them). Return ONLY a JSON array, no prose, no code fence:
[{"i":3,"s":"エミリア","e":"怒り","c":0.95,"ev":"explicit"},{"i":5,"s":"スバル","c":0.6,"ev":"implicit"},{"i":8,"s":"unknown","c":0.2,"ev":"implicit"}]
- "i": the line number.
- "s": who speaks the line: EXACTLY one canonical name from the cast list, or "unknown" when it is dialogue but you cannot tell who says it. Never use a name that is not in the cast list; never use an alias.
- "e": optional short emotion / tone hint in the book's language (e.g. 怒り, 囁き, 笑い); omit when neutral.
- "c": your confidence from 0 to 1.
- "ev": "explicit" (an attribution like 「…」とスバルは言った names the speaker), "anaphoric" (a pronoun, title or description refers to them, e.g. と彼女は言った, 少女が呟いた), or "implicit" (no tag; inferred from turn-taking, address terms, speech style).

Rules:
- Include ONLY lines that are spoken (or clearly voiced aloud) by a character: dialogue, usually inside 「」 or 『』 (or “” / "" in Western text). Narration, descriptions, inner monologue written as narration and titles are the narrator: do NOT include them.
- A long utterance may be split across several consecutive lines; label every line of it with the same speaker.
- Use the attribution tags, turn-taking (in a two-person exchange speakers usually alternate), how characters address each other, their speech style and gender, and the surrounding narration (including context lines and the already-attributed lines).
- Prefer "unknown" with a low "c" over guessing.
''';

/// 滚动上下文里的一句已归属台词。
typedef TtsCastRecentLine = ({String speaker, String text});

/// 第二遍一块的用户消息。[roster] 由调用方按台词数降序排好；[recent] = 上一块
/// 最后几句已归属的台词（本章第一块为空）。
String buildTtsCastLinesUserPrompt(
  TtsCastChunk chunk, {
  required List<TtsCastCharacter> roster,
  required List<TtsCastRecentLine> recent,
}) {
  final StringBuffer b = StringBuffer();
  b.writeln('[cast list]');
  if (roster.isEmpty) {
    b.writeln('(empty: use "unknown" for every dialogue line)');
  } else {
    for (final TtsCastCharacter c in roster.take(kTtsCastMaxRosterInPrompt)) {
      b.writeln(_rosterLine(c, withDescription: false));
    }
  }
  b.writeln();
  if (recent.isNotEmpty) {
    b.writeln('[already attributed, just before]');
    for (final TtsCastRecentLine r in recent) {
      final String who = r.speaker == kTtsUnknown ? 'unknown' : r.speaker;
      b.writeln('$who: ${_oneLine(r.text)}');
    }
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

/// 模型给的一行归属；[index] 是块内编号（1 起），[speaker] 已解析成规范名 /
/// [kTtsUnknown] / [kTtsNarrator]。
class TtsCastLabel {
  const TtsCastLabel({
    required this.index,
    required this.speaker,
    this.emotion,
    this.confidence,
    this.evidence,
  });

  final int index;
  final String speaker;
  final String? emotion;
  final double? confidence;
  final TtsCastEvidence? evidence;
}

/// 解析结果：[rawCount] = 数组元素数（含不合格的），用来区分「模型说没有台词」与
/// 「模型回了一堆认不出的东西」；[looping] 见 [parseTtsRosterReply]。
typedef TtsCastParseResult = ({
  List<TtsCastLabel> labels,
  int rawCount,
  bool looping,
});

/// 解析第二遍回复。找不到可解析的 JSON 数组返回 null。编号越界 / 重复（取第一个）
/// / 缺说话人的元素丢弃；说话人按 [speakers] 解析（别名 → 规范名，表外 → 不明）。
TtsCastParseResult? parseTtsCastReply(
  String reply,
  int lineCount, {
  required TtsCastSpeakerIndex speakers,
}) {
  final List<Object?>? array = _firstJsonArray(_stripFences(reply));
  if (array == null) return null;
  final Map<int, TtsCastLabel> byIndex = <int, TtsCastLabel>{};
  for (final Object? entry in array) {
    if (entry is! Map) continue;
    final int? index = _asIndex(entry['i']);
    if (index == null || index < 1 || index > lineCount) continue;
    if (byIndex.containsKey(index)) continue;
    final String? raw = _cleanName(entry['s'], allowReserved: true);
    if (raw == null) continue;
    final String speaker = speakers.resolve(raw);
    final bool narrator = speaker == kTtsNarrator;
    byIndex[index] = TtsCastLabel(
      index: index,
      speaker: speaker,
      emotion: narrator ? null : _cleanText(entry['e'], _kMaxEmotionLength),
      confidence: narrator ? null : _asConfidence(entry['c']),
      evidence: narrator
          ? null
          : switch (entry['ev']) {
              'explicit' => TtsCastEvidence.explicit,
              'anaphoric' => TtsCastEvidence.anaphoric,
              'implicit' => TtsCastEvidence.implicit,
              _ => null,
            },
    );
  }
  final List<TtsCastLabel> labels = byIndex.values.toList()
    ..sort((TtsCastLabel a, TtsCastLabel b) => a.index.compareTo(b.index));
  return (
    labels: labels,
    rawCount: array.length,
    looping: _looksLooping(array, lineCount * 2 + 10),
  );
}

/// 一块的整套行标注：模型回了的行按回复；没回的台词行记 [kTtsUnknown] + 零把握
/// （进复核），其余没回的行记旁白。全部是 llm 来源，重新标注时口径一致。
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
          confidence: l.confidence,
          evidence: l.evidence,
        ),
        null when chunk.dialogue[i] => const TtsCastLine(
          speaker: kTtsUnknown,
          source: TtsCastSource.llm,
          confidence: 0,
        ),
        null => const TtsCastLine(
          speaker: kTtsNarrator,
          source: TtsCastSource.llm,
        ),
      },
  };
}

/// 一块标完后的滚动上下文：这块最后 [kTtsCastRecentDialogue] 句非旁白行。
List<TtsCastRecentLine> ttsCastRecentDialogue(
  TtsCastChunk chunk,
  Map<String, TtsCastLine> lines,
) {
  final List<TtsCastRecentLine> out = <TtsCastRecentLine>[];
  for (int i = chunk.sentences.length - 1; i >= 0; i--) {
    final TtsPlanSentence s = chunk.sentences[i];
    final TtsCastLine? line = lines[ttsLineKey(s.section, s.matchStart)];
    if (line == null || line.speaker == kTtsNarrator) continue;
    out.add((speaker: line.speaker, text: s.text));
    if (out.length == kTtsCastRecentDialogue) break;
  }
  return out.reversed.toList();
}

// ---------------------------------------------------------------------------
// 共用
// ---------------------------------------------------------------------------

String _oneLine(String text) => text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

String? _cleanName(Object? raw, {bool allowReserved = false}) {
  if (raw is! String) return null;
  final String name = raw.trim();
  if (name.isEmpty || name.length > 40) return null;
  if (!allowReserved && _isReservedName(name)) return null;
  return name;
}

String? _cleanText(Object? raw, int maxLength) {
  if (raw is! String) return null;
  final String text = raw.trim();
  return text.isEmpty || text.length > maxLength ? null : text;
}

String? _pick(Object? raw, Set<String> allowed) {
  if (raw is! String) return null;
  final String v = raw.trim().toLowerCase();
  return allowed.contains(v) ? v : null;
}

int? _asIndex(Object? raw) => switch (raw) {
  final int v => v,
  final double v when v == v.roundToDouble() => v.toInt(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};

double? _asConfidence(Object? raw) {
  final double? v = switch (raw) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s.trim()),
    _ => null,
  };
  if (v == null || v.isNaN) return null;
  return v.clamp(0.0, 1.0);
}

/// 复读判定：元素数超过 [maxEntries]，或二十个以上元素里一半以上是逐字重复。
bool _looksLooping(List<Object?> array, int maxEntries) {
  if (array.length > maxEntries) return true;
  if (array.length < 20) return false;
  final Set<String> distinct = <String>{
    for (final Object? e in array) jsonEncode(e),
  };
  return distinct.length * 2 < array.length;
}

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
