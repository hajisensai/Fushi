import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';

import '../audiobook/audiobook_model.dart';
import 'cue_parse_dispatch.dart';
import 'srt_parser.dart';
import 'subtitle_native_decode.dart';
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
/// - 时间码格式 `H:MM:SS.x`（厘秒/毫秒/十分之一秒可变精度，与 SRT/VTT 对齐）
/// - 剥离 ASS 覆盖标签（`{\an8}`、`{\k50}` 等）
/// - 软换行符 `\N`、`\n`、`\h` 转为空格
/// - textFragmentId 格式为 `[data-cue-id="<sentenceIndex>"]`，供 AudiobookBridge CSS selector 定位
class AssParser {
  static const int largeContentComputeThreshold =
      CueParseDispatch.largeContentComputeThreshold;

  static bool shouldParseInIsolate(String content) =>
      CueParseDispatch.shouldParseInIsolate(content);

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
    bool includeDrawings = false,
  }) {
    return CueParseDispatch.run(
      content: content,
      parse: () => parseString(
        content: content,
        bookKey: bookKey,
        chapterHref: chapterHref,
        audioFileIndex: audioFileIndex,
        includeDrawings: includeDrawings,
      ),
    );
  }

  /// 解析 ASS/SSA 文本字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  ///
  /// [includeDrawings]：是否把**无正文的 `\p` 矢量绘图事件**（招牌白底遮罩等）也作为
  /// cue 产出（`text` 为空、`markup.drawing` 非空）。默认关——字幕列表 / 制卡 / 导入
  /// 持久化只认可读对白；播放渲染路径开（[VideoPlayerController] 再把它们分流到
  /// 渲染专用流，不进对白流）。
  ///
  /// 实现在 Rust（`ffc_parse_subtitle_ass`，native/fushi_compute/src/parse/subtitle/
  /// formats.rs）：`[Script Info]` 的 PlayResX/Y（缺省 384×288）、`[V4+ Styles]` /
  /// `[V4 Styles]` 的 `Format:` 动态列序与 `Style:` 行（样式名大小写不敏感，同名后者覆盖）、
  /// `[Events]` 的 `Format:` 动态列序与 `Dialogue:` 行（Text 列之后的逗号拼回、Layer、
  /// 行级 MarginL/R/V >0 覆盖），Events 之后遇到新段即停；按起始时间**稳定**排序（文件序
  /// 即 libass 同层 z 序），缺 End 用下一条起点补、最后一条 +5 s，丢弃 end <= start。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    String chapterHref = defaultChapter,
    int audioFileIndex = 0,
    bool includeDrawings = false,
  }) {
    return decodeAssCues(
      SubtitleParseNative.instance.parseAss(
        content,
        includeDrawings: includeDrawings,
      ),
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileIndex: audioFileIndex,
    );
  }
}
