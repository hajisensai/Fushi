import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audiobook/audiobook_model.dart';
import 'srt_parser.dart';
import 'subtitle_markup.dart';
import 'text_file_io.dart';

/// 解析 ASS/SSA（.ass / .ssa）字幕文件，产出 [AudioCue] 列表。
///
/// ASS 格式示例：
/// ```
/// [Script Info]
/// Title: Sample
///
/// [V4+ Styles]
/// Format: Name, ...
/// Style: Default,...
///
/// [Events]
/// Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
/// Dialogue: 0,0:00:01.00,0:00:04.23,Default,,0,0,0,,吾輩は猫である。
/// Dialogue: 0,0:00:04.50,0:00:08.10,Default,,0,0,0,,名前はまだない。
/// ```
///
/// 特性：
/// - 解析 `[Events]` 段，通过 `Format:` 行动态定位 Start / End / Text 列
/// - 时间码格式 `H:MM:SS.cc`（厘秒精度）
/// - 剥离 ASS 覆盖标签（`{\an8}`、`{\k50}` 等）
/// - 软换行符 `\N`、`\n`、`\h` 转为空格
/// - textFragmentId 格式为 `[data-cue-id="<sentenceIndex>"]`，供 AudiobookBridge CSS selector 定位
class AssParser {
  static const int largeContentComputeThreshold = 1024 * 1024;

  static bool shouldParseInIsolate(String content) {
    return SrtParser.utf8ContentByteLength(content) >
        largeContentComputeThreshold;
  }

  /// 与 [SrtParser.defaultChapter] 共用同一章节标识。
  static const String defaultChapter = SrtParser.defaultChapter;

