/// 多声优配音的「选角表」：每句台词归哪个角色、每个角色用哪份声音预设。
///
/// - 句子按 `(章, 句首匹配偏移)` 指认（[ttsLineKey]），不按计划下标：计划随发音词典 /
///   分句规则变化会整体平移，坐标锚在正文上才稳定。
/// - 角色标注可以来自 LLM（[TtsCastSource.llm]）或用户手改（[TtsCastSource.user]，
///   重新标注时保留，不被 LLM 覆盖）。
/// - 没有归属的句子、归给「旁白」的句子、角色没配声音的句子，一律用任务的默认声音
///   （旁白声音）。
/// - 每句的演出字段（类型 / 一拍 / 情绪 + 强度 / 种子，见 `cast_line_direction.dart`）
///   与漫画演出稿同名同口径；句间停顿见 `tts_cast_timing.dart`。
/// - 每本书一个 JSON 文件，原子写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';

/// 旁白（叙述）的固定角色名。
const String kTtsNarrator = '__narrator__';

/// 是台词、但判断不出是谁说的（与旁白分开：用户可以一次性把它们指给某个角色，
/// 或给「不明」单独配一个声音）。
const String kTtsUnknown = '__unknown__';

String ttsLineKey(int section, int matchStart) => '$section:$matchStart';

enum TtsCastSource { llm, user }

/// 归属依据（小说说话人识别的三类：有「X 说」明确提示 / 靠代词或称谓回指 / 无任何
/// 提示、靠对话轮次推断）。复核界面优先列后两类。
enum TtsCastEvidence { explicit, anaphoric, implicit }

class TtsCastLine {
  const TtsCastLine({
    required this.speaker,
    required this.source,
    this.kind,
    this.beatMs = 0,
    this.emotion,
    this.intensity,
    this.rateOffset,
    this.pitchOffset,
    this.volumeOffset,
    this.seed,
    this.tone,
    this.confidence,
    this.evidence,
    this.voice,
    this.say,
  });

  /// 角色名；[kTtsNarrator] = 旁白，[kTtsUnknown] = 说话人不明。
  final String speaker;
  final TtsCastSource source;

  /// 类型（与漫画演出稿同一词表）；null = 没标，按说话人推断（见 [effectiveKind]）。
  final CastLineKind? kind;

  /// 句后额外停顿（毫秒），叠加在转场基础值之上（[CastLineLimits.maxBeatMs] 封顶）。
  final int beatMs;

  /// 情绪（封闭词表，只标注、不参与合成）+ 强度 0..100。
  final CastEmotion? emotion;
  final int? intensity;

  /// 语速 / 音高 / 音量偏移（可选；引擎不支持的字段忽略）。
  final double? rateOffset;
  final double? pitchOffset;
  final double? volumeOffset;

  /// 种子；null = 用作品默认种子（[TtsCast.defaultSeed]）。单句重生成时写入。
  final int? seed;

  /// 旧版选角表里 LLM 给的自由文本语气提示（如「囁き」；新标注不再产出，只展示）。
  final String? tone;

  /// LLM 自报的把握（0..1）；用户手改的行为 null（视为确定）。
  final double? confidence;
  final TtsCastEvidence? evidence;

  /// 这一句单独指定的声音（「切配置重试」成功后写入，或用户手动指定）；null = 按角色。
  final String? voice;

  /// 手动填写的要念的文字（替换计划里的念法；小说的「文本修正」就是它）；null = 照
  /// 原文。与漫画演出稿同名字段。
  final String? say;

  /// 实际类型：标了用标的；没标时旁白 = 叙述、其余 = 说出口。
  CastLineKind get effectiveKind =>
      kind ??
      (speaker == kTtsNarrator ? CastLineKind.narration : CastLineKind.spoken);

  /// 这句的演出字段（与漫画 `MangaScriptLine.direction` 同一个类型）。
  CastLineDirection get direction => CastLineDirection(
    beatMs: beatMs,
    emotion: emotion,
    intensity: intensity,
    rateOffset: rateOffset,
    pitchOffset: pitchOffset,
    volumeOffset: volumeOffset,
    seed: seed,
  );

  /// 用户挂在这行上的补回设置（单句声音 / 念法 / 重生成写下的种子）：重新标注时要
  /// 跟着这行留下来。
  bool get hasUserOverrides => voice != null || say != null || seed != null;

