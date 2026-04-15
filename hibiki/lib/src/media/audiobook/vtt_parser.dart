import 'dart:io';

import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';

/// 解析 WebVTT（.vtt）字幕文件，产出 [AudioCue] 列表。
///
/// WebVTT 格式示例：
/// ```
/// WEBVTT
///
/// 1
/// 00:00:01.000 --> 00:00:04.230
/// 吾輩は猫である。
///
/// 00:00:04.500 --> 00:00:08.100 align:left
/// 名前はまだない。
/// ```
///
/// 特性：
/// - 跳过 WEBVTT 头、NOTE、STYLE、REGION 块
/// - 时间码支持 `[HH:]MM:SS.mmm`（有无小时均可）
/// - 忽略时间行后的位置指令（`align:left` 等）
/// - 剥离 HTML/VTT 行内标签（`<b>`、`<ruby>`、`<c.class>` 等）
/// - textFragmentId 格式与 SRT 相同（`srt://<sentenceIndex>`），可复用 SrtReaderPage
class VttParser {
  /// 与 [SrtParser.defaultChapter] 共用同一章节标识。
  static const String defaultChapter = SrtParser.defaultChapter;

  /// 解析 [vttFile] 并返回 [AudioCue] 列表。
  static List<AudioCue> parse({
    required File vttFile,
    required String bookUid,
    String chapterHref = defaultChapter,
  }) {
    final String raw = vttFile.readAsStringSync();
    final String content =
        raw.startsWith('\uFEFF') ? raw.substring(1) : raw;

    final List<String> blocks = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n{2,}'));

    final List<AudioCue> cues = [];
    int sentenceIndex = 0;

    for (final String block in blocks) {
      final List<String> lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      if (lines.isEmpty) {
        continue;
      }

      // 跳过 WEBVTT 头和功能块
      final String first = lines[0];
      if (first.startsWith('WEBVTT') ||
          first.startsWith('NOTE') ||
          first.startsWith('STYLE') ||
          first.startsWith('REGION')) {
        continue;
      }

      // 找时间行（含 `-->`）；前面可能有 cue ID 行
      String? timeLine;
      int timeLineIdx = -1;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('-->')) {
          timeLine = lines[i];
          timeLineIdx = i;
          break;
        }
      }
      if (timeLine == null) {
        continue;
      }

      final (int, int)? times = _parseTimeLine(timeLine);
      if (times == null) {
        continue;
      }

      final String rawText = lines
          .skip(timeLineIdx + 1)
          .where((l) => l.isNotEmpty)
          .join(' ');
      final String text = _stripTags(rawText);
      if (text.isEmpty) {
        continue;
      }

      cues.add(
        AudioCue()
          ..bookUid = bookUid
          ..chapterHref = chapterHref
          ..sentenceIndex = sentenceIndex
          ..textFragmentId = 'srt://$sentenceIndex'
          ..text = text
          ..startMs = times.$1
          ..endMs = times.$2
          ..audioFileIndex = 0,
      );
      sentenceIndex++;
    }

    return cues;
  }

  /// 解析 VTT 时间行，忽略 `-->` 后的位置指令。
  static (int, int)? _parseTimeLine(String line) {
    final List<String> parts = line.split('-->');
    if (parts.length < 2) {
      return null;
    }
    // 位置指令（如 `align:left`）以空白分隔在时间戳后，取第一个 token
    final int? start =
        _parseTimecodeToMs(parts[0].trim().split(RegExp(r'\s+')).first);
    final int? end =
        _parseTimecodeToMs(parts[1].trim().split(RegExp(r'\s+')).first);
    if (start == null || end == null) {
      return null;
    }
    return (start, end);
  }

  /// 剥离 VTT/HTML 行内标签（`<b>`、`<i>`、`<ruby>`、`<c.className>` 等）。
  static String _stripTags(String text) =>
      text.replaceAll(RegExp('<[^>]+>'), '').trim();

  /// 将 VTT 时间码转换为毫秒。
  ///
  /// 支持 `HH:MM:SS.mmm`（含小时）和 `MM:SS.mmm`（不含小时）。
  static int? _parseTimecodeToMs(String timecode) {
    final String normalized = timecode.replaceAll(',', '.');

    // HH:MM:SS.mmm
    final RegExpMatch? full =
        RegExp(r'^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$').firstMatch(normalized);
    if (full != null) {
      return int.parse(full.group(1)!) * 3600000 +
          int.parse(full.group(2)!) * 60000 +
          int.parse(full.group(3)!) * 1000 +
          int.parse(full.group(4)!.padRight(3, '0'));
    }

    // MM:SS.mmm（无小时）
    final RegExpMatch? short =
        RegExp(r'^(\d+):(\d{2})\.(\d{1,3})$').firstMatch(normalized);
    if (short != null) {
      return int.parse(short.group(1)!) * 60000 +
          int.parse(short.group(2)!) * 1000 +
          int.parse(short.group(3)!.padRight(3, '0'));
    }

    return null;
  }
}