  /// 读取 [assFile]（.ass 或 .ssa）并返回 [AudioCue] 列表。
  ///
  /// 走 [readTextWithEncoding] 自动识别编码，兼容 Shift-JIS / CP932 等非 UTF-8 源。
  static Future<List<AudioCue>> parse({
    required File assFile,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) async {
    final String content = await readTextWithEncoding(assFile);
    return parseStringAsync(
      content: content,
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    );
  }

  static Future<List<AudioCue>> parseStringAsync({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    if (shouldParseInIsolate(content)) {
      return compute(_parseStringIsolate, <String, dynamic>{
        'content': content,
        'bookKey': bookKey,
        'chapterHref': chapterHref,
        'audioFileIndex': audioFileIndex,
      });
    }
    return Future<List<AudioCue>>.value(parseString(
      content: content,
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    ));
  }

  static List<AudioCue> _parseStringIsolate(Map<String, dynamic> args) {
    return parseString(
      content: args['content'] as String,
      bookKey: args['bookKey'] as String,
      chapterHref: args['chapterHref'] as String,
      audioFileIndex: args['audioFileIndex'] as int,
    );
  }

  /// 解析 ASS/SSA 文本字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    final String stripped =
        content.startsWith('\uFEFF') ? content.substring(1) : content;

    final List<String> lines =
        stripped.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    bool inEvents = false;
    int startCol = -1;
    int endCol = -1;
    int textCol = -1;
    // 脚本坐标系分辨率（[Script Info]），仅用于把 \pos 归一化；缺省按 ASS 规范 384×288。
    double? playResX;
    double? playResY;

    // 收集 (startMs, endMs?, text, markup)，最后按 startMs 排序。
    // endMs 为 null 表示 End 列缺失/无法解析，留待排序后用下一条 cue 的
    // startMs 推断（HBK-AUDIT-067），而不是当场伪造固定的 5s 时长。
    final List<(int, int?, String, SubtitleMarkup)> rawCues = [];

    for (final String line in lines) {
      final String trimmed = line.trim();

      // 进入 [Events] 段
      if (trimmed.toLowerCase() == '[events]') {
        inEvents = true;
        continue;
      }
      // 遇到下一段则退出
      if (inEvents && trimmed.startsWith('[') && trimmed.endsWith(']')) {
        break;
      }
      if (!inEvents) {
        // [Script Info] 里捕获 PlayResX/Y（供 \pos 归一化）。
        final String low = trimmed.toLowerCase();
        if (low.startsWith('playresx:')) {
          playResX = double.tryParse(trimmed.substring(9).trim());
        } else if (low.startsWith('playresy:')) {
          playResY = double.tryParse(trimmed.substring(9).trim());
        }
        continue;
      }

      // 解析 Format 行，确定列索引
      if (trimmed.startsWith('Format:')) {
        final List<String> cols = trimmed
            .substring('Format:'.length)
            .split(',')
            .map((c) => c.trim().toLowerCase())
            .toList();
        startCol = cols.indexOf('start');
        endCol = cols.indexOf('end');
        textCol = cols.indexOf('text');
        continue;
      }

      // 解析 Dialogue 行
      if (trimmed.startsWith('Dialogue:') && startCol >= 0 && textCol >= 0) {
        final String data = trimmed.substring('Dialogue:'.length).trim();

        // 以逗号拆分；Text 列之后的内容（含逗号）整体取出
        final List<String> parts = data.split(',');
        if (parts.length <= textCol) {
          continue;
        }

        final int? startMs = _parseAssTime(parts[startCol].trim());
        if (startMs == null) {
          continue;
        }

        // End 列缺失或无法解析时保持 null，排序后再用下一条 cue 推断时长，
        // 而非伪造固定 5s（HBK-AUDIT-067）。
        final int? endMs = endCol >= 0 && endCol < parts.length
            ? _parseAssTime(parts[endCol].trim())
            : null;

        // Text 列及其后所有列重新拼合（Text 本身可能含逗号）
        final String rawText = parts.sublist(textCol).join(',');
        // markup 负责剥离 {...} override 块、转换 \N/\n/\h 软换行，并解析
        // \an/\pos/行内样式；缺 PlayRes 时按 ASS 规范回退 384×288。
        final SubtitleMarkup markup = parseSubtitleMarkup(
          rawText,
          playResX: playResX ?? 384,
          playResY: playResY ?? 288,
        );
        final String text = markup.plainText;
        if (text.isEmpty) {
          continue;
        }

        rawCues.add((startMs, endMs, text, markup));
      }
    }

    rawCues.sort((a, b) => a.$1.compareTo(b.$1));

    // 解析 endMs：缺失的用下一条 cue 的 startMs 收口（最后一条退回 5s）；
    // 同时丢弃 end <= start 的反向/零长 cue，避免静默产出永不命中的高亮区间
    // （HBK-AUDIT-067）。
    final List<AudioCue> cues = [];
    for (int i = 0; i < rawCues.length; i++) {
      final (int start, int? rawEnd, String text, SubtitleMarkup markup) =
          rawCues[i];
      final int fallbackEnd =
          i + 1 < rawCues.length ? rawCues[i + 1].$1 : start + 5000;
      final int end = rawEnd ?? fallbackEnd;
      if (end <= start) {
        if (kDebugMode) {
          debugPrint(
              'AssParser: skip cue with end<=start (start=$start end=$end): $text');
        }
        continue;
      }
      cues.add(AudioCue()
        ..bookKey = bookKey
        ..chapterHref = chapterHref
        ..sentenceIndex = cues.length
        ..textFragmentId = '[data-cue-id="${cues.length}"]'
        ..text = text
        ..markup = markup
        ..startMs = start
        ..endMs = end
        ..audioFileIndex = audioFileIndex);
    }
    return cues;
  }

  /// 将 ASS 时间码 `H:MM:SS.cc`（厘秒）转换为毫秒。
  static int? _parseAssTime(String timecode) {
    final RegExpMatch? m =
        RegExp(r'^(\d+):(\d{2}):(\d{2})\.(\d{2})$').firstMatch(timecode);
    if (m == null) {
      return null;
    }
    final int ah = int.parse(m.group(1)!);
    final int am = int.parse(m.group(2)!);
    final int as_ = int.parse(m.group(3)!);
    if (am >= 60 || as_ >= 60) return null;
    return ah * 3600000 +
        am * 60000 +
        as_ * 1000 +
        int.parse(m.group(4)!) * 10; // 厘秒 → 毫秒
  }
}