  TtsCastLine copyWith({
    String? speaker,
    TtsCastSource? source,
    CastLineKind? kind,
    int? beatMs,
    int? seed,
    String? voice,
    String? say,
    bool clearKind = false,
    bool clearSeed = false,
    bool clearVoice = false,
    bool clearSay = false,
    bool clearAiFields = false,
  }) => TtsCastLine(
    speaker: speaker ?? this.speaker,
    source: source ?? this.source,
    kind: clearKind ? null : kind ?? this.kind,
    beatMs: beatMs ?? this.beatMs,
    emotion: emotion,
    intensity: intensity,
    rateOffset: rateOffset,
    pitchOffset: pitchOffset,
    volumeOffset: volumeOffset,
    seed: clearSeed ? null : seed ?? this.seed,
    tone: tone,
    confidence: clearAiFields ? null : confidence,
    evidence: clearAiFields ? null : evidence,
    voice: clearVoice ? null : voice ?? this.voice,
    say: clearSay ? null : say ?? this.say,
  );

  /// 换上 [voice] / [say]（null 清掉），其余照旧。
  TtsCastLine withOverrides({String? voice, String? say}) => copyWith(
    voice: voice,
    say: say,
    clearVoice: voice == null,
    clearSay: say == null,
  );

  /// 把 [kept] 上的用户补回设置（声音 / 念法 / 种子）挂到这行（新的 AI 标注）上。
  TtsCastLine withUserOverridesFrom(TtsCastLine kept) => copyWith(
    voice: kept.voice,
    say: kept.say,
    seed: kept.seed,
    clearVoice: kept.voice == null,
    clearSay: kept.say == null,
    clearSeed: kept.seed == null,
  );

  /// 需要人看一眼：不明、把握低于 0.7、或无提示推断的台词。
  bool get needsReview =>
      source == TtsCastSource.llm &&
      speaker != kTtsNarrator &&
      (speaker == kTtsUnknown ||
          (confidence ?? 1) < 0.7 ||
          evidence == TtsCastEvidence.implicit);

  Map<String, Object?> toJson() => <String, Object?>{
    's': speaker,
    'src': source.name,
    if (kind != null) 'k': kind!.wire,
    ...direction.toJson(),
    if (tone != null) 'tone': tone,
    if (confidence != null) 'c': confidence,
    if (evidence != null) 'ev': evidence!.name,
    if (voice != null) 'voice': voice,
    if (say != null) 'say': say,
  };

  /// 宽松解析（旧文件照读）：演出字段按 [CastLineDirection.fromJson] 夹到范围；
  /// 不认识的类型当作没标。旧版 `e` 存的是自由文本语气提示——不在情绪词表里的
  /// 原样转进 [tone]，不丢。
  static TtsCastLine? fromJson(Object? raw) {
    if (raw is! Map || raw['s'] is! String) return null;
    TtsCastEvidence? evidence;
    for (final TtsCastEvidence e in TtsCastEvidence.values) {
      if (e.name == raw['ev']) evidence = e;
    }
    final CastLineDirection d = CastLineDirection.fromJson(raw);
    final Object? legacyTone = raw['e'];
    final Object? tone = raw['tone'] ?? (d.emotion == null ? legacyTone : null);
    return TtsCastLine(
      speaker: raw['s'] as String,
      source: raw['src'] == TtsCastSource.user.name
          ? TtsCastSource.user
          : TtsCastSource.llm,
      kind: CastLineKind.parse(raw['k']),
      beatMs: d.beatMs,
      emotion: d.emotion,
      intensity: d.intensity,
      rateOffset: d.rateOffset,
      pitchOffset: d.pitchOffset,
      volumeOffset: d.volumeOffset,
      seed: d.seed,
      tone: tone is String && tone.trim().isNotEmpty ? tone : null,
      confidence: castDoubleIn(raw['c'], 0, 1),
      evidence: evidence,
      voice: raw['voice'] is String ? raw['voice'] as String : null,
      say: raw['say'] is String && (raw['say'] as String).trim().isNotEmpty
          ? raw['say'] as String
          : null,
    );
  }
}

