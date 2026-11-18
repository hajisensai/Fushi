import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import '../parsers/subtitle_markup.dart';
import 'audiobook_health.dart' show HealthKind;

/// 有声书元数据。一本 EPUB 可挂载 0..1 个有声书。
class Audiobook {
  int? id;

  /// 书的唯一标识 = EpubBooks.bookKey（sanitize 后的标题）。
  late String bookKey;

  /// 音频文件目录（本地绝对路径）。folder 模式下非 null，files 模式下为 null。
  String? audioRoot;

  /// 手动选择的音频文件路径列表。files 模式下非 null，folder 模式下为 null。
  List<String>? audioPaths;

  List<String>? get audioPathsInCueOrder {
    final List<String>? paths = audioPaths;
    if (paths == null) return null;
    return List<String>.unmodifiable(paths);
  }

  List<File> get audioFilesInCueOrder =>
      (audioPathsInCueOrder ?? const <String>[]).map(File.new).toList();

  /// 对齐文件格式：'smil' | 'json' | 'lrc'。
  late String alignmentFormat;

  /// 对齐文件路径（本地绝对路径）。
  late String alignmentPath;

  // ── PR2 健康度指标 ────────────────────────────────────────────────────────
  // 所有字段 nullable：旧记录读出来 kind 回退为 unrun，不需要迁移脚本。
  // 语义见 [AudiobookHealth] / [HealthKind]；UI 侧永远 switch(kind)，
  // 不直接读 matchRatePct。

  /// [HealthKind] 的 name（持久化为字符串，枚举不稳定，用名字更稳）。
  String? healthKindRaw;

  /// 0..100 的匹配率。仅当 kind ∈ {ok, partial} 时有意义。
  int? matchRatePct;

  /// health 计算时间，用于"指标过期 → 重跑"判断。
  DateTime? healthMeasuredAt;

  /// partial/failed 时的人话解释，直接展示给用户（"3 章 SMIL fragment
  /// 找不到"，"EPUB 数据库未就绪" 等）。
  String? healthReason;

  /// PR8b "Follow audio" 开关的持久化状态。
  ///
  /// null / false：OFF —— cue 跨章时弹 pill "→ 第 N 章"，用户手点才跳。
  /// true：ON —— cue 跨章时自动调 __ttuGoToSection；用户手动翻页触发
  /// auto-off 回到 false。nullable 是为了旧记录读出来默认 OFF，不需迁移。
  bool? followAudio;
}

/// 一条 cue 的逐 token 发射时间：[tokens] 拼接即 cue 的听写文本，
/// [offsetsMs] 是各 token 相对 **cue 起点** 的发射时刻（RNN-T 发射偏晚，
/// 首 token 可能略晚于 cue 起点；cue 起点被前一条挤后时可为负）。
class CueTokenTiming {
  CueTokenTiming({required this.tokens, required this.offsetsMs})
    : assert(tokens.length == offsetsMs.length);

  final List<String> tokens;
  final List<int> offsetsMs;

  int get length => tokens.length;
  bool get isEmpty => tokens.isEmpty;

  /// 落库形态（`audio_cues.token_timing_json`，v160）：与转录 sidecar 一行同形的
  /// `{"t":[...],"o":[...]}`。
  String toJson() => jsonEncode(<String, Object?>{'t': tokens, 'o': offsetsMs});

  /// [toJson] 的逆。null / 空串 = 没有逐 token 时间；内容坏了（不是对象、两列不等长、
  /// 类型不对）也按没有处理——这是可再生的派生数据，坏一条不该挡住整本书读 cue，
  /// 而挂一份对不上的时间比没有更糟（半句会裁到别处）。
  static CueTokenTiming? tryParseJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Object? t = decoded['t'];
    final Object? o = decoded['o'];
    if (t is! List || o is! List || t.length != o.length) return null;
    if (t.any((Object? e) => e is! String) || o.any((Object? e) => e is! int)) {
      return null;
    }
    return CueTokenTiming(
      tokens: List<String>.unmodifiable(t.cast<String>()),
      offsetsMs: List<int>.unmodifiable(o.cast<int>()),
    );
  }
}

/// 单条对齐片段，粒度为句子级别。
///
/// 解析对齐文件后批量写入；运行时按 (bookUid, chapterHref) 查询并缓存。
class AudioCue {
  int? id;

  /// 对应 [Audiobook.bookKey]（或 standalone SRT 的 uid）。
  late String bookKey;

  /// EPUB spine item，例如 'OEBPS/ch01.xhtml'。
  late String chapterHref;

  /// 章节内句序（0-based）。
  late int sentenceIndex;

  /// DOM id 或 CSS selector，用于 WebView 高亮定位。
  /// 例如 '#s1' 或 '#p1 > span:nth-child(2)'。
  late String textFragmentId;

