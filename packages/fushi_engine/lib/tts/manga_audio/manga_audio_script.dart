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

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

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

/// 数值字段的取值范围；超出的值在解析 / 校验时夹到范围内（不丢行）。
abstract final class MangaScriptLimits {
  /// 一拍（句后额外停顿）上限，毫秒。
  static const int maxBeatMs = 10000;

  /// 情绪强度上限（下限 0）。
  static const int maxIntensity = 100;

  /// 语速偏移（倍率的增量：-0.5 = 慢一半，+1.0 = 快一倍）。
  static const double minRateOffset = -0.5;
  static const double maxRateOffset = 1.0;

  /// 音高偏移绝对值上限，半音。
  static const double maxPitchSemitones = 12;

  /// 音量偏移绝对值上限，dB。
  static const double maxVolumeDb = 12;

  /// 逐页 `hold` 上限，毫秒。
  static const int maxHoldMs = 60000;

  /// 逐页 `lead` 上限，毫秒。
  static const int maxLeadMs = 10000;

  /// 种子上限（32 位无符号，各引擎都能收）。
  static const int maxSeed = 0xFFFFFFFF;
}

// 有限数值才算数（NaN / 无穷当作没给）。
num? _finiteNum(Object? v) => v is num && v.isFinite ? v : null;

int? _intIn(Object? raw, int lo, int hi) {
  final num? v = _finiteNum(raw);
  return v?.round().clamp(lo, hi);
}

double? _doubleIn(Object? raw, double lo, double hi) {
  final num? v = _finiteNum(raw);
  return v?.toDouble().clamp(lo, hi);
}

/// 一句的音源：合成，或引用某本有声书里一段现成音频（不复制音频）。
sealed class MangaLineAudioSource {
  const MangaLineAudioSource();

  Map<String, Object?> toJson();

  static MangaLineAudioSource fromJson(Object? raw) {
    if (raw is Map && raw['t'] == MangaAudiobookClip.wireTag) {
      final Object? f = raw['f'];
      final Object? s = raw['s'];
      final Object? e = raw['e'];
      if (f is int && s is int && e is int && f >= 0 && s >= 0 && e > s) {
        return MangaAudiobookClip(fileIndex: f, startMs: s, endMs: e);
      }
    }
    return const MangaSynthesized();
  }
}

/// 按声音指派表合成（默认）。
final class MangaSynthesized extends MangaLineAudioSource {
  const MangaSynthesized();

  static const String wireTag = 'synth';

  @override
  Map<String, Object?> toJson() => const <String, Object?>{'t': wireTag};

  @override
  bool operator ==(Object other) => other is MangaSynthesized;

  @override
  int get hashCode => wireTag.hashCode;
}

/// 关联有声书里的一段：第 [fileIndex] 个音频文件的 `[startMs, endMs)`。
final class MangaAudiobookClip extends MangaLineAudioSource {
  const MangaAudiobookClip({
    required this.fileIndex,
    required this.startMs,
    required this.endMs,
  });

  static const String wireTag = 'book';

