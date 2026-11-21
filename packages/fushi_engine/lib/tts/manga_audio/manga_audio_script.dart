/// 漫画有声模式的「演出稿」：每句台词锚在 `(页, [文本块下标…])` 上，带说话人、类型、
/// 一拍、情绪、种子、OCR 修正与音源；逐页带 `hold` / `lead`；整份带生成时的 OCR 签名、
/// 作品默认种子、声音指派表与音源策略。设计见
/// `docs/specs/2026-11-17-manga-audio-mode-design.md` §1 / §5 / §6 / §9。
///
/// 与小说的选角表（`tts_cast.dart` 的 `TtsCast`）是**并列的两个类型**，不改 `TtsCast`：
/// - 小说行锚是 `(章, 句首偏移)`，存成无序的 `Map<行键, 行>`；漫画行锚是块下标，
///   且行的先后就是阅读顺序（不采用 OCR 的块顺序），必须是有序列表。
/// - 两者共享角色表（[TtsCastCharacter]）、来源（[TtsCastSource]）和旁白 / 不明两个
///   固定角色名，所以角色相关的语义只有一份。
///
/// 演出稿不存台词文本：合成与显示时按块下标从 OCR 结果取（见
/// `manga_audio_validate.dart` 的 `resolveMangaLineText`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

export 'package:fushi_engine/tts/cast/cast_line_direction.dart'
    show CastLineDirection, CastLineLimits;
export 'package:fushi_engine/tts/cast/cast_line_kind.dart';
export 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';

/// 一部作品的音源策略（设计 §9）。
enum MangaAudioSourcePolicy {
  /// 有声书命中的句子用有声书片段，其余合成（默认）。
  audiobookFirst('audiobook_first'),

  /// 只用有声书命中的句子，其余不读。
  audiobookOnly('audiobook_only'),

  /// 全部合成。
  synthOnly('synth_only');

  const MangaAudioSourcePolicy(this.wire);

  final String wire;

  static MangaAudioSourcePolicy parse(Object? raw) {
    for (final MangaAudioSourcePolicy v in values) {
      if (v.wire == raw) return v;
    }
    return MangaAudioSourcePolicy.audiobookFirst;
  }
}

/// 数值字段的取值范围（与小说选角表共用一份，见 [CastLineLimits]）。
typedef MangaScriptLimits = CastLineLimits;

/// 一句的音源：合成，或引用某本有声书里一段现成音频（不复制音频）。
///
/// [byUser] = 用户亲手定的音源：重跑有声书匹配（`manga_audiobook_match.dart` 的
/// [applyMangaAudiobookMatches]）时不覆盖，且不受作品音源策略约束（见
/// [MangaAudioScript.audioPlanFor]）。AI / 匹配器写的为 false。
sealed class MangaLineAudioSource {
  const MangaLineAudioSource({this.byUser = false});

  final bool byUser;

  Map<String, Object?> toJson();

  static MangaLineAudioSource fromJson(Object? raw) {
    final bool byUser = raw is Map && raw['u'] == true;
    if (raw is Map && raw['t'] == MangaAudiobookClip.wireTag) {
      final Object? f = raw['f'];
      final Object? s = raw['s'];
      final Object? e = raw['e'];
      final Object? k = raw['k'];
      if (f is int && s is int && e is int && f >= 0 && s >= 0 && e > s) {
        return MangaAudiobookClip(
          bookKey: k is String && k.isNotEmpty ? k : null,
          fileIndex: f,
          startMs: s,
          endMs: e,
          byUser: byUser,
        );
      }
    }
    return byUser
        ? const MangaSynthesized(byUser: true)
        : const MangaSynthesized();
  }
}

/// 按声音指派表合成（默认）。
final class MangaSynthesized extends MangaLineAudioSource {
  const MangaSynthesized({super.byUser});

  static const String wireTag = 'synth';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': wireTag,
    if (byUser) 'u': true,
  };

  @override
  bool operator ==(Object other) =>
      other is MangaSynthesized && other.byUser == byUser;

  @override
  int get hashCode => Object.hash(wireTag, byUser);
}

