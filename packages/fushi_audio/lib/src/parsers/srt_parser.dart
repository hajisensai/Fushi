import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';

import '../audiobook/audiobook_model.dart';
import 'cue_parse_dispatch.dart';
import 'subtitle_native_decode.dart';
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
  ///
  /// 实现在 Rust（`ffc_parse_subtitle_srt`，native/fushi_compute/src/parse/subtitle/
  /// formats.rs）：去 BOM → 统一换行 → 按空行切块 → 找含 `-->` 的时间行
  /// （`HH:MM:SS,mmm`，也接受 `.`）→ 其后各行去空后以空格连接 → [stripHtmlTags] →
  /// [parseSubtitleMarkup]，正文为空的块丢弃。时间码小时位越界照旧抛 `FormatException`。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
  }) {
    return decodeSubtitleCues(
      SubtitleParseNative.instance.parseSrt(content),
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    );
  }
}
