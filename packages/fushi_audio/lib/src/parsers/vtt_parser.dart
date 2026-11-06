import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';

import '../audiobook/audiobook_model.dart';
import 'cue_parse_dispatch.dart';
import 'srt_parser.dart';
import 'subtitle_native_decode.dart';
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
  static const int largeContentComputeThreshold =
      CueParseDispatch.largeContentComputeThreshold;

  static bool shouldParseInIsolate(String content) =>
      CueParseDispatch.shouldParseInIsolate(content);

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

  /// 实现在 Rust（`ffc_parse_subtitle_vtt`，native/fushi_compute/src/parse/subtitle/
  /// formats.rs），特性见类注释；结果与旧 Dart 实现逐位一致（含小时 / 分钟位越界抛
  /// `FormatException`）。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    return decodeSubtitleCues(
      SubtitleParseNative.instance.parseVtt(content),
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    );
  }
}