/// 关联有声书里的一段：书 [bookKey]（`Audiobooks.bookKey`）的第 [fileIndex] 个音频
/// 文件（`Audiobook.audioFilesInCueOrder`，与 `AudioCue.audioFileIndex` 同一坐标）的
/// `[startMs, endMs)`。
///
/// [bookKey] 为 null 只出现在加 `k` 字段之前写下的旧行：那时演出稿只能关联一本书，
/// 消费端按 [MangaAudioScript.audiobookSources] 的第一本解释。
final class MangaAudiobookClip extends MangaLineAudioSource {
  const MangaAudiobookClip({
    this.bookKey,
    required this.fileIndex,
    required this.startMs,
    required this.endMs,
    super.byUser,
  });

  static const String wireTag = 'book';

  final String? bookKey;
  final int fileIndex;
  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  MangaAudiobookClip asUserPinned() => MangaAudiobookClip(
    bookKey: bookKey,
    fileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs,
    byUser: true,
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': wireTag,
    if (bookKey != null) 'k': bookKey,
    'f': fileIndex,
    's': startMs,
    'e': endMs,
    if (byUser) 'u': true,
  };

  @override
  bool operator ==(Object other) =>
      other is MangaAudiobookClip &&
      other.bookKey == bookKey &&
      other.fileIndex == fileIndex &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.byUser == byUser;

  @override
  int get hashCode => Object.hash(bookKey, fileIndex, startMs, endMs, byUser);
}

/// 一句最终怎么出声（[MangaAudioScript.audioPlanFor]），生成端只认这个结果。
enum MangaLineAudioPlan {
  /// 播放 / 导出关联有声书里的片段（[MangaScriptLine.audio] 是 [MangaAudiobookClip]）。
  audiobookClip,

  /// 按声音指派表合成。
  synthesize,

  /// 不读：策略是「只用有声书」而这句没命中。时间表里照常是一句（不跳页），没有音频；
  /// 它不是「未配音」行，不进未配音账本、不走重试。
  silent,
}

/// 演出稿里的一句。
class MangaScriptLine {
  MangaScriptLine({
    required this.page,
    required List<int> blocks,
    required this.speaker,
    required this.kind,
    this.beatMs = 0,
    this.emotion,
    this.intensity,
    this.rateOffset,
    this.pitchOffset,
    this.volumeOffset,
    this.seed,
    Map<int, String>? textFixes,
    this.source = TtsCastSource.llm,
    this.confidence,
    this.audio = const MangaSynthesized(),
    this.voice,
    this.say,
  }) : blocks = List<int>.unmodifiable(blocks),
       textFixes = Map<int, String>.unmodifiable(
         textFixes ?? const <int, String>{},
       );

  /// 页下标（0 起，同 `MokuroPayload.images`）。
  final int page;

  /// 该页 OCR 块下标，按朗读顺序；一句可以跨几个块。
  final List<int> blocks;

  /// 角色名；[kTtsNarrator] = 旁白，[kTtsUnknown] = 不明。
  final String speaker;

  final CastLineKind kind;

  /// 句后额外停顿（毫秒），叠加在转场基础值之上。
  final int beatMs;

  final CastEmotion? emotion;

  /// 情绪强度 0..100。
  final int? intensity;

  /// 语速 / 音高 / 音量偏移（可选；引擎不支持的字段忽略）。
  final double? rateOffset;
  final double? pitchOffset;
  final double? volumeOffset;

  /// 种子；null = 用作品默认种子（单句重生成时写入）。
  final int? seed;

  /// OCR 错字修正：块下标 → 修正后的文字（只用于改错字，不是注音）。
  final Map<int, String> textFixes;

  /// AI 标注或用户手改；用户改过的行重新标注时保留。
  final TtsCastSource source;

  /// AI 自评把握（0..1）；复核界面优先列低把握的行。
  final double? confidence;

  final MangaLineAudioSource audio;

  /// 这一句单独指定的声音（「切配置重试」成功后写入，或用户手动指定）；null = 按
  /// 声音指派表。与小说 `TtsCastLine.voice` 同名。
  final String? voice;

  /// 手动填写的要念的文字（整句替换 OCR 拼出来的文本）；null = 照 OCR（含
  /// [textFixes]）。与小说 `TtsCastLine.say` 同名。
  final String? say;

