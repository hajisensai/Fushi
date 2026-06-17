import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audiobook/audiobook_model.dart';
import 'srt_parser.dart';
import 'subtitle_markup.dart';
import 'text_file_io.dart';

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
/// - textFragmentId 格式为 `[data-cue-id="<sentenceIndex>"]`，供 AudiobookBridge CSS selector 定位
class VttParser {
  static const int largeContentComputeThreshold = 1024 * 1024;

  /// 与 [SrtParser.defaultChapter] 共用同一章节标识。
  static const String defaultChapter = SrtParser.defaultChapter;

  /// 读取 [vttFile] 并返回 [AudioCue] 列表。
  ///
  /// 走 [readTextWithEncoding] 自动识别编码，兼容 Shift-JIS / CP932 等非 UTF-8 源。
  static Future<List<AudioCue>> parse({
    required File vttFile,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) async {
    final String content = await readTextWithEncoding(vttFile);
    return parseStringAsync(
      content: content,
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    );
  }

  /// 解析 VTT 文本字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static Future<List<AudioCue>> parseStringAsync({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    if (content.length > largeContentComputeThreshold) {
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

  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    final String stripped =
        content.startsWith('\uFEFF') ? content.substring(1) : content;

    final List<String> blocks = stripped
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

      final String rawText =
          lines.skip(timeLineIdx + 1).where((l) => l.isNotEmpty).join(' ');
      // 先剥 VTT/HTML 标签，再交 markup 解析 ASS override 块（两者正交）。
      final SubtitleMarkup markup = parseSubtitleMarkup(_stripTags(rawText));
      final String text = markup.plainText;
      if (text.isEmpty) {
        continue;
      }

      cues.add(
        AudioCue()
          ..bookKey = bookKey
          ..chapterHref = chapterHref
          ..sentenceIndex = sentenceIndex
          ..textFragmentId = '[data-cue-id="$sentenceIndex"]'
          ..text = text
          ..markup = markup
          ..startMs = times.$1
          ..endMs = times.$2
          ..audioFileIndex = audioFileIndex,
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
      final int fh = int.parse(full.group(1)!);
      final int fm = int.parse(full.group(2)!);
      final int fs = int.parse(full.group(3)!);
      if (fm >= 60 || fs >= 60) return null;
      return fh * 3600000 +
          fm * 60000 +
          fs * 1000 +
          int.parse(full.group(4)!.padRight(3, '0'));
    }

    // MM:SS.mmm（无小时）
    final RegExpMatch? short =
        RegExp(r'^(\d+):(\d{2})\.(\d{1,3})$').firstMatch(normalized);
    if (short != null) {
      final int sm = int.parse(short.group(1)!);
      final int ss = int.parse(short.group(2)!);
      if (ss >= 60) return null;
      return sm * 60000 +
          ss * 1000 +
          int.parse(short.group(3)!.padRight(3, '0'));
    }

    return null;
  }
}
