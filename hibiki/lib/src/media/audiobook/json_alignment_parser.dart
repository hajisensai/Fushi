import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/text_file_io.dart';

/// 解析自定义 JSON 对齐文件，产出 [AudioCue] 列表。
///
/// JSON 格式示例：
/// ```json
/// {
///   "bookUid": "reader/path/to/book.epub",
///   "audio": ["audio/ch01.mp3", "audio/ch02.mp3"],
///   "cues": [
///     {
///       "chapter": "ch01.xhtml",
///       "i": 0,
///       "selector": "#p1 > span:nth-child(1)",
///       "start": 0,
///       "end": 4230,
///       "file": 0,
///       "text": "吾輩は猫である。"
///     }
///   ]
/// }
/// ```
class JsonAlignmentParser {
  /// 读取 [jsonFile] 并返回所有 [AudioCue]。
  ///
  /// 走 [readTextWithEncoding] 自动识别编码，以防对齐 JSON 被用 CP932 保存。
  ///
  /// [bookUid] 用于覆盖 JSON 中的 bookUid 字段（以实际加载的书为准）。
  static Future<List<AudioCue>> parse({
    required File jsonFile,
    required String bookUid,
  }) async {
    final String content = await readTextWithEncoding(jsonFile);
    return parseString(content: content, bookUid: bookUid);
  }

  /// 解析 JSON 对齐字符串并返回所有 [AudioCue]。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookUid,
  }) {
    final Map<String, dynamic> json =
        jsonDecode(content) as Map<String, dynamic>;

    final List<dynamic> rawCues = json['cues'] as List<dynamic>? ?? [];

    final List<AudioCue> cues = [];

    for (final dynamic raw in rawCues) {
      final Map<String, dynamic> c = raw as Map<String, dynamic>;

      final String chapter = c['chapter'] as String? ?? '';
      final int sentenceIndex = c['i'] as int? ?? 0;
      final String selector = c['selector'] as String? ?? '';
      final int startMs = c['start'] as int? ?? 0;
      final int endMs = c['end'] as int? ?? 0;
      final int fileIndex = c['file'] as int? ?? 0;
      final String text = c['text'] as String? ?? '';

      final AudioCue cue = AudioCue()
        ..bookUid = bookUid
        ..chapterHref = chapter
        ..sentenceIndex = sentenceIndex
        ..textFragmentId = selector
        ..text = text
        ..startMs = startMs
        ..endMs = endMs
        ..audioFileIndex = fileIndex;

      cues.add(cue);
    }

    return cues;
  }

  /// 从 [AudioCue] 列表中提取指定章节的 cues，按 sentenceIndex 排序。
  static List<AudioCue> cuesForChapter({
    required List<AudioCue> allCues,
    required String chapterHref,
  }) {
    return allCues
        .where((c) => c.chapterHref == chapterHref)
        .toList()
      ..sort((a, b) => a.sentenceIndex.compareTo(b.sentenceIndex));
  }

  /// 二分查找：返回 [positionMs] 所处或最近播放过的 cue 下标。
  ///
  /// 策略为 "sustain"：返回满足 `startMs <= positionMs` 的最后一条 cue。
  /// SRT 字幕两条 cue 之间普遍有 gap，若严格要求 `positionMs <= endMs`，在 gap
  /// 期间高亮会被清除、滚动会停止，体验是"语句消失然后又出现"。改为 sustain
  /// 后，gap 期间保持上一句高亮，直到下一句 startMs 抵达。
  ///
  /// 要求 [cues] 已按 startMs 升序排序（即 sentenceIndex 顺序）。
  /// [positionMs] 早于第一条 cue 时返回 -1。
  static int findCueIndex({
    required List<AudioCue> cues,
    required int positionMs,
  }) {
    if (cues.isEmpty) {
      return -1;
    }

    int lo = 0;
    int hi = cues.length - 1;
    int result = -1;

    while (lo <= hi) {
      final int mid = (lo + hi) ~/ 2;
      if (cues[mid].startMs <= positionMs) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }

    return result;
  }
}