  /// 稳定的行身份：页 + 块下标（不用行序号——增删句子后序号会整体错位）。
  /// 音频文件名、未配音账本都按它。行不可变（改行一律 [copyWith] 出新对象），
  /// 所以首次取用后缓存，查行时不再每次拼字符串。
  late final String lineId = 'p${page}b${blocks.join('.')}';

  /// 这一行的 JSON 文本（[toJson] 编码后缓存）。行不可变，整稿存盘时没改过的行直接
  /// 复用，只有新行要重新编码（见 [MangaAudioScript.encode]）。
  late final String jsonText = jsonEncode(toJson());

  /// 这句实际用的种子。
  int effectiveSeed(int defaultSeed) => seed ?? defaultSeed;

  /// 这句的演出字段（与小说 `TtsCastLine.direction` 同一个类型）。
  CastLineDirection get direction => CastLineDirection(
    beatMs: beatMs,
    emotion: emotion,
    intensity: intensity,
    rateOffset: rateOffset,
    pitchOffset: pitchOffset,
    volumeOffset: volumeOffset,
    seed: seed,
  );

  MangaScriptLine copyWith({
    List<int>? blocks,
    String? speaker,
    CastLineKind? kind,
    int? beatMs,
    int? seed,
    Map<int, String>? textFixes,
    TtsCastSource? source,
    MangaLineAudioSource? audio,
    String? voice,
    String? say,
    bool clearVoice = false,
    bool clearSay = false,
  }) => MangaScriptLine(
    page: page,
    blocks: blocks ?? this.blocks,
    speaker: speaker ?? this.speaker,
    kind: kind ?? this.kind,
    beatMs: beatMs ?? this.beatMs,
    emotion: emotion,
    intensity: intensity,
    rateOffset: rateOffset,
    pitchOffset: pitchOffset,
    volumeOffset: volumeOffset,
    seed: seed ?? this.seed,
    textFixes: textFixes ?? this.textFixes,
    source: source ?? this.source,
    confidence: confidence,
    audio: audio ?? this.audio,
    voice: clearVoice ? null : voice ?? this.voice,
    say: clearSay ? null : say ?? this.say,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'p': page,
    'b': blocks,
    's': speaker,
    'k': kind.wire,
    ...direction.toJson(),
    if (textFixes.isNotEmpty)
      'fix': <String, String>{
        for (final MapEntry<int, String> e in textFixes.entries)
          '${e.key}': e.value,
      },
    'src': source.name,
    if (confidence != null) 'c': confidence,
    if (audio != const MangaSynthesized()) 'audio': audio.toJson(),
    if (voice != null) 'voice': voice,
    if (say != null) 'say': say,
  };

  /// 宽松解析已落盘的行：结构坏（缺页 / 块 / 说话人、类型不认识）返回 null，
  /// 数值夹到范围，不认识的情绪当作没标。AI 输出的严格校验在
  /// `validateMangaPageLines` 里做。
  static MangaScriptLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? page = raw['p'];
    final Object? blocks = raw['b'];
    final Object? speaker = raw['s'];
    final CastLineKind? kind = CastLineKind.parse(raw['k']);
    if (page is! int || page < 0 || blocks is! List || speaker is! String) {
      return null;
    }
    if (kind == null || speaker.isEmpty) return null;
    final List<int> blockList = <int>[
      for (final Object? b in blocks)
        if (b is int) b,
    ];
    if (blockList.isEmpty || blockList.length != blocks.length) return null;
    return mangaLineFromFields(
      raw,
      page: page,
      blocks: blockList,
      speaker: speaker,
      kind: kind,
      emotion: CastEmotion.parse(raw['e']),
    );
  }
}

