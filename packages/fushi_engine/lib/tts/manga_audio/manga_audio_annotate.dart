/// 漫画演出稿的 AI 标注（设计 §4）：三遍的提示词、回复解析与本地校验，纯函数。
///
/// 1. **角色表**（[kMangaRosterSystemPrompt]）：封面与前几页带图，抽角色（名字 / 别名 /
///    性别 / 年龄段 / 一句人设）。提示词里先给**系列**角色表（`SeriesCastProfile.roster`）
///    再给本卷已有的，模型只补新人和空字段，名字跨卷不漂移。
/// 2. **逐页**（[kMangaPageSystemPrompt]）：页图 + 该页 OCR 块（下标、0..1000 坐标、
///    竖排、文字）+ 角色表 + 前几页已定的行；回复的行字段与 `MangaScriptLine.toJson`
///    同名，直接交 `validateMangaPageLines` 校验，不合格的行丢弃并列出。模型可以在
///    `new` 里声明角色表里没有的新角色（后面才登场的人），声明过的名字才能当说话人。
/// 3. **整场复核**（[kMangaSceneReviewSystemPrompt]）：连续几页的行一起通读，只回要改的
///    行（按行身份 `lineId`），只改 AI 标的行，用户改过的行不动。
///
/// 模型有意标成「不读」（`k: skip`）的行照样保留为「不读」，不是失败，也不进重试。
/// 调用、限频、落盘、失败记账在应用层（`ai_manga_audio_assistant.dart`）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/media/manga/manga_ruby.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_prompt_roster.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

/// 发给模型的页图长边上限（像素）。气泡里的字由 OCR 文本给，图只用来认人、看
/// 气泡形状与分格走向，1280 足够，且每页一张图的上传量可控。
const int kMangaAnnotateImageMaxSide = 1280;

/// 角色表那一遍带图的正文页数（封面另算一张）。
const int kMangaRosterImagePages = 4;

/// 逐页提示词里带的「前几页已定的行」条数。
const int kMangaPagePreviousLines = 8;

/// 整场复核一次最多几页 / 几行。
const int kMangaSceneMaxPages = 6;
const int kMangaSceneMaxLines = 60;

/// 提示词里角色表最多列几个人（按出场顺序）。
const int kMangaPromptMaxRoster = 60;

/// 「不明」「旁白」在提示词与回复里的写法（落盘仍是 [kTtsUnknown] / [kTtsNarrator]）。
const String kMangaPromptUnknown = 'UNKNOWN';
const String kMangaPromptNarrator = 'NARRATOR';

String _toPromptSpeaker(String speaker) => switch (speaker) {
  kTtsUnknown => kMangaPromptUnknown,
  kTtsNarrator => kMangaPromptNarrator,
  _ => speaker,
};

/// 回复里的说话人 → 角色表规范名；别名换成规范名，旁白 / 不明换回内部名。
/// 不认识的原样返回（交校验丢弃）。
String normalizeMangaSpeaker(
  Map<String, TtsCastCharacter> roster,
  String raw, {
  CastPromptRoster? promptRoster,
}) {
  final String s = promptRoster?.restoreSpeaker(raw) ?? raw.trim();
  if (s == kMangaPromptUnknown || s == kTtsUnknown) return kTtsUnknown;
  if (s == kMangaPromptNarrator || s == kTtsNarrator) return kTtsNarrator;
  return canonicalCastName(roster, s) ?? s;
}

/// 系列角色表在前、本卷的在后（同名以系列为准），供提示词与说话人校验。
Map<String, TtsCastCharacter> mergedMangaRoster({
  required Map<String, TtsCastCharacter> series,
  required Map<String, TtsCastCharacter> volume,
}) {
  final Map<String, TtsCastCharacter> out = <String, TtsCastCharacter>{
    ...series,
  };
  mergeCastRoster(out, volume.values);
  return out;
}

String _rosterLine(TtsCastCharacter c) {
  final List<String> parts = <String>[c.name];
  if (c.aliases.isNotEmpty) parts.add('aliases: ${c.aliases.join('、')}');
  if (c.gender != null) parts.add(c.gender!);
  if (c.age != null) parts.add(c.age!);
  if (c.description != null) parts.add(c.description!);
  return '- ${parts.join(' | ')}';
}

