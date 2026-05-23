import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audiobook/audiobook_model.dart';
import 'srt_parser.dart';
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
  /// 与 [SrtParser.defaultChapter] 共用同一章节标识。
  static const String defaultChapter = SrtParser.defaultChapter;

  /// ASS 覆盖标签：`{\an8}`、`{\k50\kf100}` 等。
  static final RegExp _overrideTag = RegExp(r'\{[^}]*\}');

  /// 读取 [assFile]（.ass 或 .ssa）并返回 [AudioCue] 列表。
  ///
  /// 走 [readTextWithEncoding] 自动识别编码，兼容 Shift-JIS / CP932 等非 UTF-8 源。
  static Future<List<AudioCue>> parse({
    required File assFile,
    required String bookUid,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) async {
    final String content = await readTextWithEncoding(assFile);
    if (content.length > 1024 * 1024) {
      return compute(_parseStringIsolate, <String, dynamic>{
        'content': content,
        'bookUid': bookUid,
        'chapterHref': chapterHref,
        'audioFileIndex': audioFileIndex,
      });
    }
    return parseString(
      content: content,
      bookUid: bookUid,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    );
  }

  static List<AudioCue> _parseStringIsolate(Map<String, dynamic> args) {
    return parseString(
      content: args['content'] as String,
      bookUid: args['bookUid'] as String,
      chapterHref: args['chapterHref'] as String,
      audioFileIndex: args['audioFileIndex'] as int,
    );
  }

  /// 解析 ASS/SSA 文本字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookUid,
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

    // 收集 (startMs, endMs, text)，最后按 startMs 排序
    final List<(int, int, String)> rawCues = [];

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

        final int endMs = endCol >= 0 && endCol < parts.length
            ? _parseAssTime(parts[endCol].trim()) ?? startMs + 5000
            : startMs + 5000;

        // Text 列及其后所有列重新拼合（Text 本身可能含逗号）
        final String rawText = parts.sublist(textCol).join(',');
        final String text = _cleanText(rawText);
        if (text.isEmpty) {
          continue;
        }

        rawCues.add((startMs, endMs, text));
      }
    }

    rawCues.sort((a, b) => a.$1.compareTo(b.$1));

    return List.generate(rawCues.length, (i) {
      final (int start, int end, String text) = rawCues[i];
      return AudioCue()
        ..bookUid = bookUid
        ..chapterHref = chapterHref
        ..sentenceIndex = i
        ..textFragmentId = '[data-cue-id="$i"]'
        ..text = text
        ..startMs = start
        ..endMs = end
        ..audioFileIndex = audioFileIndex;
    });
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

  /// 剥离 ASS 覆盖标签，并将软换行符转为空格。
  static String _cleanText(String text) {
    return text
        .replaceAll(_overrideTag, '')
        .replaceAll(r'\N', ' ')
        .replaceAll(r'\n', ' ')
        .replaceAll(r'\h', ' ')
        .trim();
  }
}