/// 由已确认的结构字段 + 原始 map 里的可选字段组装一句（数值夹到范围）。
/// 落盘解析与 AI 输出校验共用，保证两边的夹取规则只有一份。
MangaScriptLine mangaLineFromFields(
  Map<Object?, Object?> raw, {
  required int page,
  required List<int> blocks,
  required String speaker,
  required CastLineKind kind,
  required CastEmotion? emotion,
  TtsCastSource? source,
}) {
  // 演出字段的夹取规则与小说共用一份（[CastLineDirection.fromJson]）；情绪用调用方
  // 已解析好的值。
  final CastLineDirection d = CastLineDirection.fromJson(<Object?, Object?>{
    ...raw,
    'e': emotion?.wire,
  });
  return MangaScriptLine(
    page: page,
    blocks: blocks,
    speaker: speaker,
    kind: kind,
    beatMs: d.beatMs,
    emotion: d.emotion,
    intensity: d.intensity,
    rateOffset: d.rateOffset,
    pitchOffset: d.pitchOffset,
    volumeOffset: d.volumeOffset,
    seed: d.seed,
    textFixes: _parseFixes(raw['fix'], blocks),
    source:
        source ??
        (raw['src'] == TtsCastSource.user.name
            ? TtsCastSource.user
            : TtsCastSource.llm),
    confidence: castDoubleIn(raw['c'], 0, 1),
    audio: MangaLineAudioSource.fromJson(raw['audio']),
    voice: raw['voice'] is String && (raw['voice'] as String).isNotEmpty
        ? raw['voice'] as String
        : null,
    say: raw['say'] is String && (raw['say'] as String).trim().isNotEmpty
        ? raw['say'] as String
        : null,
  );
}

/// 文本修正只保留指向本句块、且非空的条目。
Map<int, String> _parseFixes(Object? raw, List<int> blocks) {
  if (raw is! Map) return const <int, String>{};
  final Map<int, String> out = <int, String>{};
  for (final MapEntry<Object?, Object?> e in raw.entries) {
    final Object? k = e.key;
    final int? key = k is int ? k : int.tryParse('$k');
    final Object? value = e.value;
    if (key == null || value is! String || value.trim().isEmpty) continue;
    if (!blocks.contains(key)) continue;
    out[key] = value;
  }
  return out;
}

/// 逐页指令：`hold` = 无台词页整页停留；`lead` = 翻到该页后、第一句之前先看画面的时间。
/// null = 用默认值（见 `MangaTimingParams`）。
class MangaPageDirective {
  const MangaPageDirective({
    this.holdMs,
    this.leadMs,
    this.source = TtsCastSource.llm,
  });

  final int? holdMs;
  final int? leadMs;
  final TtsCastSource source;

  bool get isEmpty => holdMs == null && leadMs == null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (holdMs != null) 'hold': holdMs,
    if (leadMs != null) 'lead': leadMs,
    'src': source.name,
  };

  static MangaPageDirective fromJson(Object? raw) {
    if (raw is! Map) return const MangaPageDirective();
    return MangaPageDirective(
      holdMs: castIntIn(raw['hold'], 0, MangaScriptLimits.maxHoldMs),
      leadMs: castIntIn(raw['lead'], 0, MangaScriptLimits.maxLeadMs),
      source: raw['src'] == TtsCastSource.user.name
          ? TtsCastSource.user
          : TtsCastSource.llm,
    );
  }
}

/// 演出稿与当前 OCR 的关系。
enum MangaScriptFreshness {
  /// 签名一致（或演出稿里还没有任何行），块下标可直接用。
  upToDate,

  /// OCR 重跑过（或任一侧缺签名），块下标可能已错位：整卷需重新标注，不按坐标迁移。
  needsReannotation,
}

/// 过期判定（纯函数）：签名一致 → [MangaScriptFreshness.upToDate]；演出稿还没有任何行
/// 时无从错位，也算最新；其余（签名不同、任一侧缺签名）→ 需重新标注。
MangaScriptFreshness mangaScriptFreshness({
  required String? scriptSignature,
  required String? currentSignature,
  required bool hasLines,
}) {
  if (!hasLines) return MangaScriptFreshness.upToDate;
  if (scriptSignature != null &&
      currentSignature != null &&
      scriptSignature == currentSignature) {
    return MangaScriptFreshness.upToDate;
  }
  return MangaScriptFreshness.needsReannotation;
}

