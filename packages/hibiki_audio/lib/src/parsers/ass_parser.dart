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
/// - 时间码格式 `H:MM:SS.x`（厘秒/毫秒/十分之一秒可变精度，与 SRT/VTT 对齐）
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
    bool inStyles = false;
    int startCol = -1;
    int endCol = -1;
    int textCol = -1;
    int styleCol = -1;
    // 脚本坐标系分辨率（[Script Info]），仅用于把 \pos 归一化；缺省按 ASS 规范 384×288。
    double? playResX;
    double? playResY;

    // [V4+ Styles] 段解析出的 style-name（小写）→ 默认样式映射（TODO-1105）。
    final Map<String, SubtitleCueStyle> styles = <String, SubtitleCueStyle>{};
    // Styles 段 Format: 行的列名列表（区分 V4 与 V4+ 列序差异；动态定位）。
    List<String>? styleFormatCols;

    // 收集 (startMs, endMs?, text, markup)，最后按 startMs 排序。
    // endMs 为 null 表示 End 列缺失/无法解析，留待排序后用下一条 cue 的
    // startMs 推断（HBK-AUDIT-067），而不是当场伪造固定的 5s 时长。
    final List<(int, int?, String, SubtitleMarkup)> rawCues = [];

    for (final String line in lines) {
      final String trimmed = line.trim();
      final String lowSection = trimmed.toLowerCase();

      // 进入 [Events] 段
      if (lowSection == '[events]') {
        inEvents = true;
        inStyles = false;
        continue;
      }
      // 进入 [V4+ Styles] / [V4 Styles] / [V4++ Styles] 段（TODO-1105）。
      if (lowSection.startsWith('[v4') && lowSection.endsWith('styles]')) {
        inStyles = true;
        inEvents = false;
        styleFormatCols = null;
        continue;
      }
      // 进入其它段头：退出 styles 段。若已在 Events 段（遇到 Events 之后的下一段）
      // 则收工——Styles 段规范上在 Events 之前，Events 之后无需再扫。
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        if (inEvents) break;
        inStyles = false;
        inEvents = false;
        // 其余（如 [Script Info]）继续下方 PlayRes 捕获。
      }

      if (inStyles) {
        if (trimmed.startsWith('Format:')) {
          styleFormatCols = trimmed
              .substring('Format:'.length)
              .split(',')
              .map((c) => c.trim().toLowerCase())
              .toList();
          continue;
        }
        if (trimmed.startsWith('Style:') && styleFormatCols != null) {
          final String body = trimmed.substring('Style:'.length);
          final SubtitleCueStyle? parsed =
              _parseStyleRow(body, styleFormatCols);
          final int nameIdx = styleFormatCols.indexOf('name');
          if (parsed != null && nameIdx >= 0) {
            // Style 名可含空格但规范不含逗号；按逗号取第 nameIdx 段。
            final List<String> cells =
                body.split(',').map((c) => c.trim()).toList();
            if (nameIdx < cells.length && cells[nameIdx].isNotEmpty) {
              styles[cells[nameIdx].toLowerCase()] = parsed;
            }
          }
        }
        continue;
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
        styleCol = cols.indexOf('style');
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

        // 本条引用的 Style（V4+ Format 里的 'style' 列）→ cue 级默认样式（TODO-1105）。
        SubtitleCueStyle? cueStyle;
        if (styleCol >= 0 && styleCol < parts.length) {
          cueStyle = styles[parts[styleCol].trim().toLowerCase()];
        }

        // Text 列及其后所有列重新拼合（Text 本身可能含逗号）
        final String rawText = parts.sublist(textCol).join(',');
        // markup 负责剥离 {...} override 块、转换 \N/\n/\h 软换行，并解析
        // \an/\pos/行内样式；缺 PlayRes 时按 ASS 规范回退 384×288。cueStyle 作为
        // 行内 span 之下的基线透传（TODO-1105）。
        final SubtitleMarkup markup = parseSubtitleMarkup(
          rawText,
          playResX: playResX ?? 384,
          playResY: playResY ?? 288,
          cueStyle: cueStyle,
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

  /// 将 ASS 时间码 `H:MM:SS.x` 转换为毫秒。小数秒接受 1~3 位
  /// （厘秒/毫秒/十分之一秒可变精度），归一到毫秒的写法与 SRT/VTT
  /// 解析器同构（`padRight(3, '0')`），消除外挂 .ass 的孤立特例（TODO-870）。
  static int? _parseAssTime(String timecode) {
    final RegExpMatch? m =
        RegExp(r'^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$').firstMatch(timecode);
    if (m == null) {
      return null;
    }
    final int ah = int.parse(m.group(1)!);
    final int am = int.parse(m.group(2)!);
    final int as_ = int.parse(m.group(3)!);
    if (am >= 60 || as_ >= 60) return null;
    // 小数秒右补 0 到 3 位再当毫秒（与 srt_parser.dart 同构）：
    // '1'→100ms（十分之一秒）/ '67'→670ms（厘秒）/ '000'→0ms（毫秒）。
    final int frac = int.parse(m.group(4)!.padRight(3, '0'));
    return ah * 3600000 + am * 60000 + as_ * 1000 + frac;
  }

  /// 把一条 `Style: ...` 行（`Style:` 前缀已剥）按 [formatCols]（`[V4+ Styles]` 的
  /// `Format:` 列名，小写）解析成 [SubtitleCueStyle]（TODO-1105）。列名不存在的字段留
  /// null，渲染层据此回退用户统一样式（fail-safe）。颜色列走与行内 \c 同一份
  /// [assColorToArgb]（BGR→ARGB）。V4 与 V4+ 列序不同，故一律按列名动态取，不按固定下标。
  static SubtitleCueStyle? _parseStyleRow(
    String body,
    List<String> formatCols,
  ) {
    // Style 名规范不含逗号，其余数值/颜色列也不含逗号 → 直接按逗号切分，与列名一一对应。
    final List<String> cells =
        body.split(',').map((String c) => c.trim()).toList();
    String? cell(String name) {
      final int idx = formatCols.indexOf(name);
      if (idx < 0 || idx >= cells.length) return null;
      final String v = cells[idx];
      return v.isEmpty ? null : v;
    }

    int? color(String name) {
      final String? raw = cell(name);
      if (raw == null) return null;
      // ASS 颜色形如 &HAABBGGRR& 或 &HBBGGRR；取出十六进制主体交给 assColorToArgb。
      final RegExpMatch? m = RegExp(r'&H([0-9a-fA-F]{1,8})&?$').firstMatch(raw);
      if (m == null) return null;
      return assColorToArgb(m.group(1)!);
    }

    double? number(String name) {
      final String? raw = cell(name);
      if (raw == null) return null;
      return double.tryParse(raw);
    }

    // ASS 布尔列：-1 / 1 = 真，0 = 假（负数按 SSA 惯例视为真）。
    bool? flag(String name) {
      final String? raw = cell(name);
      if (raw == null) return null;
      final int? v = int.tryParse(raw);
      if (v == null) return null;
      return v != 0;
    }

    SubtitleAnchor? anchor() {
      final String? raw = cell('alignment');
      if (raw == null) return null;
      final int? a = int.tryParse(raw);
      if (a == null) return null;
      // V4+ Alignment 与行内 \an 同为小键盘 1..9；SubtitleAnchor.fromAnCode 复用。
      return SubtitleAnchor.fromAnCode(a);
    }

    return SubtitleCueStyle(
      fontName: cell('fontname'),
      primaryColorArgb: color('primarycolour'),
      outlineColorArgb: color('outlinecolour'),
      shadowColorArgb: color('backcolour'),
      fontSizePx: number('fontsize'),
      outlineWidthPx: number('outline'),
      shadowDepthPx: number('shadow'),
      bold: flag('bold'),
      italic: flag('italic'),
      underline: flag('underline'),
      strikeOut: flag('strikeout'),
      anchor: anchor(),
      marginV: number('marginv'),
    );
  }
}