/// 角色表里的一个人：规范名 + 别名 + 选角用的特征（LLM 第一遍抽取，用户可改）。
class TtsCastCharacter {
  const TtsCastCharacter({
    required this.name,
    this.aliases = const <String>[],
    this.gender,
    this.age,
    this.description,
  });

  final String name;
  final List<String> aliases;

  /// `female` / `male` / null（不明）。
  final String? gender;

  /// `child` / `teen` / `adult` / `elderly` / null。
  final String? age;

  /// 一句人设（口吻、身份），选声音时参考。
  final String? description;

  Map<String, Object?> toJson() => <String, Object?>{
    'n': name,
    if (aliases.isNotEmpty) 'a': aliases,
    if (gender != null) 'g': gender,
    if (age != null) 'age': age,
    if (description != null) 'd': description,
  };

  static TtsCastCharacter? fromJson(Object? raw) {
    if (raw is! Map || raw['n'] is! String) return null;
    final Object? a = raw['a'];
    return TtsCastCharacter(
      name: raw['n'] as String,
      aliases: <String>[
        if (a is List)
          for (final Object? v in a)
            if (v is String && v.isNotEmpty) v,
      ],
      gender: raw['g'] is String ? raw['g'] as String : null,
      age: raw['age'] is String ? raw['age'] as String : null,
      description: raw['d'] is String ? raw['d'] as String : null,
    );
  }
}

class TtsCast {
  TtsCast({
    Map<String, TtsCastLine>? lines,
    Map<String, String>? voices,
    Map<String, TtsCastCharacter>? roster,
    List<String>? retryVoices,
    this.annotatedSections = const <int>{},
    this.defaultSeed = 0,
  }) : lines = lines ?? <String, TtsCastLine>{},
       voices = voices ?? <String, String>{},
       roster = roster ?? <String, TtsCastCharacter>{},
       retryVoices = retryVoices ?? <String>[];

  /// 行键（[ttsLineKey]）→ 角色。
  final Map<String, TtsCastLine> lines;

  /// 角色 → 声音预设 id。旁白也可以单独配（否则用任务默认声音）。
  final Map<String, String> voices;

  /// 角色表：规范名 → 角色（别名 / 性别 / 年龄 / 人设）。LLM 第一遍按章增量抽取，
  /// 第二遍逐句归属只能从这里选（或 [kTtsUnknown]）。
  final Map<String, TtsCastCharacter> roster;

  /// 本书自己的「切配置重试」候选声音（按顺序试，排在系列的候选前面）。书不属于
  /// 任何系列时只有这一份。
  final List<String> retryVoices;

  /// 已经跑过 LLM 标注的章（UI 显示进度、重新标注跳过已完成的章）。
  Set<int> annotatedSections;

  /// 整部作品一个默认种子（设计 §6）；单句重生成写进该行的 [TtsCastLine.seed]。
  int defaultSeed;

  /// 这本书所属系列的声音指派（[SeriesCastProfile.voices]，不随本文件落盘）：本书
  /// 没给角色配声音时回落到系列里记住的声音。
  CastVoiceAssignment? series;

  /// 本书自己的指派表视图（旁白一行 = 叙述类）。
  CastVoiceAssignment get ownAssignment => CastVoiceAssignment(
    narrationVoice: voices[kTtsNarrator],
    byCharacter: <String, String>{
      for (final MapEntry<String, String> e in voices.entries)
        if (e.key != kTtsNarrator) e.key: e.value,
    },
    retryVoices: retryVoices,
  );

  /// 某个角色用的声音：本书 → 系列；null = 任务默认声音。
  String? voiceOf(String speaker) => ownAssignment.resolveOver(
    speaker,
    speaker == kTtsNarrator ? CastLineKind.narration : CastLineKind.spoken,
    series,
  );

  /// 声音是不是从系列继承来的（本书没设）。
  bool voiceInherited(String speaker) =>
      !voices.containsKey(speaker) && voiceOf(speaker) != null;

  bool get isEmpty => lines.isEmpty && voices.isEmpty;

  String speakerOf(int section, int matchStart) =>
      lines[ttsLineKey(section, matchStart)]?.speaker ?? kTtsNarrator;

  /// 这一句用哪份声音预设：句子单独指定 → 角色（本书 → 系列）；null = 任务默认声音。
  String? presetFor(int section, int matchStart) {
    final TtsCastLine? line = lines[ttsLineKey(section, matchStart)];
    return line?.voice ?? voiceOf(line?.speaker ?? kTtsNarrator);
  }