/// 一卷漫画的演出稿。
class MangaAudioScript {
  MangaAudioScript({
    this.engineSignature,
    this.defaultSeed = 0,
    CastVoiceAssignment? voices,
    this.sourcePolicy = MangaAudioSourcePolicy.audiobookFirst,
    Map<String, TtsCastCharacter>? roster,
    List<MangaScriptLine>? lines,
    Map<int, MangaPageDirective>? pages,
    Set<int>? annotatedPages,
    List<String>? audiobookSources,
  }) : voices = voices ?? CastVoiceAssignment(),
       roster = roster ?? <String, TtsCastCharacter>{},
       lines = lines ?? <MangaScriptLine>[],
       pages = pages ?? <int, MangaPageDirective>{},
       annotatedPages = annotatedPages ?? <int>{},
       audiobookSources = audiobookSources ?? <String>[];

  static const int schemaVersion = 1;

  /// 生成时 OCR 结果的 `engine_signature`（`MangaOcrMetadata.engineSignature`）。
  String? engineSignature;

  /// 整部作品一个默认种子（设计 §6）。
  int defaultSeed;

  final CastVoiceAssignment voices;

  MangaAudioSourcePolicy sourcePolicy;

  /// 角色表：规范名 → 角色。逐句说话人只能从这里选，或旁白 / 不明。
  final Map<String, TtsCastCharacter> roster;

  /// 全卷的行，按阅读顺序（页非降序，页内顺序 = 朗读顺序）。
  final List<MangaScriptLine> lines;

  /// 逐页指令（没有条目 = 用默认值）。
  final Map<int, MangaPageDirective> pages;

  /// 已跑过 AI 标注的页。
  final Set<int> annotatedPages;

  /// 关联的有声书（设计 §9）：书库里带 `Audiobooks` 的书的 bookKey，按**故事顺序**
  /// （同一系列多卷小说时第 1 卷在前）。有声书匹配把它们的 cue 依次接成一条语料，
  /// 单调推进。用户手动选，不自动猜。存在本卷演出稿里（JSON `books`，旧文件没有这个
  /// 键 = 没关联）；「整个系列一起关联」由应用层把同一份列表写进系列里每一卷的演出稿，
  /// 不另立 sidecar。
  final List<String> audiobookSources;

  /// 一句最终怎么出声：用户亲手定的音源（[MangaLineAudioSource.byUser]）优先，不受
  /// 策略约束；否则按 [sourcePolicy]——只合成时忽略匹配写下的片段，「只用有声书」时
  /// 没命中的句子不读。旧版没有 `k` 的片段在没有任何关联书时无从解释，按没命中处理。
  MangaLineAudioPlan audioPlanFor(MangaScriptLine line) {
    final MangaLineAudioSource audio = line.audio;
    final bool clipUsable =
        audio is MangaAudiobookClip &&
        (audio.bookKey != null || audiobookSources.isNotEmpty);
    if (audio.byUser) {
      return clipUsable
          ? MangaLineAudioPlan.audiobookClip
          : MangaLineAudioPlan.synthesize;
    }
    return switch (sourcePolicy) {
      MangaAudioSourcePolicy.synthOnly => MangaLineAudioPlan.synthesize,
      MangaAudioSourcePolicy.audiobookFirst =>
        clipUsable
            ? MangaLineAudioPlan.audiobookClip
            : MangaLineAudioPlan.synthesize,
      MangaAudioSourcePolicy.audiobookOnly =>
        clipUsable
            ? MangaLineAudioPlan.audiobookClip
            : MangaLineAudioPlan.silent,
    };
  }

  /// 片段实际指向的有声书 bookKey（旧行没有 `k` 时取第一本关联书）。
  String? clipBookKey(MangaAudiobookClip clip) =>
      clip.bookKey ??
      (audiobookSources.isEmpty ? null : audiobookSources.first);

  /// 某页的行（保持顺序）。
  List<MangaScriptLine> linesOnPage(int page) => <MangaScriptLine>[
    for (final MangaScriptLine l in lines)
      if (l.page == page) l,
  ];

  /// 会发声的行（去掉「不读」），时间表的输入用它。
  List<MangaScriptLine> get audibleLines => <MangaScriptLine>[
    for (final MangaScriptLine l in lines)
      if (l.kind.isAudible) l,
  ];