void _writeRoster(StringBuffer b, Iterable<TtsCastCharacter> roster) {
  b.writeln('[cast list]');
  final List<TtsCastCharacter> list = roster
      .take(kMangaPromptMaxRoster)
      .toList();
  if (list.isEmpty) {
    b.writeln('(empty)');
  } else {
    for (final TtsCastCharacter c in list) {
      b.writeln(_rosterLine(c));
    }
  }
}

/// 一块在提示词里的一行：下标、0..1000 归一化外框、竖 / 横、（注音块）`ruby-of:<底本>`、
/// 文字（JSON 字符串字面量，多行与引号不会串行）。
String _blockLine(
  int index,
  MokuroBlock block,
  MokuroSize size,
  List<CastTextSubstitution> substitutions, {
  int? rubyOf,
}) {
  int norm(double v, double extent) =>
      extent <= 0 ? 0 : (v / extent * 1000).round().clamp(0, 1000);
  final MokuroRect r = block.rectangle;
  final String box =
      '${norm(r.left, size.width)},${norm(r.top, size.height)},'
      '${norm(r.right, size.width)},${norm(r.bottom, size.height)}';
  return '$index [$box] ${block.isVertical ? 'V' : 'H'} '
      '${rubyOf == null ? '' : 'ruby-of:$rubyOf '}'
      '${jsonEncode(applyCastSubstitutions(block.lines.join(), substitutions))}';
}

// ---------------------------------------------------------------------------
// 第一遍：角色表
// ---------------------------------------------------------------------------

const String kMangaRosterSystemPrompt = '''
You build the cast list of a manga volume so an audiobook can give each character a different voice.

You get page images (the cover first, then the first pages of the volume), the OCR text of those pages, and the cast list known so far for this series. Return ONLY one JSON object — no prose, no code fence:
{"characters":[{"name":"宮城","aliases":["宮城さん"],"gender":"female","age":"teen","desc":"blunt, teasing speech; short dark hair"}]}

- List characters who speak (or clearly will speak) and are NOT in the cast list yet, plus existing characters whose aliases / gender / age / desc you can now fill in (repeat their canonical name exactly).
- "gender": "female" | "male" | "unknown". "age": "child" | "teen" | "adult" | "elderly" | "unknown". "desc": one short phrase about persona, way of speaking and the visual features you use to recognise them, in the manga's language.
- Write names exactly as the manga writes them, in the original script. Never translate or romanize. Keep the canonical names of the cast list unchanged; other forms go into "aliases".
- A speaker who is never named gets a short descriptive label (e.g. 店員, 男子生徒) so lines can be attributed later.
- If nothing changes, return {"characters":[]}.
''';

/// 第一遍的用户消息。[pages] = 带图的页（下标 + 该页块 + 尺寸），图按同序附在消息里。
String buildMangaRosterUserPrompt({
  required Iterable<TtsCastCharacter> roster,
  required List<({int page, MokuroImage image})> pages,
  required bool hasCover,
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
  CastPromptRoster? promptRoster,
}) {
  final CastPromptRoster view =
      promptRoster ??
      CastPromptRoster(roster: roster, substitutions: substitutions);
  final StringBuffer b = StringBuffer();
  _writeRoster(b, view.characters);
  b.writeln();
  final int imageCount = pages.length + (hasCover ? 1 : 0);
  b.writeln(
    '[images] $imageCount attached in order'
    '${hasCover ? ': the cover, then' : ':'} '
    '${pages.map((({int page, MokuroImage image}) e) => 'page ${e.page + 1}').join(', ')}.',
  );
  for (final ({int page, MokuroImage image}) e in pages) {
    b.writeln();
    b.writeln('[page ${e.page + 1} text blocks]');
    if (e.image.blocks.isEmpty) b.writeln('(no text)');
    final MangaPageRuby ruby = detectMangaPageRuby(e.image.blocks);
    for (int i = 0; i < e.image.blocks.length; i++) {
      b.writeln(
        _blockLine(
          i,
          e.image.blocks[i],
          e.image.size,
          substitutions,
          rubyOf: ruby.baseOfRuby[i],
        ),
      );
    }
  }
  return b.toString();
}