  /// 这一句实际用的种子：单句写下的 → 作品默认。
  int seedFor(int section, int matchStart) =>
      lines[ttsLineKey(section, matchStart)]?.seed ?? defaultSeed;

  /// 这章的句间停顿按演出稿算（跑过选角标注；见 `tts_cast_timing.dart`）。没标过的章
  /// 照旧只看段落 / 场景边界。
  bool directsSection(int section) => annotatedSections.contains(section);

  /// 单句重生成：给这一句写下新种子（null 清掉、回到作品默认）。没有标注行的句子按
  /// 旁白建一行（来源仍是 AI，之后的标注照常给它定说话人，种子留着）。
  void setLineSeed(int section, int matchStart, int? seed) {
    final String key = ttsLineKey(section, matchStart);
    final TtsCastLine base =
        lines[key] ??
        const TtsCastLine(speaker: kTtsNarrator, source: TtsCastSource.llm);
    lines[key] = base.copyWith(
      seed: seed?.clamp(0, CastLineLimits.maxSeed),
      clearSeed: seed == null,
    );
  }

  /// 这一句手动填写的念法；null = 照原文。
  String? sayFor(int section, int matchStart) =>
      lines[ttsLineKey(section, matchStart)]?.say;

  /// 给一句单独指定声音 / 念法（null 清掉）；没有标注行的句子按旁白建一行。
  void setLineOverrides(
    int section,
    int matchStart, {
    required String? voice,
    required String? say,
  }) {
    final String key = ttsLineKey(section, matchStart);
    final TtsCastLine base =
        lines[key] ??
        // 只为挂覆盖而建的行不算用户标注：之后的 AI 标注照常给它定说话人。
        const TtsCastLine(speaker: kTtsNarrator, source: TtsCastSource.llm);
    final String? cleanSay = say == null || say.trim().isEmpty ? null : say;
    lines[key] = base.withOverrides(voice: voice, say: cleanSay);
  }

