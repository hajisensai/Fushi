import 'package:isar/isar.dart';

part 'audiobook_model.g.dart';

/// 有声书元数据。一本 EPUB 可挂载 0..1 个有声书。
@Collection()
class Audiobook {
  Id id = Isar.autoIncrement;

  /// 对应 MediaItem.uniqueKey（书的唯一标识）。
  @Index(unique: true, replace: true)
  late String bookUid;

  /// 音频文件目录（本地绝对路径）或 base URL。
  late String audioRoot;

  /// 对齐文件格式：'smil' | 'json' | 'lrc'。
  late String alignmentFormat;

  /// 对齐文件路径（本地绝对路径）。
  late String alignmentPath;
}

/// 单条对齐片段，粒度为句子级别。
///
/// 解析对齐文件后批量写入；运行时按 (bookUid, chapterHref) 查询并缓存。
@Collection()
class AudioCue {
  Id id = Isar.autoIncrement;

  /// 对应 [Audiobook.bookUid]。
  @Index()
  late String bookUid;

  /// EPUB spine item，例如 'OEBPS/ch01.xhtml'。
  @Index()
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
}