  /// 这卷所属系列的声音指派（`SeriesCastProfile.voices`，不随本文件落盘）。
  CastVoiceAssignment? series;

  /// 这卷所属系列的用词替换表（`SeriesCastProfile.substitutions`，不随本文件落盘）。
  /// 用于生成端实际念的文字与成品 cue 文本；AI 标注由 runner 接同一张表，有声书匹配仍看原文。单句
  /// 手动填写的念法（`say`）不替换。
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[];

  /// 一句该用的声音：单句指定 → 本卷指派表叠在系列上（见
  /// [CastVoiceAssignment.resolveOver]）；null = 当前朗读声音。
  String? voiceFor(MangaScriptLine line) =>
      line.voice ?? voices.resolveOver(line.speaker, line.kind, series);

  /// 「切配置重试」的候选声音（本卷在前、系列在后）。
  List<String> get retryVoices => voices.retryVoicesOver(series);

  /// 读盘时店里这卷的修订（见 [MangaAudioScriptStore.saveIfCurrent]），每次经店存盘
  /// 后更新；null = 不是从店里读出来的。只在内存里，不落盘。
  int? storeRevision;

  /// 行身份 → 在 [lines] 里的下标。[lines] 是公开可变列表（标注、重置都直接改它），
  /// 所以这份索引只当提示：命中后核对该位置确实是这一行，对不上就整份重建。
  Map<String, int>? _positions;

  int _indexOf(String lineId) {
    final int? at = _positions?[lineId];
    if (at != null && at < lines.length && lines[at].lineId == lineId) {
      return at;
    }
    final Map<String, int> rebuilt = <String, int>{};
    for (int i = 0; i < lines.length; i++) {
      rebuilt.putIfAbsent(lines[i].lineId, () => i);
    }
    _positions = rebuilt;
    return rebuilt[lineId] ?? -1;
  }

  /// 按行身份找行。
  MangaScriptLine? lineById(String lineId) {
    final int i = _indexOf(lineId);
    return i < 0 ? null : lines[i];
  }

  /// 替换一行（按行身份）；找不到返回 false。
  bool replaceLine(String lineId, MangaScriptLine Function(MangaScriptLine) f) {
    final int i = _indexOf(lineId);
    if (i < 0) return false;
    lines[i] = f(lines[i]);
    return true;
  }

  /// 与当前 OCR 签名比对（设计 §1：不一致整卷重新标注，不按坐标迁移）。
  MangaScriptFreshness freshness(String? currentEngineSignature) =>
      mangaScriptFreshness(
        scriptSignature: engineSignature,
        currentSignature: currentEngineSignature,
        hasLines: lines.isNotEmpty,
      );

  /// 并入 AI 对一页的标注：该页旧的 AI 行整体替换；用户改过的行保留，且与它们
  /// 共用块的 AI 新行丢弃（每块至多归一句）。用户行排在它所覆盖的第一条 AI 新行
  /// 的位置；没被任何新行覆盖的用户行按原页内位置插回。用户改过的页指令同样保留。
  void mergeAiPage(
    int page,
    List<MangaScriptLine> annotated, {
    MangaPageDirective? directive,
  }) {
    final List<MangaScriptLine> old = linesOnPage(page);
    final List<({int index, MangaScriptLine line})> userLines =
        <({int index, MangaScriptLine line})>[
          for (int i = 0; i < old.length; i++)
            if (old[i].source == TtsCastSource.user) (index: i, line: old[i]),
        ];
    final List<MangaScriptLine> merged = <MangaScriptLine>[];
    final Set<int> emitted = <int>{};
    for (final MangaScriptLine ai in annotated) {
      if (ai.page != page) continue;
      int? owner;
      for (int u = 0; u < userLines.length; u++) {
        if (userLines[u].line.blocks.any(ai.blocks.contains)) {
          owner = u;
          break;
        }
      }
      if (owner == null) {
        merged.add(ai);
      } else if (emitted.add(owner)) {
        merged.add(userLines[owner].line);
      }
    }
    for (int u = 0; u < userLines.length; u++) {
      if (emitted.contains(u)) continue;
      merged.insert(
        userLines[u].index.clamp(0, merged.length),
        userLines[u].line,
      );
    }
    lines.removeWhere((MangaScriptLine l) => l.page == page);
    final int at = lines.indexWhere((MangaScriptLine l) => l.page > page);
    lines.insertAll(at < 0 ? lines.length : at, merged);

    if (pages[page]?.source != TtsCastSource.user) {
      if (directive == null || directive.isEmpty) {
        pages.remove(page);
      } else {
        pages[page] = directive;
      }
    }
    annotatedPages.add(page);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ..._headJson(),
    'lines': <Object?>[for (final MangaScriptLine l in lines) l.toJson()],
  };