TtsCastCharacter? _characterFrom(Object? raw) {
  if (raw is! Map) return null;
  final Object? name = raw['name'];
  if (name is! String) return null;
  final String n = name.trim();
  if (n.isEmpty ||
      n == kMangaPromptUnknown ||
      n == kMangaPromptNarrator ||
      n == kTtsUnknown ||
      n == kTtsNarrator) {
    return null;
  }
  String? enumOrNull(Object? v, Set<String> allowed) =>
      v is String && allowed.contains(v) ? v : null;
  final Object? aliases = raw['aliases'];
  final Object? desc = raw['desc'];
  return TtsCastCharacter(
    name: n,
    aliases: <String>{
      if (aliases is List)
        for (final Object? a in aliases)
          if (a is String && a.trim().isNotEmpty && a.trim() != n) a.trim(),
    }.toList(),
    gender: enumOrNull(raw['gender'], const <String>{'female', 'male'}),
    age: enumOrNull(raw['age'], const <String>{
      'child',
      'teen',
      'adult',
      'elderly',
    }),
    description: desc is String && desc.trim().isNotEmpty ? desc.trim() : null,
  );
}

/// 解析第一遍回复；不是 `{"characters":[…]}` 返回 null（调用方记 `bad_output`）。
List<TtsCastCharacter>? parseMangaRosterReply(
  String reply, {
  CastPromptRoster? promptRoster,
}) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? list = json?['characters'];
  if (list is! List) return null;
  return <TtsCastCharacter>[
    for (final Object? raw in list)
      if (_characterFrom(raw) case final TtsCastCharacter c)
        if ((promptRoster == null ? c : promptRoster.restoreCharacter(c))
            case final TtsCastCharacter restored)
          restored,
  ];
}

// ---------------------------------------------------------------------------
// 第二遍：逐页
// ---------------------------------------------------------------------------

String get kMangaPageSystemPrompt =>
    '''
You direct the audio drama of a manga, one page at a time. You get the page image, its OCR text blocks, the cast list, and the last lines already directed on earlier pages.

Each block line is: index [x0,y0,x1,y1 box on a 0..1000 page grid] V(vertical)/H(horizontal) "text". A block marked ruby-of:N is the furigana / reading printed beside block N: never make it a line of its own — put it in the same line as block N (or leave it out); the audio speaks block N with that reading automatically. The OCR order of blocks is NOT the reading order — decide the order from the image (Japanese manga: panels right-to-left, top-to-bottom; balloons inside a panel likewise).

Return ONLY one JSON object — no prose, no code fence:
{"lines":[{"b":[3,1],"s":"宮城","k":"spoken","beat":200,"e":"joy","ei":60,"tone":"からかうように","c":0.9}],"new":[{"name":"店員","gender":"female","age":"adult","desc":"polite clerk"}],"lead":700}

"lines" — in reading order, one entry per line to be voiced or deliberately left unread:
- "b": block indexes of this line, in reading order. One balloon split into several blocks is one line. Every block belongs to at most one line.
- "s": the speaker — a canonical name from the cast list, a name you declare in "new", "$kMangaPromptNarrator" (narration boxes, titles, letters, signs read as narration) or "$kMangaPromptUnknown" (a spoken line whose speaker you cannot tell even from context).
- "k": ${CastLineKind.values.map((CastLineKind k) => '"${k.wire}"').join(' | ')}. "narration" = formal third-person text; "monologue" = first-person narration in a box; "thought" = thought balloon; "spoken" = normal speech; "shout"; "mutter" = quiet talking to oneself; "skip" = not read aloud (sound effects, handwritten side notes, OCR noise).
- "beat": optional extra pause after the line in milliseconds (0..${MangaScriptLimits.maxBeatMs}), for dramatic timing.
- "e": optional emotion, one of ${CastEmotion.values.map((CastEmotion e) => '"${e.wire}"').join(' | ')}; "ei": its intensity 0..100.
- "tone": optional short Japanese acting note (at most 20 characters, e.g. "おずおずと", "必死に食い下がる", "声を落として") saying HOW this line is delivered — the nuance the emotion word cannot carry.
- "c": your confidence in the speaker, 0..1.
- "fix": optional {"<block index>":"corrected text"} only for obvious OCR misreads. Never add readings or furigana.
Decide line by line, not page by page: never leave a whole page out because of one line.
Direct each line's delivery on its own. When the same speaker says several lines in a row, do NOT copy one direction across all of them: read each line's sentence-final particles and what the line does (apology, excuse, empathy, promise, plea, emotional appeal, …) and give each line its own "e" / "ei" / "tone", so the delivery changes from line to line the way a real actor's would.

"new" — characters who speak on this page but are missing from the cast list (same fields as the cast list). Omit when empty.
"hold" — only for a page with no voiced line: how long the reader should look at it, milliseconds (0..${MangaScriptLimits.maxHoldMs}). "lead" — optional time to look at the page before the first line (0..${MangaScriptLimits.maxLeadMs}). Omit both to use the defaults.
''';

