import 'package:hibiki/src/database/database.dart';

/// 有声书元数据。一本 EPUB 可挂载 0..1 个有声书。
class Audiobook {
  int? id;

  /// 对应 MediaItem.uniqueKey（书的唯一标识）。
  late String bookUid;

  /// 音频文件目录（本地绝对路径）。folder 模式下非 null，files 模式下为 null。
  String? audioRoot;

  /// 手动选择的音频文件路径列表。files 模式下非 null，folder 模式下为 null。
  List<String>? audioPaths;

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
  /// 找不到"，"ttu IDB 未就绪" 等）。
  String? healthReason;

  /// PR8b "Follow audio" 开关的持久化状态。
  ///
  /// null / false：OFF —— cue 跨章时弹 pill "→ 第 N 章"，用户手点才跳。
  /// true：ON —— cue 跨章时自动调 __ttuGoToSection；用户手动翻页触发
  /// auto-off 回到 false。nullable 是为了旧记录读出来默认 OFF，不需迁移。
  bool? followAudio;
}

/// 单条对齐片段，粒度为句子级别。
///
/// 解析对齐文件后批量写入；运行时按 (bookUid, chapterHref) 查询并缓存。
class AudioCue {
  int? id;

  /// 对应 [Audiobook.bookUid]。
  late String bookUid;

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

  static AudioCue fromRow(AudioCueRow r) {
    final c = AudioCue();
    c.id = r.id;
    c.bookUid = r.bookUid;
    c.chapterHref = r.chapterHref;
    c.sentenceIndex = r.sentenceIndex;
    c.textFragmentId = r.textFragmentId;
    c.text = r.cueText;
    c.startMs = r.startMs;
    c.endMs = r.endMs;
    c.audioFileIndex = r.audioFileIndex;
    return c;
  }

  static AudioCuesCompanion toCompanion(AudioCue c) =>
      AudioCuesCompanion.insert(
        bookUid: c.bookUid,
        chapterHref: c.chapterHref,
        sentenceIndex: c.sentenceIndex,
        textFragmentId: c.textFragmentId,
        cueText: c.text,
        startMs: c.startMs,
        endMs: c.endMs,
        audioFileIndex: c.audioFileIndex,
      );
}
