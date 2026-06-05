import 'dart:convert';
import 'dart:io';

import '../audiobook/audiobook_model.dart';
import 'text_file_io.dart';

/// 解析自定义 JSON 对齐文件，产出 [AudioCue] 列表。
///
/// JSON 格式示例：
/// ```json
/// {
///   "bookKey": "reader/path/to/book.epub",
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
  /// [bookKey] 用于覆盖 JSON 中的 bookKey 字段（以实际加载的书为准）。
  static Future<List<AudioCue>> parse({
    required File jsonFile,
    required String bookKey,
  }) async {
    final String content = await readTextWithEncoding(jsonFile);
    return parseString(content: content, bookKey: bookKey);
  }

  /// 解析 JSON 对齐字符串并返回所有 [AudioCue]。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
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
        ..bookKey = bookKey
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
    return allCues.where((c) => c.chapterHref == chapterHref).toList()
      ..sort((a, b) => a.sentenceIndex.compareTo(b.sentenceIndex));
  }

  /// 二分查找：返回 [positionMs] 落在其闭区间 `[startMs, endMs]` 内的 cue 下标。
  ///
  /// HBK-AUDIT-153：endMs 是 **inclusive** 的——`positionMs == prev.endMs` 仍
  /// 返回 prev（见 `findCueIndex` 测试 'position at endMs returns that cue'）。
  /// 静音 gap 因此为 `prev.endMs < positionMs < next.startMs`，落入 gap 返回
  /// -1 让上层清高亮。这与上游 Sasayaki `CueTimeline.cue(at:)` 仅在 endMs 这
  /// 1ms 边界点上有差异（上游 exclusive），不可感知，故保留闭区间契约并与文档
  /// 对齐，避免无意义地翻转行为破坏既有测试。
  /// 旧实现曾采用 "sustain"（gap 保持上一句）避免 SRT 字幕轻微抖动，但会让
  /// 重复短句在 cue 切换时因 `textFragmentId` 相同而 `_updateCurrentCue`
  /// 短路，表现为"高亮偶尔不出现"。
  ///
  /// 要求 [cues] 已按 startMs 升序排序。[positionMs] 早于第一条 cue 时返回 -1。
  static int findCueIndex({
    required List<AudioCue> cues,
    required int positionMs,
  }) {
    if (cues.isEmpty) return -1;

    // 二分找第一条 startMs >= positionMs 的 cue。
    int lo = 0;
    int hi = cues.length;
    while (lo < hi) {
      final int mid = (lo + hi) >>> 1;
      if (cues[mid].startMs < positionMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    // 精确命中 startMs：返回该 cue。
    if (lo < cues.length && cues[lo].startMs == positionMs) return lo;
    // 位置早于第一条 cue。
    if (lo == 0) return -1;

    final int prev = lo - 1;
    // 在上一条 cue 区间内（含 endMs）。
    if (positionMs <= cues[prev].endMs) return prev;
    // 落在 gap：上游返回 nil。
    return -1;
  }
}