  /// 原文文本（用于模糊兜底匹配）。
  late String text;

  /// 片段开始时间（毫秒），相对于当前音频文件。
  late int startMs;

  /// 片段结束时间（毫秒），相对于当前音频文件。
  late int endMs;

  /// 多段音频时的文件下标（对应 [Audiobook] audioRoot 下按名称排序的文件列表）。
  late int audioFileIndex;

  /// 解析时附带的行内样式 markup（仅视频字幕渲染用，瞬态、不持久化）。
  /// 由各文本字幕 parser 在 [parseSubtitleMarkup] 后填充；DB 往返不携带。
  SubtitleMarkup? markup;

  /// 设备端转录产物附带的逐 token 发射时间。导入链路从转录任务目录的 sidecar
  /// 挂上来，供匹配后按正文句界重切 cue（`cue_sentence_resegmenter.dart`）；重切 /
  /// 后处理会同步改写它，所以落库的是**与本条 cue 最终边界一致**的那份
  /// （`audio_cues.token_timing_json`，v160），运行时（漫画台词半句命中按 token
  /// 裁区间）从库里读回。sidecar 按原始转录行号排，与库里重切后的 cue 对不上，
  /// 不能拿来事后补挂。非转录字幕、v160 之前匹配的书为 null（重新匹配才有）。
  CueTokenTiming? tokenTiming;

  /// 用户手改字幕前的那条原 cue（瞬态、不持久化）。null = 这句没被改过，[text] 就是
  /// 原文；非 null 时本 cue 是改后副本（[text] 为用户文本，显示 / 查词 / 制卡都用它），
  /// 原 cue 原样留着（含样式 markup）供还原与覆盖命中（视频字幕文本覆盖层
  /// `subtitle_text_override.dart`）。
  AudioCue? uneditedCue;

  /// 字幕源里的原文：被手改过时取 [uneditedCue] 的文本，否则就是 [text]。
  String get sourceText => uneditedCue?.text ?? text;

  /// 渲染专用 cue：无可读正文、只有 ASS `\p` 矢量绘图（招牌白底遮罩等）。它只该被
  /// 视频 overlay 画出来——不进字幕列表 / 跳句 / 制卡 / 句尾暂停，也不落库
  /// （`VideoBookRepository.saveCues` 过滤）。由 `AssParser.parseString(includeDrawings:
  /// true)` 产出，其余解析路径默认不产出。
  bool get isRenderOnly => text.isEmpty && markup?.drawing != null;

  /// 特效字幕（歌词特效 / 屏幕字，H7r4mf_z2n）：解析层标出的 [SubtitleMarkup.isEffect]；
  /// 没有 markup（落库往返、外部转录）恒为 false。手改过的 cue 的 markup 由
  /// `subtitle_text_override.dart` 沿用原 cue 的标志。
  bool get isEffect => markup?.isEffect ?? false;

  File? resolveAudioFile(List<File> audioFiles) {
    if (audioFileIndex < 0 || audioFileIndex >= audioFiles.length) {
      return null;
    }
    return audioFiles[audioFileIndex];
  }

  static AudioCue fromRow(AudioCueRow r) {
    final c = AudioCue();
    c.id = r.id;
    c.bookKey = r.bookKey;
    c.chapterHref = r.chapterHref;
    c.sentenceIndex = r.sentenceIndex;
    c.textFragmentId = r.textFragmentId;
    c.text = r.cueText;
    c.startMs = r.startMs;
    c.endMs = r.endMs;
    c.audioFileIndex = r.audioFileIndex;
    c.tokenTiming = CueTokenTiming.tryParseJson(r.tokenTimingJson);
    return c;
  }

  static AudioCuesCompanion toCompanion(AudioCue c) =>
      AudioCuesCompanion.insert(
        bookKey: c.bookKey,
        chapterHref: c.chapterHref,
        sentenceIndex: c.sentenceIndex,
        textFragmentId: c.textFragmentId,
        // 落库的永远是字幕源的原文：手改文本是另一层覆盖，不写进 cue 表。
        cueText: c.sourceText,
        startMs: c.startMs,
        endMs: c.endMs,
        audioFileIndex: c.audioFileIndex,
        tokenTimingJson: Value(_tokenTimingJsonFor(c)),
      );

  /// 与 `cueText` 同口径取字幕源那条：手改过的 cue 落库的是原文（[sourceText]），
  /// 改后副本的时间已被清掉（`subtitle_text_override.dart`），存原 cue 的那份。
  /// 空 token 列表不存。
  static String? _tokenTimingJsonFor(AudioCue c) {
    final CueTokenTiming? t = (c.uneditedCue ?? c).tokenTiming;
    if (t == null || t.isEmpty || t.tokens.length != t.offsetsMs.length) {
      return null;
    }
    return t.toJson();
  }
}