/// 逐页提示词里「前几页已定的行」的一条。
typedef MangaPreviousLine = ({String speaker, CastLineKind kind, String text});

/// 第二遍一页的用户消息。[pageCount] 是全卷页数（只用于「第几页 / 共几页」）。
String buildMangaPageUserPrompt({
  required int page,
  required int pageCount,
  required MokuroImage image,
  required Iterable<TtsCastCharacter> roster,
  required List<MangaPreviousLine> previous,
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
  CastPromptRoster? promptRoster,
}) {
  final CastPromptRoster view =
      promptRoster ??
      CastPromptRoster(roster: roster, substitutions: substitutions);
  final StringBuffer b = StringBuffer();
  b.writeln('[page ${page + 1} of $pageCount] image attached.');
  b.writeln();
  _writeRoster(b, view.characters);
  b.writeln();
  b.writeln('[previous lines]');
  if (previous.isEmpty) b.writeln('(none)');
  for (final MangaPreviousLine l in previous.take(kMangaPagePreviousLines)) {
    b.writeln(
      '- ${_toPromptSpeaker(view.speakerFor(l.speaker))} (${l.kind.wire}): ${jsonEncode(l.text)}',
    );
  }
  b.writeln();
  b.writeln('[text blocks]');
  final MangaPageRuby ruby = detectMangaPageRuby(image.blocks);
  for (int i = 0; i < image.blocks.length; i++) {
    b.writeln(
      _blockLine(
        i,
        image.blocks[i],
        image.size,
        substitutions,
        rubyOf: ruby.baseOfRuby[i],
      ),
    );
  }
  return b.toString();
}

/// 一页的解析结果。
class MangaPageAnnotation {
  const MangaPageAnnotation({
    required this.validation,
    required this.newCharacters,
    required this.directive,
    required this.rawLineCount,
  });

  /// 校验结果：保留的行、丢弃的行（带原因）、没被认领的块（按「不读」处理）。
  final MangaPageValidation validation;

  /// 本页新登场、已并进角色表的人。
  final List<TtsCastCharacter> newCharacters;

  /// 本页的 `hold` / `lead`（夹到范围）；都没给是空指令。
  final MangaPageDirective directive;

  /// 回复里 `lines` 的条数（含被丢弃的）。
  final int rawLineCount;

  /// 有块、模型也回了行，却一行都没留下：整页按校验失败处理（可重试）。模型回
  /// 空 `lines` 不算：那是它判断整页都不读（全是拟声词之类），按块逐个列为未认领。
  bool get allRejected => rawLineCount > 0 && validation.accepted.isEmpty;
}