  /// 落盘用的 JSON 文本，与 `jsonEncode(toJson())` 等价；每行用缓存的
  /// [MangaScriptLine.jsonText]，逐句复核改一句只重新编码这一句。
  String encode() {
    final String head = jsonEncode(_headJson());
    final StringBuffer out = StringBuffer(head.substring(0, head.length - 1))
      ..write(',"lines":[');
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) out.write(',');
      out.write(lines[i].jsonText);
    }
    out.write(']}');
    return out.toString();
  }

  /// 除 `lines` 以外的字段（至少有 `v`，所以编码后不是空对象）。
  Map<String, Object?> _headJson() => <String, Object?>{
    'v': schemaVersion,
    if (engineSignature != null) 'ocr': engineSignature,
    'seed': defaultSeed,
    'voices': voices.toJson(),
    'policy': sourcePolicy.wire,
    'roster': <Object?>[
      for (final TtsCastCharacter c in roster.values) c.toJson(),
    ],
    'pages': <String, Object?>{
      for (final MapEntry<int, MangaPageDirective> e in pages.entries)
        '${e.key}': e.value.toJson(),
    },
    'annotated': annotatedPages.toList()..sort(),
    if (audiobookSources.isNotEmpty) 'books': audiobookSources,
  };

  static MangaAudioScript fromJson(Object? raw) {
    if (raw is! Map) return MangaAudioScript();
    final Object? roster = raw['roster'];
    final Object? lines = raw['lines'];
    final Object? pages = raw['pages'];
    final Object? annotated = raw['annotated'];
    final Object? seed = raw['seed'];
    final Object? signature = raw['ocr'];
    final Object? books = raw['books'];
    final List<MangaScriptLine> parsed = <MangaScriptLine>[
      if (lines is List)
        for (final Object? l in lines)
          if (MangaScriptLine.fromJson(l) case final MangaScriptLine line) line,
    ];
    final Map<int, MangaPageDirective> directives = <int, MangaPageDirective>{};
    if (pages is Map) {
      for (final MapEntry<Object?, Object?> e in pages.entries) {
        final int? page = int.tryParse('${e.key}');
        if (page != null && page >= 0) {
          directives[page] = MangaPageDirective.fromJson(e.value);
        }
      }
    }
    return MangaAudioScript(
      engineSignature: signature is String ? signature : null,
      defaultSeed: seed is int ? seed.clamp(0, MangaScriptLimits.maxSeed) : 0,
      voices: CastVoiceAssignment.fromJson(raw['voices']),
      sourcePolicy: MangaAudioSourcePolicy.parse(raw['policy']),
      roster: <String, TtsCastCharacter>{
        if (roster is List)
          for (final Object? r in roster)
            if (TtsCastCharacter.fromJson(r) case final TtsCastCharacter c)
              c.name: c,
      },
      // 落盘顺序就是阅读顺序；稳定排序只把跨页乱序（手改坏的文件）拉回页非降序。
      lines: _stableSortByPage(parsed),
      pages: directives,
      annotatedPages: <int>{
        if (annotated is List)
          for (final Object? v in annotated)
            if (v is int && v >= 0) v,
      },
      // 集合字面量保序去重（手改出来的重复书只留第一次出现）。
      audiobookSources: <String>{
        if (books is List)
          for (final Object? b in books)
            if (b is String && b.isNotEmpty) b,
      }.toList(),
    );
  }
}

