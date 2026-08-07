import 'dart:io';

import '../audiobook/audiobook_model.dart';
import 'text_file_io.dart';
import 'package:xml/xml.dart';

/// 解析 EPUB 3 Media Overlays（SMIL）对齐文件，产出 [AudioCue] 列表。
///
/// SMIL 结构示例：
/// ```xml
/// <smil>
///   <body>
///     <seq id="ch01">
///       <par id="s1">
///         <text src="ch01.xhtml#s1"/>
///         <audio src="audio/ch01.mp3" clipBegin="0:00:00.000" clipEnd="0:00:04.230"/>
///       </par>
///     </seq>
///   </body>
/// </smil>
/// ```
class SmilParser {
  /// 读取 [smilFile] 并返回该章节的 [AudioCue] 列表。
  ///
  /// 走 [readTextWithEncoding] 自动识别编码。
  ///
  /// [bookKey]       对应 MediaItem.uniqueKey。
  /// [chapterHref]   EPUB spine item 路径，如 'OEBPS/ch01.xhtml'。
  /// [audioFileMap]  将音频 src（相对 SMIL 文件）映射到 audioFileIndex。
  ///                 若为 null，则所有 cue 的 audioFileIndex = 0。
  static Future<List<AudioCue>> parse({
    required File smilFile,
    required String bookKey,
    required String chapterHref,
    Map<String, int>? audioFileMap,
  }) async {
    final String content = await readTextWithEncoding(smilFile);
    return parseString(
      content: content,
      bookKey: bookKey,
      chapterHref: chapterHref,
      audioFileMap: audioFileMap,
    );
  }

  /// 解析 SMIL 字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookKey,
    required String chapterHref,
    Map<String, int>? audioFileMap,
  }) {
    final XmlDocument doc = XmlDocument.parse(content);

    final List<AudioCue> cues = [];
    int sentenceIndex = 0;

    for (final XmlElement par in doc.findAllElements('par')) {
      final XmlElement? textEl = par.getElement('text');
      final XmlElement? audioEl = par.getElement('audio');
      if (textEl == null || audioEl == null) {
        continue;
      }

      final String? textSrc = textEl.getAttribute('src');
      final String? audioSrc = audioEl.getAttribute('src');
      final String? clipBegin = audioEl.getAttribute('clipBegin');
      final String? clipEnd = audioEl.getAttribute('clipEnd');

      if (textSrc == null || audioSrc == null) {
        continue;
      }

      // textSrc 形如 'ch01.xhtml#s1'，取 # 后作为 fragment id
      final String fragmentId =
          textSrc.contains('#') ? '#${textSrc.split('#').last}' : textSrc;

      final int? startMs = _parseTimeToMs(clipBegin ?? '0');
      final int? endMs = _parseTimeToMs(clipEnd ?? '0');
      if (startMs == null || endMs == null) continue;
      final int fileIndex = audioFileMap?[audioSrc] ?? 0;

      final AudioCue cue = AudioCue()
        ..bookKey = bookKey
        ..chapterHref = chapterHref
        ..sentenceIndex = sentenceIndex
        ..textFragmentId = fragmentId
        ..text = ''
        ..startMs = startMs
        ..endMs = endMs
        ..audioFileIndex = fileIndex;

      cues.add(cue);
      sentenceIndex++;
    }

    return cues;
  }

  /// 将 SMIL 时间字符串（hh:mm:ss.sss 或 ss.sss）转换为毫秒。
  /// 无法解析时返回 null，调用方应跳过该 cue。
  static int? _parseTimeToMs(String time) {
    final List<String> parts = time.split(':');
    double? seconds;

    if (parts.length == 3) {
      final double? h = double.tryParse(parts[0]);
      final double? m = double.tryParse(parts[1]);
      final double? s = double.tryParse(parts[2]);
      if (h == null || m == null || s == null) return null;
      seconds = h * 3600 + m * 60 + s;
    } else if (parts.length == 2) {
      final double? m = double.tryParse(parts[0]);
      final double? s = double.tryParse(parts[1]);
      if (m == null || s == null) return null;
      seconds = m * 60 + s;
    } else {
      seconds = _parseOffsetSeconds(parts[0]);
    }
    if (seconds == null) return null;
    return (seconds * 1000).round();
  }

  /// Parses a SMIL clock offset value to seconds. The grammar allows a unit
  /// suffix on the non-colon form: '4230ms', '4.5s', '1.2min', '1.5h', or a
  /// bare number (seconds). Previously only bare numbers parsed, so unit-tagged
  /// values returned null and the cue was silently dropped (HBK-AUDIT-024).
  static double? _parseOffsetSeconds(String raw) {
    final String t = raw.trim();
    if (t.endsWith('ms')) {
      final double? v = double.tryParse(t.substring(0, t.length - 2));
      return v == null ? null : v / 1000;
    }
    if (t.endsWith('min')) {
      final double? v = double.tryParse(t.substring(0, t.length - 3));
      return v == null ? null : v * 60;
    }
    if (t.endsWith('h')) {
      final double? v = double.tryParse(t.substring(0, t.length - 1));
      return v == null ? null : v * 3600;
    }
    if (t.endsWith('s')) {
      return double.tryParse(t.substring(0, t.length - 1));
    }
    return double.tryParse(t);
  }
}
