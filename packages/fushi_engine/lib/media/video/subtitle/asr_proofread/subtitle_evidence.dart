/// 字幕管线的「证据」：同一视频身边已有、但不完全可用的字幕（外挂 / 内嵌文字字幕、
/// 图形字幕 OCR），以及它们在识别稿各行上的时间重叠查询。设计见
/// `docs/specs/2026-11-04-video-subtitle-multisource-evidence.md` §1。
///
/// - 同语言（目标语言，通常是日语）证据：S3 校对时优先采用其写法；识别漏掉的行由
///   缺口补齐插回（`subtitle_evidence_fusion.dart`）。
/// - 他言語证据：只给 S3 当判断人名 / 用语 / 意思的依据（校对规则 1、5）。
///
/// 纯函数，不碰文件系统；收集见 `subtitle_evidence_loader.dart`。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer.dart';

/// 证据的来源种类。
enum SubtitleEvidenceKind {
  /// 人写的文字字幕（SRT / ASS / VTT，外挂或内嵌）。
  text,

  /// 图形字幕（PGS / VobSub / DVB）的 OCR 结果：字形近似的字可能认错。
  ocr;

  static SubtitleEvidenceKind? fromName(Object? name) {
    for (final SubtitleEvidenceKind k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// 一行证据在画面上的角色。
enum SubtitleEvidenceRole {
  /// 台词。
  dialogue,

  /// 招牌 / 标题 / 注释等排版（带定位、绘图）：不是台词，不参与校对与补齐。
  sign,

  /// 歌词（OP / ED / 插曲、卡拉 OK 行）：歌词补齐用。
  song;

  static SubtitleEvidenceRole fromName(Object? name) {
    for (final SubtitleEvidenceRole r in values) {
      if (r.name == name) return r;
    }
    return dialogue;
  }
}

/// 一行证据。
class SubtitleEvidenceCue {
  const SubtitleEvidenceCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.role = SubtitleEvidenceRole.dialogue,
  });

  factory SubtitleEvidenceCue.fromJson(Map<String, Object?> json) =>
      SubtitleEvidenceCue(
        startMs: (json['s'] as num).round(),
        endMs: (json['e'] as num).round(),
        text: json['t'] as String? ?? '',
        role: SubtitleEvidenceRole.fromName(json['r']),
      );

  final int startMs;
  final int endMs;

  /// 纯文本（已去掉覆盖标签；多行用 `\n`）。
  final String text;
  final SubtitleEvidenceRole role;

  Map<String, Object?> toJson() => <String, Object?>{
    's': startMs,
    'e': endMs,
    't': text,
    if (role != SubtitleEvidenceRole.dialogue) 'r': role.name,
  };
}

/// 一条证据轨。时间轴一律可信（与视频同步）：内嵌轨与视频同容器；外挂轨只有按识别稿
/// 对齐成功（`autoApply`）的才会被收集器收进来（`subtitle_evidence_loader.dart`），
/// 所以下游可以直接按时间取行。
class SubtitleEvidenceTrack {
  const SubtitleEvidenceTrack({
    required this.label,
    required this.kind,
    required this.cues,
    this.language,
  });

  factory SubtitleEvidenceTrack.fromJson(Map<String, Object?> json) =>
      SubtitleEvidenceTrack(
        label: json['label'] as String? ?? '',
        kind:
            SubtitleEvidenceKind.fromName(json['kind']) ??
            SubtitleEvidenceKind.text,
        language: json['language'] as String?,
        cues: <SubtitleEvidenceCue>[
          for (final Object? c
              in (json['cues'] as List<Object?>? ?? const <Object?>[]))
            if (c is Map)
              SubtitleEvidenceCue.fromJson(c.cast<String, Object?>()),
        ],
      );

  /// 给提示词 / 日志看的来源（文件名或内嵌轨标签）。
  final String label;
  final SubtitleEvidenceKind kind;

  /// 归一化的语言（`ja` / `en` / `zh` / `ko` …）；判不出为 null。
  final String? language;

  /// 按开始时间升序。
  final List<SubtitleEvidenceCue> cues;

  int get dialogueCount => cues
      .where((SubtitleEvidenceCue c) => c.role == SubtitleEvidenceRole.dialogue)
      .length;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'kind': kind.name,
    if (language != null) 'language': language,
    'cues': <Map<String, Object?>>[
      for (final SubtitleEvidenceCue c in cues) c.toJson(),
    ],
  };
}