  /// 出现过的角色（不含旁白）及台词数，按台词数降序。
  List<({String speaker, int count})> speakers() {
    final Map<String, int> counts = <String, int>{};
    for (final TtsCastLine line in lines.values) {
      if (line.speaker == kTtsNarrator) continue;
      counts[line.speaker] = (counts[line.speaker] ?? 0) + 1;
    }
    final List<({String speaker, int count})> out =
        <({String speaker, int count})>[
          for (final MapEntry<String, int> e in counts.entries)
            (speaker: e.key, count: e.value),
        ]..sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  /// 并入 LLM 的一章标注：用户手改过的行保留。
  void mergeLlm(int section, Map<String, TtsCastLine> annotated) {
    // 单句声音 / 念法 / 重生成写下的种子是用户的补回设置，挂在 AI 行上也要跨重新
    // 标注保留。
    final Map<String, TtsCastLine> overrides = <String, TtsCastLine>{};
    lines.removeWhere((String key, TtsCastLine line) {
      if (!key.startsWith('$section:') || line.source != TtsCastSource.llm) {
        return false;
      }
      if (line.hasUserOverrides) overrides[key] = line;
      return true;
    });
    annotated.forEach((String key, TtsCastLine line) {
      final TtsCastLine? existing = lines[key];
      if (existing != null && existing.source == TtsCastSource.user) return;
      final TtsCastLine? kept = overrides.remove(key);
      lines[key] = kept == null ? line : line.withUserOverridesFrom(kept);
    });
    // 这次没标到的句子：覆盖照样留着（说话人回到它原来的值）。
    lines.addAll(overrides);
    annotatedSections = <int>{...annotatedSections, section};
  }

  /// 并入第一遍抽到的角色：同名合并别名、空特征用新值补上（不覆盖已有值）。
  void mergeRoster(Iterable<TtsCastCharacter> found) =>
      mergeCastRoster(roster, found);

  /// 需要人工复核的行数（不明 / 低把握 / 无提示推断）。
  int get reviewCount =>
      lines.values.where((TtsCastLine l) => l.needsReview).length;

  /// 用户手动改一句的角色。演出字段（一拍 / 情绪 / 种子）与补回设置留着；类型与
  /// 新说话人对不上时（改成旁白、或从旁白改成角色）丢掉，按说话人重新推断。
  void setUserSpeaker(int section, int matchStart, String speaker) {
    final String key = ttsLineKey(section, matchStart);
    final TtsCastLine old =
        lines[key] ??
        const TtsCastLine(speaker: kTtsNarrator, source: TtsCastSource.llm);
    final bool narrator = speaker == kTtsNarrator;
    final bool kindFits =
        old.kind == null || (old.kind == CastLineKind.narration) == narrator;
    lines[key] = old.copyWith(
      speaker: speaker,
      source: TtsCastSource.user,
      clearKind: !kindFits,
      clearAiFields: true,
    );
  }

  /// 把一个角色改名 / 合并进另一个角色（LLM 常把同一人标成两个名字）。
  void renameSpeaker(String from, String to) {
    if (from == to) return;
    lines.updateAll(
      (String _, TtsCastLine line) =>
          line.speaker == from ? line.copyWith(speaker: to) : line,
    );
    final String? voice = voices.remove(from);
    if (voice != null) voices.putIfAbsent(to, () => voice);
    // 角色表：旧名成为新名的别名（下次标注时 LLM 会把它认作同一人）。
    final TtsCastCharacter? gone = roster.remove(from);
    if (gone != null && to != kTtsUnknown && to != kTtsNarrator) {
      mergeRoster(<TtsCastCharacter>[
        TtsCastCharacter(
          name: to,
          aliases: <String>[from, ...gone.aliases],
          gender: gone.gender,
          age: gone.age,
          description: gone.description,
        ),
      ]);
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'lines': <String, Object?>{
      for (final MapEntry<String, TtsCastLine> e in lines.entries)
        e.key: e.value.toJson(),
    },
    'voices': voices,
    'roster': <Object?>[
      for (final TtsCastCharacter c in roster.values) c.toJson(),
    ],
    'annotated': annotatedSections.toList()..sort(),
    if (retryVoices.isNotEmpty) 'retry': retryVoices,
    if (defaultSeed != 0) 'seed': defaultSeed,
  };

  static TtsCast fromJson(Object? raw) {
    if (raw is! Map) return TtsCast();
    final Object? lines = raw['lines'];
    final Object? voices = raw['voices'];
    final Object? annotated = raw['annotated'];
    final Object? roster = raw['roster'];
    final Object? retry = raw['retry'];
    final Object? seed = raw['seed'];
    return TtsCast(
      defaultSeed: seed is int ? seed.clamp(0, CastLineLimits.maxSeed) : 0,
      retryVoices: <String>[
        if (retry is List)
          for (final Object? v in retry)
            if (v is String && v.isNotEmpty) v,
      ],
      roster: <String, TtsCastCharacter>{
        if (roster is List)
          for (final Object? r in roster)
            if (TtsCastCharacter.fromJson(r) case final TtsCastCharacter c)
              c.name: c,
      },
      lines: <String, TtsCastLine>{
        if (lines is Map)
          for (final MapEntry<Object?, Object?> e in lines.entries)
            if (e.key is String)
              if (TtsCastLine.fromJson(e.value) case final TtsCastLine line)
                e.key! as String: line,
      },
      voices: <String, String>{
        if (voices is Map)
          for (final MapEntry<Object?, Object?> e in voices.entries)
            if (e.key is String && e.value is String)
              e.key! as String: e.value! as String,
      },
      annotatedSections: <int>{
        if (annotated is List)
          for (final Object? v in annotated)
            if (v is int) v,
      },
    );
  }
}

/// 每本书一份选角表：`<root>/<sha1(bookKey)>.json`。
class TtsCastStore {
  TtsCastStore(this.root);

  final Directory root;

  File _file(String bookKey) =>
      File(p.join(root.path, '${sha1.convert(utf8.encode(bookKey))}.json'));

  Future<TtsCast> load(String bookKey) async {
    final File f = _file(bookKey);
    if (!await f.exists()) return TtsCast();
    try {
      return TtsCast.fromJson(jsonDecode(await f.readAsString()));
    } on FormatException {
      await f.rename('${f.path}.corrupt');
      return TtsCast();
    }
  }

  Future<void> save(String bookKey, TtsCast cast) async {
    final File f = _file(bookKey);
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(cast.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}