/// 解析第二遍一页的回复并本地校验。先把 `new` 并进 [roster]（调用方传进来的就是
/// 本次运行的工作角色表，会被就地补充），说话人的别名换成规范名，再交
/// [validateMangaPageLines]。回复不是带 `lines` 数组的对象返回 null（`bad_output`）。
MangaPageAnnotation? parseMangaPageReply(
  String reply, {
  required int page,
  required int blockCount,
  required Map<String, TtsCastCharacter> roster,
  CastPromptRoster? promptRoster,
}) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? lines = json?['lines'];
  if (json == null || lines is! List) return null;

  final Object? rawNew = json['new'];
  final List<TtsCastCharacter> fresh = <TtsCastCharacter>[
    if (rawNew is List)
      for (final Object? raw in rawNew)
        if (_characterFrom(raw) case final TtsCastCharacter c)
          if ((promptRoster == null ? c : promptRoster.restoreCharacter(c))
              case final TtsCastCharacter restored)
            if (canonicalCastName(roster, restored.name) == null) restored,
  ];
  mergeCastRoster(roster, fresh);

  final List<Object?> normalized = <Object?>[
    for (final Object? raw in lines)
      if (raw is Map && raw['s'] is String)
        <Object?, Object?>{
          ...raw,
          's': normalizeMangaSpeaker(
            roster,
            raw['s'] as String,
            promptRoster: promptRoster,
          ),
        }
      else
        raw,
  ];
  final MangaPageValidation validation = validateMangaPageLines(
    page: page,
    blockCount: blockCount,
    rawLines: normalized,
    roster: roster.keys,
  );
  final MangaPageDirective directive =
      MangaPageDirective.fromJson(<String, Object?>{
        if (json['hold'] != null) 'hold': json['hold'],
        if (json['lead'] != null) 'lead': json['lead'],
      });
  return MangaPageAnnotation(
    validation: validation,
    newCharacters: fresh,
    // 有发声行的页 `hold` 没有意义（时间表只给无台词页用），不落盘以免误导复核。
    directive: validation.accepted.any((MangaScriptLine l) => l.kind.isAudible)
        ? MangaPageDirective(leadMs: directive.leadMs)
        : directive,
    rawLineCount: lines.length,
  );
}

/// 本页之前已定的最后几行（发声的），给下一页的提示词作上下文。
List<MangaPreviousLine> mangaPreviousLines(
  MangaAudioScript script,
  int beforePage,
  String Function(MangaScriptLine line) textOf, {
  int limit = kMangaPagePreviousLines,
}) {
  final List<MangaPreviousLine> out = <MangaPreviousLine>[];
  for (int i = script.lines.length - 1; i >= 0 && out.length < limit; i--) {
    final MangaScriptLine l = script.lines[i];
    if (l.page >= beforePage || !l.kind.isAudible) continue;
    out.add((speaker: l.speaker, kind: l.kind, text: textOf(l)));
  }
  return out.reversed.toList();
}

// ---------------------------------------------------------------------------
// 第三遍：整场复核
// ---------------------------------------------------------------------------

const String kMangaSceneReviewSystemPrompt = '''
You review the audio-drama direction of a stretch of consecutive manga pages. Each line was directed page by page; now read the whole scene at once and fix what only the wider context reveals: a speaker that contradicts the surrounding conversation, an UNKNOWN speaker that the context makes clear, a line kind that is inconsistent, an emotion curve or pacing that jumps.

Smooth the emotion curve, but keep the line-to-line variation: consecutive lines by the same speaker should NOT all share one emotion / intensity / tone. Read each line's sentence-final particles and speech act (apology, excuse, empathy, promise, plea, emotional appeal, …); where a run of lines was given one flat direction, give each line its own "e" / "ei" / "tone".

Each line is: id | speaker | kind | emotion/intensity | tone | beat | "text".
Return ONLY one JSON object listing the lines to change — no prose, no code fence:
{"edits":[{"id":"p12b3.1","s":"宮城","k":"thought","e":"tension","ei":40,"tone":"声を落として","beat":300}]}
- Include only the fields you change. "s" must be a canonical name from the cast list, "NARRATOR" or "UNKNOWN". "k" / "e" use the same vocabulary as the lines. "tone" is a short Japanese acting note (at most 20 characters) saying how the line is delivered. "beat" is milliseconds.
- Do not change the order of lines or which blocks they cover.
- If nothing needs changing, return {"edits":[]}.
''';

/// 一场（连续几页）的边界：页下标升序。
typedef MangaScene = List<int>;