/// 一组证据轨 → JSON（`evidence.json` 的 `tracks`）。
List<Map<String, Object?>> encodeSubtitleEvidenceTracks(
  List<SubtitleEvidenceTrack> tracks,
) => <Map<String, Object?>>[
  for (final SubtitleEvidenceTrack t in tracks) t.toJson(),
];

/// [encodeSubtitleEvidenceTracks] 的逆。
List<SubtitleEvidenceTrack> decodeSubtitleEvidenceTracks(
  Object? json,
) => <SubtitleEvidenceTrack>[
  if (json is List)
    for (final Object? t in json)
      if (t is Map) SubtitleEvidenceTrack.fromJson(t.cast<String, Object?>()),
];

/// 证据内容的指纹：S3 的批缓存与 `final.json` 都绑在它上（证据变了要重新校对）。
/// 没有证据 → 空串（与改版前的缓存兼容）。
String subtitleEvidenceFingerprint(List<SubtitleEvidenceTrack> tracks) {
  if (tracks.isEmpty) return '';
  return sha1
      .convert(utf8.encode(jsonEncode(encodeSubtitleEvidenceTracks(tracks))))
      .toString();
}

// ---------------------------------------------------------------------------
// 语言
// ---------------------------------------------------------------------------

final RegExp _kana = RegExp(
  r'[\u3040-\u309F\u30A0-\u30FF\u31F0-\u31FF\uFF66-\uFF9F]',
);
final RegExp _han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
final RegExp _hangul = RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]');
final RegExp _cyrillic = RegExp(r'[\u0400-\u04FF]');
final RegExp _thai = RegExp(r'[\u0E00-\u0E7F]');
final RegExp _arabic = RegExp(r'[\u0600-\u06FF]');
final RegExp _latin = RegExp(r'[A-Za-z\u00C0-\u024F]');

/// 按书写系统判一批文字的语言：假名占汉字 + 假名的 ≥ 8% → `ja`；谚文 → `ko`；只有汉字
/// → `zh`；西里尔 → `ru`；泰文 → `th`；阿拉伯 → `ar`；拉丁 → `en`（拉丁系语言之间分不出，
/// 交给来源标签）。字太少 → null。
String? detectSubtitleTextLanguage(Iterable<String> lines) {
  int kana = 0, han = 0, hangul = 0, cyr = 0, thai = 0, arabic = 0, latin = 0;
  for (final String line in lines) {
    kana += _kana.allMatches(line).length;
    han += _han.allMatches(line).length;
    hangul += _hangul.allMatches(line).length;
    cyr += _cyrillic.allMatches(line).length;
    thai += _thai.allMatches(line).length;
    arabic += _arabic.allMatches(line).length;
    latin += _latin.allMatches(line).length;
  }
  final int cjk = kana + han;
  final List<(String, int)> scripts = <(String, int)>[
    ('cjk', cjk),
    ('ko', hangul),
    ('ru', cyr),
    ('th', thai),
    ('ar', arabic),
    // 拉丁字母一个词好几个字符：按 1/3 折算，免得中日字幕里夹的英文把它压过去。
    ('en', latin ~/ 3),
  ]..sort(((String, int) a, (String, int) b) => b.$2.compareTo(a.$2));
  final (String top, int count) = scripts.first;
  if (count < 8) return null;
  if (top != 'cjk') return top;
  return kana >= cjk * 0.08 ? 'ja' : 'zh';
}

/// 来源标签（文件名后缀 / 内嵌轨 language，已归一化）与文字判定合成最终语言：文字
/// 判得出就信文字（字幕组常把轨标错），拉丁系只判得出 `en` 时信标签（法 / 德 / 西…）。
String? resolveSubtitleEvidenceLanguage({
  required String? tagged,
  required String? detected,
}) {
  if (detected == null) return tagged;
  if (detected == 'en' &&
      tagged != null &&
      !_nonLatinLanguages.contains(tagged)) {
    return tagged;
  }
  return detected;
}

const Set<String> _nonLatinLanguages = <String>{
  'ja',
  'zh',
  'ko',
  'ru',
  'th',
  'ar',
  'uk',
  'el',
  'he',
  'hi',
};

