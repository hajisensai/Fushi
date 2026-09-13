import 'dart:io';

import '../audiobook/audiobook_model.dart';
import 'cue_parse_dispatch.dart';
import 'strip_html_tags.dart';
import 'subtitle_markup.dart';
import 'text_file_io.dart';

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
  static const int largeContentComputeThreshold =
      CueParseDispatch.largeContentComputeThreshold;

  static int utf8ContentByteLength(String content) =>
      CueParseDispatch.utf8ContentByteLength(content);

  static bool shouldParseInIsolate(String content) =>
      CueParseDispatch.shouldParseInIsolate(content);

  /// SRT 独立书籍使用的固定章节标识。
  static const String defaultChapter = 'srt://default';

  /// 读取 [srtFile] 并返回 [AudioCue] 列表。
  ///
  /// 日文字幕常见 Shift-JIS / CP932 编码，读文件走 [readTextWithEncoding]
  /// 自动识别，避免 UTF-8 严格解码时抛 [FormatException]。
  ///
  /// [bookKey]     对应 MediaItem.uniqueKey。
  /// [chapterHref] 章节标识，默认 [defaultChapter]（单章节策略）。
  ///
  /// 每条 cue 的 [AudioCue.textFragmentId] 格式为 `[data-cue-id="<sentenceIndex>"]`，
  /// 供 [AudiobookBridge] 以 CSS selector 定位 WebView 内的 span 元素。
  static Future<List<AudioCue>> parse({
    required File srtFile,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) async {
    final String content = await readTextWithEncoding(srtFile);
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
    return CueParseDispatch.run(
      content: content,
      parse: () => parseString(
        content: content,
        bookKey: bookKey,
        chapterHref: chapterHref,
        audioFileIndex: audioFileIndex,
      ),
    );
  }

  /// 解析 SRT 文本字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    // 移除 UTF-8 BOM
    final String stripped =
        content.startsWith('\uFEFF') ? content.substring(1) : content;

    // 统一换行符，按空行分割 block
    final List<String> blocks = stripped
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
      final int timeLineIndex = _findTimeLineIndex(lines);
      if (timeLineIndex < 0) {
        continue;
      }

      final (int startMs, int endMs)? times =
          _parseTimeLine(lines[timeLineIndex]);
      if (times == null) {
        continue;
      }

      // 时间行之后的所有行合并为文本（多行字幕 → 空格连接），并剥离 HTML 标签
      final String rawText =
          lines.skip(timeLineIndex + 1).where((l) => l.isNotEmpty).join(' ');
      // 先剥 HTML 标签（`<i>` / `<b>` / `<font>` 等，共享 [stripHtmlTags]），
      // 再交 markup 解析 ASS override 块（两者正交）。
      final SubtitleMarkup markup = parseSubtitleMarkup(stripHtmlTags(rawText));
      final String text = markup.plainText;

      if (text.isEmpty) {
        continue;
      }

      final AudioCue cue = AudioCue()
        ..bookKey = bookKey
        ..chapterHref = chapterHref
        ..sentenceIndex = sentenceIndex
        ..textFragmentId = '[data-cue-id="$sentenceIndex"]'
        ..text = text
        ..markup = markup
        ..startMs = times.$1
        ..endMs = times.$2
        ..audioFileIndex = audioFileIndex;

      cues.add(cue);
      sentenceIndex++;
    }

    return cues;
  }

  /// 在 block 的各行中找到时间码行（包含 ` --> `）。
  /// 时间行下标；找不到返回 -1（调用方直接用下标，不再 `indexOf` 二次扫描）。
  static int _findTimeLineIndex(List<String> lines) {
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].contains('-->')) {
        return i;
      }
    }
    return -1;
  }

  /// `HH:MM:SS.mmm`。编译一次：以前在 [_parseTimecodeToMs] 里逐次 `RegExp(...)`，
  /// 每条 cue 起止各一次 = 每文件 2N 次正则编译。
  static final RegExp _timecodeRe =
      RegExp(r'^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$');

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
    final RegExpMatch? match = _timecodeRe.firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final int h = int.parse(match.group(1)!);
    final int m = int.parse(match.group(2)!);
    final int s = int.parse(match.group(3)!);
    if (m >= 60 || s >= 60) return null;
    // 毫秒部分补齐到 3 位（如 '1' → 100，'12' → 120，'123' → 123）
    final String msStr = match.group(4)!.padRight(3, '0');
    final int ms = int.parse(msStr);
    return h * 3600000 + m * 60000 + s * 1000 + ms;
  }
}