List<MangaScriptLine> _stableSortByPage(List<MangaScriptLine> lines) {
  final List<(int, MangaScriptLine)> indexed = <(int, MangaScriptLine)>[
    for (int i = 0; i < lines.length; i++) (i, lines[i]),
  ];
  indexed.sort(((int, MangaScriptLine) a, (int, MangaScriptLine) b) {
    final int byPage = a.$2.page.compareTo(b.$2.page);
    return byPage != 0 ? byPage : a.$1.compareTo(b.$1);
  });
  return <MangaScriptLine>[
    for (final (int, MangaScriptLine) e in indexed) e.$2,
  ];
}

/// 每卷一份演出稿：`<root>/<sha1(bookKey)>.manga-script.json`。后缀与小说选角表
/// （`<sha1>.json`）不同，两者可以放在同一个目录里互不覆盖。
class MangaAudioScriptStore {
  MangaAudioScriptStore(this.root);

  final Directory root;

  File fileFor(String bookKey) => File(
    p.join(
      root.path,
      '${sha1.convert(utf8.encode(bookKey))}.manga-script.json',
    ),
  );

  /// 同一份演出稿文件在本进程里的读写闸与修订（按规范化路径）。店对象各处随用随建
  /// （`mangaAudioScriptStoreFor`），所以状态挂在静态表上，而不是实例上。
  static final Map<String, _ScriptFileState> _files =
      <String, _ScriptFileState>{};

  /// 同一卷的读写排成一队，按调用顺序执行：两次存盘不会同时写同一个临时文件，
  /// 读盘也不会夹在别人的「写临时文件 → 改名」中间。排队在调用当下同步发生，
  /// 先调用的先执行。[body] 的异常照常抛给调用方，只是不阻断后面排队的读写。
  Future<T> _serialized<T>(
    File f,
    Future<T> Function(_ScriptFileState state) body,
  ) {
    final _ScriptFileState state = _files.putIfAbsent(
      p.normalize(p.absolute(f.path)),
      _ScriptFileState.new,
    );
    final Future<T> run = state.tail.then((_) => body(state));
    state.tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  Future<MangaAudioScript> load(String bookKey) {
    final File f = fileFor(bookKey);
    return _serialized(f, (_ScriptFileState state) async {
      MangaAudioScript script;
      if (!await f.exists()) {
        script = MangaAudioScript();
      } else {
        try {
          script = MangaAudioScript.fromJson(
            jsonDecode(await f.readAsString()),
          );
        } on FormatException {
          await f.rename('${f.path}.corrupt');
          state.revision++;
          script = MangaAudioScript();
        }
      }
      return script..storeRevision = state.revision;
    });
  }

  /// 原子写：先写同目录临时文件并 flush，再 rename 覆盖。无条件覆盖盘上的稿子
  /// （标注任务、ctl 这类自己持有最新稿的写入方用）。界面上的会话（制作台、逐句复核）
  /// 读盘后可能被这些写入方抢先，一律走 [saveIfCurrent]。
  Future<void> save(String bookKey, MangaAudioScript script) {
    final File f = fileFor(bookKey);
    return _serialized(f, (_ScriptFileState state) => _write(f, state, script));
  }

  /// 只有 [script] 读盘（或上次经店存盘）之后本卷没被别处存过才写，返回是否写了。
  /// 拿着旧稿的会话（标注任务刚在后台改过这卷）因此不会把整份旧稿写回去盖掉新结果；
  /// 调用方拿到 false 应重读最新稿。
  Future<bool> saveIfCurrent(String bookKey, MangaAudioScript script) {
    final File f = fileFor(bookKey);
    return _serialized(f, (_ScriptFileState state) async {
      if (script.storeRevision == null ||
          script.storeRevision != state.revision) {
        return false;
      }
      await _write(f, state, script);
      return true;
    });
  }

  static Future<void> _write(
    File f,
    _ScriptFileState state,
    MangaAudioScript script,
  ) async {
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(script.encode(), flush: true);
    await tmp.rename(f.path);
    script.storeRevision = ++state.revision;
  }
}

class _ScriptFileState {
  /// 排在最后的一次读写（永不以错误结束）。
  Future<void> tail = Future<void>.value();

  /// 本进程里这份文件被写过几次。
  int revision = 0;
}