/// 两种语言是否算「同语言」（`zh-Hans` / `zh-Hant` 等按主标签比）。
bool sameSubtitleLanguage(String? a, String? b) {
  if (a == null || b == null) return false;
  String primary(String s) => s.toLowerCase().split(RegExp('[-_]')).first;
  return primary(a) == primary(b);
}

// ---------------------------------------------------------------------------
// 角色分类
// ---------------------------------------------------------------------------

/// 样式名 / Name / Effect 命中这些就是歌词（OP / ED / 插曲 / 卡拉 OK）；与 ASS 导出
/// 判歌词行共用一份（`subtitle_ass_style_transfer.dart`）。
final RegExp _songStyle = assSongStylePattern;
final RegExp _karaokeTag = assKaraokeTagPattern;
final RegExp _songMark = RegExp(r'^[\s　]*[♪♫♬〜～]');

/// ASS 事件的角色：排版（定位 / 绘图）→ sign；样式像歌 / 带 `\k` → song；其余台词。
SubtitleEvidenceRole classifyAssEvidenceEvent(AssReferenceEvent event) {
  if (event.isDrawing || event.isPositioned) return SubtitleEvidenceRole.sign;
  if (_karaokeTag.hasMatch(event.text)) return SubtitleEvidenceRole.song;
  if (_songStyle.hasMatch(event.style) ||
      _songStyle.hasMatch(event.name) ||
      _songStyle.hasMatch(event.effect)) {
    return SubtitleEvidenceRole.song;
  }
  return _songMark.hasMatch(event.plainText)
      ? SubtitleEvidenceRole.song
      : SubtitleEvidenceRole.dialogue;
}

/// 纯文本格式（SRT / VTT / OCR）一行的角色：`♪` 起头是歌词，其余台词。
SubtitleEvidenceRole classifyPlainEvidenceText(String text) =>
    _songMark.hasMatch(text)
    ? SubtitleEvidenceRole.song
    : SubtitleEvidenceRole.dialogue;