/// 把有发声行的页切成一场一场：连续的页（页号相邻）放一场，满 [maxPages] 页或
/// [maxLines] 行就另起一场。只看 [pages] 里给的页（通常是本次刚标完的页）。
List<MangaScene> chunkMangaScenes(
  MangaAudioScript script,
  Iterable<int> pages, {
  int maxPages = kMangaSceneMaxPages,
  int maxLines = kMangaSceneMaxLines,
}) {
  final Map<int, int> lineCount = <int, int>{};
  for (final MangaScriptLine l in script.lines) {
    if (l.kind.isAudible) lineCount[l.page] = (lineCount[l.page] ?? 0) + 1;
  }
  final List<int> sorted =
      pages.where((int p) => (lineCount[p] ?? 0) > 0).toSet().toList()..sort();
  final List<MangaScene> scenes = <MangaScene>[];
  List<int> current = <int>[];
  int lines = 0;
  for (final int p in sorted) {
    final int n = lineCount[p]!;
    final bool gap = current.isNotEmpty && p != current.last + 1;
    if (current.isNotEmpty &&
        (gap || current.length >= maxPages || lines + n > maxLines)) {
      scenes.add(current);
      current = <int>[];
      lines = 0;
    }
    current.add(p);
    lines += n;
  }
  if (current.isNotEmpty) scenes.add(current);
  return scenes;
}

/// 整场复核的用户消息。[textOf] 取一句的台词文本（应用层按 OCR 拼）。
String buildMangaSceneReviewUserPrompt({
  required MangaAudioScript script,
  required MangaScene scene,
  required Iterable<TtsCastCharacter> roster,
  required String Function(MangaScriptLine line) textOf,
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
  CastPromptRoster? promptRoster,
}) {
  final CastPromptRoster view =
      promptRoster ??
      CastPromptRoster(roster: roster, substitutions: substitutions);
  final StringBuffer b = StringBuffer();
  _writeRoster(b, view.characters);
  for (final int page in scene) {
    b.writeln();
    b.writeln('[page ${page + 1}]');
    for (final MangaScriptLine l in script.linesOnPage(page)) {
      if (!l.kind.isAudible) continue;
      final String emotion = l.emotion == null
          ? '-'
          : '${l.emotion!.wire}/${l.intensity ?? '-'}';
      b.writeln(
        '${l.lineId} | ${_toPromptSpeaker(view.speakerFor(l.speaker))} | ${l.kind.wire} | '
        '$emotion | ${l.tone ?? '-'} | ${l.beatMs} | ${jsonEncode(textOf(l))}',
      );
    }
  }
  return b.toString();
}

/// 复核里对一句的修改（只含要改的字段）。
class MangaReviewEdit {
  const MangaReviewEdit({
    required this.lineId,
    this.speaker,
    this.kind,
    this.emotion,
    this.intensity,
    this.tone,
    this.beatMs,
  });

  final String lineId;
  final String? speaker;
  final CastLineKind? kind;
  final CastEmotion? emotion;
  final int? intensity;

  /// 语气说明（经 [castToneOf] 截断；空串当没改）。
  final String? tone;
  final int? beatMs;

  bool get isEmpty =>
      speaker == null &&
      kind == null &&
      emotion == null &&
      intensity == null &&
      tone == null &&
      beatMs == null;
}

/// 解析复核回复：每条修改逐字段校验——说话人不在角色表（含别名、旁白 / 不明）、
/// 类型 / 情绪不在词表内的字段丢掉，其余字段照收；数值夹到范围。回复不是带
/// `edits` 数组的对象返回 null。
List<MangaReviewEdit>? parseMangaSceneReviewReply(
  String reply, {
  required Map<String, TtsCastCharacter> roster,
  CastPromptRoster? promptRoster,
}) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? edits = json?['edits'];
  if (edits is! List) return null;
  final List<MangaReviewEdit> out = <MangaReviewEdit>[];
  for (final Object? raw in edits) {
    if (raw is! Map || raw['id'] is! String) continue;
    String? speaker;
    if (raw['s'] case final String s) {
      final String n = normalizeMangaSpeaker(
        roster,
        s,
        promptRoster: promptRoster,
      );
      if (n == kTtsUnknown || n == kTtsNarrator || roster.containsKey(n)) {
        speaker = n;
      }
    }
    final Object? beat = raw['beat'];
    final Object? ei = raw['ei'];
    final MangaReviewEdit edit = MangaReviewEdit(
      lineId: raw['id'] as String,
      speaker: speaker,
      kind: CastLineKind.parse(raw['k']),
      emotion: CastEmotion.parse(raw['e']),
      intensity: ei is num && ei.isFinite
          ? ei.round().clamp(0, MangaScriptLimits.maxIntensity)
          : null,
      tone: castToneOf(raw['tone']),
      beatMs: beat is num && beat.isFinite
          ? beat.round().clamp(0, MangaScriptLimits.maxBeatMs)
          : null,
    );
    if (!edit.isEmpty) out.add(edit);
  }
  return out;
}

