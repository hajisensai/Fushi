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

  /// 返回**所有**闭区间 `[startMs, endMs]` 覆盖 [positionMs] 的 cue 下标（升序）。
  ///
  /// 与 [findCueIndex] 的关键差异：[findCueIndex] 只回一个「代表」下标（重叠区里回
  /// startMs 更大的那条、gap 回 -1），用于有声书正文高亮 / 查词锚 / 跳句这些「同一
  /// 时刻只关心一条」的旧路径；本函数回**整个活动集**，用于视频字幕 overlay 把同一轨
  /// 上时间轴重叠的多条 cue 同时渲染出来（TODO-1312：重叠 cue 都显示、不因越过被选那
  /// 条 end 落进 gap 而闪烁 / 切换）。
  ///
  /// 边界默认与 [findCueIndex] 一致：`startMs <= positionMs <= endMs`（endMs **闭区间**，
  /// HBK-AUDIT-153）。空活动集返回空列表（调用方据此清空 overlay，与 gap 语义一致）。
  ///
  /// [endInclusive]（默认 true，保 HBK-AUDIT-153 契约）：置 false 时改用**半开区间**
  /// `[startMs, endMs)`。视频字幕 overlay 的**渲染集**必须传 false，否则相邻对白
  /// （前一条 `endMs` == 后一条 `startMs`，fansub 极常见）在那一毫秒会**同时活跃**——
  /// 前一条尚未退场、后一条已进场，两对 cue 挤成一帧的「幻影重叠」。竖排堆叠槽位表
  /// （`VideoSubtitleOverlay._syncGroupSlots`）据此把后进 cue 追加到远端槽，随后前一条
  /// 退场只留下**锚点侧隐形占位**（step③ 只裁尾部死槽），把后一条持续顶离基线，直到
  /// 出现间隙整组清空——表现为「双轨字幕在连续对白里被抬高、间隙落回，来回弹跳」。半开
  /// 区间让边界处只后一条活跃，后进 cue 直接复用被腾空的锚点槽，弹跳根除。代表 cue
  /// （[findCueIndex]，仍闭区间）由 `_activeRenderIndices` 并入，故末条无后继时不会因半开
  /// 提前 1 tick 消失。
  ///
  /// 要求 [cues] 已按 startMs 升序排序（[VideoPlayerController.setCues] /
  /// [JsonAlignmentParser.parseString] 后调用方保证）：一旦某条 startMs > positionMs，
  /// 其后的 cue startMs 只会更大、更不可能覆盖，故提前 break。endMs 因重叠可乱序，
  /// 不能据 endMs 提前终止，只能对 startMs <= positionMs 的每条判 endMs。
  static List<int> findActiveCueIndices({
    required List<AudioCue> cues,
    required int positionMs,
    bool endInclusive = true,
  }) {
    final List<int> active = <int>[];
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      if (cue.startMs > positionMs) break;
      final bool withinEnd =
          endInclusive ? positionMs <= cue.endMs : positionMs < cue.endMs;
      if (withinEnd) active.add(i);
    }
    return active;
  }
}