/// 解析好的 ASS → 证据行（同一时刻同文的重复层合并；绘图 / 空行已被解析器去掉）。
List<SubtitleEvidenceCue> evidenceCuesFromAss(AssStyleReference reference) {
  final List<SubtitleEvidenceCue> out = <SubtitleEvidenceCue>[];
  final Set<String> seen = <String>{};
  for (final AssReferenceEvent e in reference.events) {
    final String text = e.plainText.trim();
    if (text.isEmpty || e.endMs <= e.startMs) continue;
    // 字幕组常把同一句画两层（描边层 + 正文层）：同起止同文只留一条。
    if (!seen.add('${e.startMs}|${e.endMs}|$text')) continue;
    out.add(
      SubtitleEvidenceCue(
        startMs: e.startMs,
        endMs: e.endMs,
        text: text,
        role: classifyAssEvidenceEvent(e),
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// 时间重叠查询
// ---------------------------------------------------------------------------

/// 一次查询的结果：某条识别稿同时段的证据。
class SubtitleEvidenceMatch {
  const SubtitleEvidenceMatch({required this.track, required this.text});

  final SubtitleEvidenceTrack track;

  /// 重叠的证据行按时间拼接（`／` 分隔）。
  final String text;
}

/// 两段时间的重叠毫秒数（不重叠为 0）。
int subtitleOverlapMs(int aStart, int aEnd, int bStart, int bEnd) {
  final int lo = aStart > bStart ? aStart : bStart;
  final int hi = aEnd < bEnd ? aEnd : bEnd;
  return hi > lo ? hi - lo : 0;
}

/// 证据索引：从全部证据轨里每种语言挑一条最好的轨，按时间查。
class SubtitleEvidenceIndex {
  SubtitleEvidenceIndex(
    List<SubtitleEvidenceTrack> tracks, {
    required this.targetLanguage,
    this.maxOtherLanguages = 2,
  }) : same = _pickSame(tracks, targetLanguage),
       others = _pickOthers(tracks, targetLanguage, maxOtherLanguages);

  /// 目标语言（管线的字幕后缀，通常 `ja`）。
  final String targetLanguage;
  final int maxOtherLanguages;

  /// 同语言证据轨（人工字幕优先于 OCR，再按台词行数）；可能有 0~2 条（一条人工 + 一条
  /// OCR 时两条都给：两种错误互相校正）。
  final List<SubtitleEvidenceTrack> same;

  /// 他言語证据轨（每种语言一条，英 / 中优先，最多 [maxOtherLanguages] 条）。
  final List<SubtitleEvidenceTrack> others;

  bool get isEmpty => same.isEmpty && others.isEmpty;

  /// [startMs, endMs] 同时段的台词证据（同语言在前）。重叠至少占证据行或识别行较短
  /// 一方的 30% 才算（擦边的前后句不给，免得误导校对）。
  List<SubtitleEvidenceMatch> matchesFor(int startMs, int endMs) =>
      <SubtitleEvidenceMatch>[
        for (final SubtitleEvidenceTrack t in <SubtitleEvidenceTrack>[
          ...same,
          ...others,
        ])
          if (_overlapText(t, startMs, endMs) case final String text)
            SubtitleEvidenceMatch(track: t, text: text),
      ];

  static String? _overlapText(
    SubtitleEvidenceTrack track,
    int startMs,
    int endMs,
  ) {
    final List<String> parts = <String>[];
    for (final SubtitleEvidenceCue c in track.cues) {
      if (c.startMs >= endMs) break;
      if (c.role != SubtitleEvidenceRole.dialogue) continue;
      final int overlap = subtitleOverlapMs(startMs, endMs, c.startMs, c.endMs);
      if (overlap <= 0) continue;
      final int shorter = (endMs - startMs) < (c.endMs - c.startMs)
          ? endMs - startMs
          : c.endMs - c.startMs;
      if (shorter <= 0 || overlap < shorter * 0.3) continue;
      final String text = c.text.replaceAll('\n', ' ').trim();
      if (text.isNotEmpty && !parts.contains(text)) parts.add(text);
    }
    return parts.isEmpty ? null : parts.join('／');
  }

  static List<SubtitleEvidenceTrack> _pickSame(
    List<SubtitleEvidenceTrack> tracks,
    String target,
  ) {
    SubtitleEvidenceTrack? best(SubtitleEvidenceKind kind) {
      SubtitleEvidenceTrack? pick;
      for (final SubtitleEvidenceTrack t in tracks) {
        if (t.kind != kind || !sameSubtitleLanguage(t.language, target)) {
          continue;
        }
        if (t.dialogueCount == 0) continue;
        if (pick == null || t.dialogueCount > pick.dialogueCount) pick = t;
      }
      return pick;
    }

    return <SubtitleEvidenceTrack>[
      ?best(SubtitleEvidenceKind.text),
      ?best(SubtitleEvidenceKind.ocr),
    ];
  }

  static List<SubtitleEvidenceTrack> _pickOthers(
    List<SubtitleEvidenceTrack> tracks,
    String target,
    int max,
  ) {
    final Map<String, SubtitleEvidenceTrack> byLanguage =
        <String, SubtitleEvidenceTrack>{};
    for (final SubtitleEvidenceTrack t in tracks) {
      final String? lang = t.language;
      if (lang == null || sameSubtitleLanguage(lang, target)) continue;
      if (t.dialogueCount == 0) continue;
      final String key = lang.toLowerCase().split(RegExp('[-_]')).first;
      final SubtitleEvidenceTrack? old = byLanguage[key];
      // 同语言里人工字幕优先，再比台词行数。
      if (old == null ||
          (old.kind == SubtitleEvidenceKind.ocr &&
              t.kind == SubtitleEvidenceKind.text) ||
          (old.kind == t.kind && t.dialogueCount > old.dialogueCount)) {
        byLanguage[key] = t;
      }
    }
    int rank(String lang) => switch (lang) {
      'en' => 0,
      'zh' => 1,
      _ => 2,
    };
    final List<String> keys = byLanguage.keys.toList()
      ..sort((String a, String b) {
        final int c = rank(a).compareTo(rank(b));
        return c != 0
            ? c
            : byLanguage[b]!.dialogueCount.compareTo(
                byLanguage[a]!.dialogueCount,
              );
      });
    return <SubtitleEvidenceTrack>[
      for (final String k in keys.take(max)) byLanguage[k]!,
    ];
  }
}
