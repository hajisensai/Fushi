import 'dart:io';

import '../audiobook/audiobook_model.dart';
import '../audiobook/srt_book_repository.dart' show SrtBookRepository;
import 'srt_parser.dart';
import 'text_file_io.dart';

/// 解析 LRC（歌词）字幕文件，产出 [AudioCue] 列表。
///
/// 支持标准 LRC 格式（MM:SS.xx / MM:SS.xxx）和
/// 扩展 HH:MM:SS.xx 格式；自动忽略元数据标签。
///
/// LRC 格式示例：
/// ```
/// [ar:作者名]
/// [ti:曲名]
///
/// [00:01.00]吾輩は猫である。
/// [00:04.50]名前はまだない。
/// [00:08.20]どこで生れたかとんと見当がつかぬ。
/// ```
///
/// 特性：
/// - endMs = 下一条 cue 的 startMs（最后一条默认加 [lastCueDurationMs]）
/// - 同一行多个时间标签（`[T1][T2]text`）分别生成独立 cue
/// - 剥离增强 LRC 词级时间标签（`<MM:SS.xx>`）
/// - 忽略纯元数据行（`[tag:value]` 其中 tag 全为字母）
/// - textFragmentId 格式为 `[data-cue-id="<sentenceIndex>"]`，供 AudiobookBridge CSS selector 定位
class LrcParser {
  /// 与 [SrtParser.defaultChapter] 共用同一章节标识，
  /// 确保 [SrtBookRepository] 可统一查询。
  static const String defaultChapter = SrtParser.defaultChapter;

  /// 时间标签正则：`[MM:SS.xx]`、`[MM:SS.xxx]`、`[HH:MM:SS.xx]` 等。
  static final RegExp _timedTag = RegExp(r'\[(\d+(?::\d{2})+[.,]\d{1,3})\]');

  /// 增强 LRC 词级时间标签：`<MM:SS.xx>`，解析时剥离。
  static final RegExp _wordTag = RegExp('<[^>]+>');

  /// 元数据标签：`[letters:anything]`（tag 全为字母）。
  static final RegExp _metaTag = RegExp(r'^\[([a-zA-Z]+):[^\]]*\]$');

  /// 读取 [lrcFile] 并返回 [AudioCue] 列表。
  ///
  /// 走 [readTextWithEncoding] 自动识别编码，兼容 Shift-JIS / CP932 等非 UTF-8 源。
  ///
  /// [bookUid]            对应 MediaItem.uniqueKey。
  /// [chapterHref]        章节标识，默认 [defaultChapter]（单章节策略）。
  /// [lastCueDurationMs]  最后一条 cue 的持续时长（毫秒），默认 5000。
  static Future<List<AudioCue>> parse({
    required File lrcFile,
    required String bookUid,
    String chapterHref = defaultChapter,
    int lastCueDurationMs = 5000,
    int audioFileIndex = 0,
  }) async {
    final String content = await readTextWithEncoding(lrcFile);
    return parseString(
      content: content,
      bookUid: bookUid,
      chapterHref: chapterHref,
      lastCueDurationMs: lastCueDurationMs,
      audioFileIndex: audioFileIndex,
    );
  }

  /// 解析 LRC 文本字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookUid,
    String chapterHref = defaultChapter,
    int lastCueDurationMs = 5000,
    int audioFileIndex = 0,
  }) {
    // 移除 UTF-8 BOM
    final String stripped =
        content.startsWith('\uFEFF') ? content.substring(1) : content;

    final List<String> lines =
        stripped.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    // 第一步：收集所有 (startMs, text) 原始对
    final List<(int, String)> rawCues = [];

    for (final String line in lines) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // 跳过元数据行，例如 [ar:Artist]、[ti:Title]
      if (_metaTag.hasMatch(trimmed)) continue;

      // 找出本行全部时间标签
      final Iterable<RegExpMatch> tagMatches = _timedTag.allMatches(trimmed);
      if (tagMatches.isEmpty) continue;

      // 将所有时间标签从行中移除，剩余部分即为文本
      String rawText = trimmed.replaceAll(_timedTag, '');
      // 再剥离增强 LRC 词级时间标签 <MM:SS.xx>
      rawText = rawText.replaceAll(_wordTag, '').trim();

      if (rawText.isEmpty) continue;

      for (final RegExpMatch m in tagMatches) {
        final int? ms = _parseTimecodeToMs(m.group(1)!);
        if (ms != null) {
          rawCues.add((ms, rawText));
        }
      }
    }

    if (rawCues.isEmpty) return [];

    // 第二步：按 startMs 排序
    rawCues.sort(
        (final (int, String) a, final (int, String) b) => a.$1.compareTo(b.$1));

    // 第三步：计算 endMs，构造 AudioCue 列表
    final List<AudioCue> cues = [];
    for (int i = 0; i < rawCues.length; i++) {
      final int startMs = rawCues[i].$1;
      final int endMs = i + 1 < rawCues.length
          ? rawCues[i + 1].$1
          : startMs + lastCueDurationMs;

      final AudioCue cue = AudioCue()
        ..bookUid = bookUid
        ..chapterHref = chapterHref
        ..sentenceIndex = i
        ..textFragmentId = '[data-cue-id="$i"]'
        ..text = rawCues[i].$2
        ..startMs = startMs
        ..endMs = endMs
        ..audioFileIndex = audioFileIndex;

      cues.add(cue);
    }

    return cues;
  }

  /// 将 LRC 时间码转换为毫秒整数。
  ///
  /// 支持：
  /// - `MM:SS.xx`（标准 LRC，百分之一秒）
  /// - `MM:SS.xxx`（毫秒精度）
  /// - `HH:MM:SS.xx` / `HH:MM:SS.xxx`（扩展格式）
  /// - 逗号或点号分隔毫秒部分均可。
  static int? _parseTimecodeToMs(String timecode) {
    // 统一分隔符：将 ',' 替换为 '.'
    final String normalized = timecode.replaceAll(',', '.');

    // 尝试 HH:MM:SS.xxx
    final RegExp fullRe = RegExp(r'^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$');
    final RegExpMatch? fullMatch = fullRe.firstMatch(normalized);
    if (fullMatch != null) {
      final int h = int.parse(fullMatch.group(1)!);
      final int m = int.parse(fullMatch.group(2)!);
      final int s = int.parse(fullMatch.group(3)!);
      if (m >= 60 || s >= 60) return null;
      final String msStr = fullMatch.group(4)!.padRight(3, '0');
      return h * 3600000 + m * 60000 + s * 1000 + int.parse(msStr);
    }

    // 尝试 MM:SS.xx 或 MM:SS.xxx（标准 LRC）
    final RegExp shortRe = RegExp(r'^(\d+):(\d{2})\.(\d{1,3})$');
    final RegExpMatch? shortMatch = shortRe.firstMatch(normalized);
    if (shortMatch != null) {
      final int m = int.parse(shortMatch.group(1)!);
      final int s = int.parse(shortMatch.group(2)!);
      if (s >= 60) return null;
      final String msStr = shortMatch.group(3)!.padRight(3, '0');
      return m * 60000 + s * 1000 + int.parse(msStr);
    }

    return null;
  }
}