/// 把复核修改套到演出稿上：只改 [scene] 里、AI 标的行（用户改过的行不动）；
/// 返回实际改动的行数。改完的行来源仍是 AI（重标时照常被新结果替换）。
int applyMangaSceneReview(
  MangaAudioScript script,
  MangaScene scene,
  List<MangaReviewEdit> edits,
) {
  final Set<int> pages = scene.toSet();
  int changed = 0;
  for (final MangaReviewEdit e in edits) {
    final int i = script.lines.indexWhere(
      (MangaScriptLine l) => l.lineId == e.lineId,
    );
    if (i < 0) continue;
    final MangaScriptLine old = script.lines[i];
    if (!pages.contains(old.page) || old.source == TtsCastSource.user) {
      continue;
    }
    final CastEmotion? emotion = e.emotion ?? old.emotion;
    final MangaScriptLine next = MangaScriptLine(
      page: old.page,
      blocks: old.blocks,
      speaker: e.speaker ?? old.speaker,
      kind: e.kind ?? old.kind,
      beatMs: e.beatMs ?? old.beatMs,
      emotion: emotion,
      intensity: emotion == null ? null : e.intensity ?? old.intensity,
      rateOffset: old.rateOffset,
      pitchOffset: old.pitchOffset,
      volumeOffset: old.volumeOffset,
      seed: old.seed,
      tone: e.tone ?? old.tone,
      textFixes: old.textFixes,
      source: old.source,
      confidence: old.confidence,
      audio: old.audio,
      voice: old.voice,
      say: old.say,
    );
    if (jsonEncode(next.toJson()) == jsonEncode(old.toJson())) continue;
    script.lines[i] = next;
    changed++;
  }
  return changed;
}

// ---------------------------------------------------------------------------
// 发起前的预估与页图尺寸
// ---------------------------------------------------------------------------

/// 发起前的请求数预估（设计 §4：每页至少一次带图请求）。
class MangaAnnotationEstimate {
  const MangaAnnotationEstimate({
    required this.rosterRequests,
    required this.pageRequests,
    required this.reviewRequests,
  });

  final int rosterRequests;

  /// 有文字的页各一次带图请求；没文字的页不发请求。
  final int pageRequests;

  /// 整场复核按每 [kMangaSceneMaxPages] 页一次估（实际按场切，只会更少或相当）。
  final int reviewRequests;

  int get total => rosterRequests + pageRequests + reviewRequests;

  /// 带图的请求数（角色表 + 逐页）。
  int get imageRequests => rosterRequests + pageRequests;
}

/// [blockCounts] = 本次要标的各页的 OCR 块数；[withRoster] = 是否跑角色表那一遍。
MangaAnnotationEstimate estimateMangaAnnotation(
  Iterable<int> blockCounts, {
  bool withRoster = true,
}) {
  final int pages = blockCounts.where((int n) => n > 0).length;
  return MangaAnnotationEstimate(
    rosterRequests: withRoster && pages > 0 ? 1 : 0,
    pageRequests: pages,
    reviewRequests: (pages / kMangaSceneMaxPages).ceil(),
  );
}

/// 页图缩到长边 [maxSide] 时的目标尺寸；已经不大于它返回 null（原图照发）。
({int width, int height})? mangaAnnotateImageTarget(
  double width,
  double height, {
  int maxSide = kMangaAnnotateImageMaxSide,
}) {
  if (width <= 0 || height <= 0) return null;
  final double longest = math.max(width, height);
  if (longest <= maxSide) return null;
  final double scale = maxSide / longest;
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// 角色表那一遍带图的页：有文字的前 [kMangaRosterImagePages] 页（跳过封面页 0，
/// 封面另作一张）。
List<int> mangaRosterImagePages(List<MokuroImage> images) => <int>[
  for (int i = 1; i < images.length; i++)
    if (images[i].blocks.isNotEmpty) i,
].take(kMangaRosterImagePages).toList();