  final int fileIndex;
  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': wireTag,
    'f': fileIndex,
    's': startMs,
    'e': endMs,
  };

  @override
  bool operator ==(Object other) =>
      other is MangaAudiobookClip &&
      other.fileIndex == fileIndex &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(fileIndex, startMs, endMs);
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
  /// 音频文件名、未配音账本都按它。
  String get lineId => 'p${page}b${blocks.join('.')}';

  /// 这句实际用的种子。
  int effectiveSeed(int defaultSeed) => seed ?? defaultSeed;

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
    if (beatMs != 0) 'beat': beatMs,
    if (emotion != null) 'e': emotion!.wire,
    if (intensity != null) 'ei': intensity,
    if (rateOffset != null) 'rate': rateOffset,
    if (pitchOffset != null) 'pitch': pitchOffset,
    if (volumeOffset != null) 'vol': volumeOffset,
    if (seed != null) 'seed': seed,
    if (textFixes.isNotEmpty)
      'fix': <String, String>{
        for (final MapEntry<int, String> e in textFixes.entries)
          '${e.key}': e.value,
      },
    'src': source.name,
    if (confidence != null) 'c': confidence,
    if (audio is! MangaSynthesized) 'audio': audio.toJson(),
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
  final Object? seed = raw['seed'];
  return MangaScriptLine(
    page: page,
    blocks: blocks,
    speaker: speaker,
    kind: kind,
    beatMs: _intIn(raw['beat'], 0, MangaScriptLimits.maxBeatMs) ?? 0,
    emotion: emotion,
    intensity: emotion == null
        ? null
        : _intIn(raw['ei'], 0, MangaScriptLimits.maxIntensity),
    rateOffset: _doubleIn(
      raw['rate'],
      MangaScriptLimits.minRateOffset,
      MangaScriptLimits.maxRateOffset,
    ),
    pitchOffset: _doubleIn(
      raw['pitch'],
      -MangaScriptLimits.maxPitchSemitones,
      MangaScriptLimits.maxPitchSemitones,
    ),
    volumeOffset: _doubleIn(
      raw['vol'],
      -MangaScriptLimits.maxVolumeDb,
      MangaScriptLimits.maxVolumeDb,
    ),
    seed: seed is int ? seed.clamp(0, MangaScriptLimits.maxSeed) : null,
    textFixes: _parseFixes(raw['fix'], blocks),
    source:
        source ??
        (raw['src'] == TtsCastSource.user.name
            ? TtsCastSource.user
            : TtsCastSource.llm),
    confidence: _doubleIn(raw['c'], 0, 1),
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
      holdMs: _intIn(raw['hold'], 0, MangaScriptLimits.maxHoldMs),
      leadMs: _intIn(raw['lead'], 0, MangaScriptLimits.maxLeadMs),
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
  }) : voices = voices ?? CastVoiceAssignment(),
       roster = roster ?? <String, TtsCastCharacter>{},
       lines = lines ?? <MangaScriptLine>[],
       pages = pages ?? <int, MangaPageDirective>{},
       annotatedPages = annotatedPages ?? <int>{};

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

  /// 一句该用的声音：单句指定 → 本卷指派表叠在系列上（见
  /// [CastVoiceAssignment.resolveOver]）；null = 当前朗读声音。
  String? voiceFor(MangaScriptLine line) =>
      line.voice ?? voices.resolveOver(line.speaker, line.kind, series);

  /// 「切配置重试」的候选声音（本卷在前、系列在后）。
  List<String> get retryVoices => voices.retryVoicesOver(series);

  /// 按行身份找行。
  MangaScriptLine? lineById(String lineId) {
    for (final MangaScriptLine l in lines) {
      if (l.lineId == lineId) return l;
    }
    return null;
  }

  /// 替换一行（按行身份）；找不到返回 false。
  bool replaceLine(String lineId, MangaScriptLine Function(MangaScriptLine) f) {
    final int i = lines.indexWhere((MangaScriptLine l) => l.lineId == lineId);
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
    'v': schemaVersion,
    if (engineSignature != null) 'ocr': engineSignature,
    'seed': defaultSeed,
    'voices': voices.toJson(),
    'policy': sourcePolicy.wire,
    'roster': <Object?>[
      for (final TtsCastCharacter c in roster.values) c.toJson(),
    ],
    'lines': <Object?>[for (final MangaScriptLine l in lines) l.toJson()],
    'pages': <String, Object?>{
      for (final MapEntry<int, MangaPageDirective> e in pages.entries)
        '${e.key}': e.value.toJson(),
    },
    'annotated': annotatedPages.toList()..sort(),
  };

  static MangaAudioScript fromJson(Object? raw) {
    if (raw is! Map) return MangaAudioScript();
    final Object? roster = raw['roster'];
    final Object? lines = raw['lines'];
    final Object? pages = raw['pages'];
    final Object? annotated = raw['annotated'];
    final Object? seed = raw['seed'];
    final Object? signature = raw['ocr'];
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

  Future<MangaAudioScript> load(String bookKey) async {
    final File f = fileFor(bookKey);
    if (!await f.exists()) return MangaAudioScript();
    try {
      return MangaAudioScript.fromJson(jsonDecode(await f.readAsString()));
    } on FormatException {
      await f.rename('${f.path}.corrupt');
      return MangaAudioScript();
    }
  }

  /// 原子写：先写同目录临时文件并 flush，再 rename 覆盖。
  Future<void> save(String bookKey, MangaAudioScript script) async {
    final File f = fileFor(bookKey);
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(script.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}
