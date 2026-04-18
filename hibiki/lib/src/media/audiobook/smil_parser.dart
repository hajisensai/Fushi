import 'dart:io';

import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/text_file_io.dart';
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
  /// [bookUid]       对应 MediaItem.uniqueKey。
  /// [chapterHref]   EPUB spine item 路径，如 'OEBPS/ch01.xhtml'。
  /// [audioFileMap]  将音频 src（相对 SMIL 文件）映射到 audioFileIndex。
  ///                 若为 null，则所有 cue 的 audioFileIndex = 0。
  static Future<List<AudioCue>> parse({
    required File smilFile,
    required String bookUid,
    required String chapterHref,
    Map<String, int>? audioFileMap,
  }) async {
    final String content = await readTextWithEncoding(smilFile);
    return parseString(
      content: content,
      bookUid: bookUid,
      chapterHref: chapterHref,
      audioFileMap: audioFileMap,
    );
  }

  /// 解析 SMIL 字符串并返回 [AudioCue] 列表。纯函数，测试入口。
  static List<AudioCue> parseString({
    required String content,
    required String bookUid,
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
      final String fragmentId = textSrc.contains('#')
          ? '#${textSrc.split('#').last}'
          : textSrc;

      final int startMs = _parseTimeToMs(clipBegin ?? '0');
      final int endMs = _parseTimeToMs(clipEnd ?? '0');
      final int fileIndex = audioFileMap?[audioSrc] ?? 0;

      final AudioCue cue = AudioCue()
        ..bookUid = bookUid
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
  static int _parseTimeToMs(String time) {
    // 标准格式：h:mm:ss.sss 或 mm:ss.sss 或 ss.sss
    final List<String> parts = time.split(':');
    double seconds = 0;

    if (parts.length == 3) {
      seconds = double.parse(parts[0]) * 3600 +
          double.parse(parts[1]) * 60 +
          double.parse(parts[2]);
    } else if (parts.length == 2) {
      seconds =
          double.parse(parts[0]) * 60 + double.parse(parts[1]);
    } else {
      seconds = double.tryParse(parts[0]) ?? 0;
    }

    return (seconds * 1000).round();
  }
}
