import 'dart:io';

import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

/// 解析 SubRip（.srt）字幕文件，产出 [AudioCue] 列表。
///
/// SRT 格式示例：
/// ```
/// 1
/// 00:00:01,000 --> 00:00:04,230
/// 吾輩は猫である。
///
/// 2
/// 00:00:04,500 --> 00:00:08,100
/// 名前はまだない。
/// ```
class SrtParser {
  /// SRT 独立书籍使用的固定章节标识。
  static const String defaultChapter = 'srt://default';

  /// 解析 [srtFile] 并返回 [AudioCue] 列表。
  ///
  /// [bookUid]     对应 MediaItem.uniqueKey。
  /// [chapterHref] 章节标识，默认 [defaultChapter]（单章节策略）。
  ///
  /// 每条 cue 的 [AudioCue.textFragmentId] 格式为 `srt://<sentenceIndex>`，
  /// 供 [SrtReaderPage] 按下标定位高亮，无需 DOM。
  static List<AudioCue> parse({
    required File srtFile,
    required String bookUid,
    String chapterHref = defaultChapter,
  }) {
    final String raw = srtFile.readAsStringSync();
    // 移除 UTF-8 BOM
    final String content =
        raw.startsWith('\uFEFF') ? raw.substring(1) : raw;

    // 统一换行符，按空行分割 block
    final List<String> blocks = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n{2,}'));

    final List<AudioCue> cues = [];
    int sentenceIndex = 0;

    for (final String block in blocks) {
      final List<String> lines =
          block.split('\n').map((l) => l.trim()).toList();

      // block 至少需要：序号行 + 时间行 + 文本行
      if (lines.length < 3) {
        continue;
      }

      // 跳过序号行（第 0 行），解析第 1 行时间码
      final String? timeLine = _findTimeLine(lines);
      if (timeLine == null) {
        continue;
      }

      final (int startMs, int endMs)? times = _parseTimeLine(timeLine);
      if (times == null) {
        continue;
      }

      // 时间行之后的所有行合并为文本（多行字幕 → 空格连接）
      final int timeLineIndex = lines.indexOf(timeLine);
      final String text = lines
          .skip(timeLineIndex + 1)
          .where((l) => l.isNotEmpty)
          .join(' ');

      if (text.isEmpty) {
        continue;
      }

      final AudioCue cue = AudioCue()
        ..bookUid = bookUid
        ..chapterHref = chapterHref
        ..sentenceIndex = sentenceIndex
        ..textFragmentId = 'srt://$sentenceIndex'
        ..text = text
        ..startMs = times.$1
        ..endMs = times.$2
        ..audioFileIndex = 0;

      cues.add(cue);
      sentenceIndex++;
    }

    return cues;
  }

  /// 在 block 的各行中找到时间码行（包含 ` --> `）。
  static String? _findTimeLine(List<String> lines) {
    for (final String line in lines) {
      if (line.contains('-->')) {
        return line;
      }
    }
    return null;
  }

  /// 解析时间码行 `HH:MM:SS,mmm --> HH:MM:SS,mmm`，返回 (startMs, endMs)。
  static (int, int)? _parseTimeLine(String line) {
    final List<String> parts = line.split('-->');
    if (parts.length != 2) {
      return null;
    }
    final int? start = _parseTimecodeToMs(parts[0].trim());
    final int? end = _parseTimecodeToMs(parts[1].trim());
    if (start == null || end == null) {
      return null;
    }
    return (start, end);
  }

  /// 将 SRT 时间码 `HH:MM:SS,mmm`（逗号分隔毫秒）转换为毫秒整数。
  /// 也接受点号分隔（`HH:MM:SS.mmm`）以提高兼容性。
  static int? _parseTimecodeToMs(String timecode) {
    // 统一分隔符：将 ',' 替换为 '.'
    final String normalized = timecode.replaceAll(',', '.');
    // 格式：HH:MM:SS.mmm
    final RegExp re =
        RegExp(r'^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$');
    final RegExpMatch? match = re.firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final int h = int.parse(match.group(1)!);
    final int m = int.parse(match.group(2)!);
    final int s = int.parse(match.group(3)!);
    // 毫秒部分补齐到 3 位（如 '1' → 100，'12' → 120，'123' → 123）
    final String msStr = match.group(4)!.padRight(3, '0');
    final int ms = int.parse(msStr);
    return h * 3600000 + m * 60000 + s * 1000 + ms;
  }
}
