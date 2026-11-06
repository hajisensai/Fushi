import 'dart:io';

import '../audiobook/audiobook_model.dart';
import 'epub_builder.dart';

/// Converts a flat [AudioCue] list into a valid EPUB 3 file.
///
/// ### Paragraph strategy
/// Consecutive cues are merged into a single `<p>` element.
/// A new paragraph is started when the gap between the end of the previous
/// cue and the start of the next exceeds [kParagraphGapMs] (default 2 s).
///
/// ### Chapter strategy
/// Cues are split into chapters such that each chapter contains at most
/// [kMaxCuesPerChapter] cues **and** spans at most [kMaxChapterDurationMs]
/// of audio.  Whichever limit is reached first triggers a chapter break.
///
/// ### Fragment IDs
/// Every cue is wrapped in a `<span>` with three data attributes:
/// ```html
/// <span data-cue-id="N" data-start="X.XXX" data-end="Y.YYY">text</span>
/// ```
/// The bridge can locate each span with the CSS selector
/// `[data-cue-id="N"]` and highlight it during audio playback.
///
/// ### Half-width `!` / `?` in Japanese text
/// ASR (and many hand-made subtitles) write Japanese exclamations with ASCII
/// `!` / `?` (`断る!`, `何を?`). In vertical writing `text-orientation: mixed`
/// lays those sideways like Latin letters — correct CSS, wrong Japanese
/// typesetting. A run of one or two of them right after a Japanese character
/// is wrapped in `<span class="tcy">` (縦中横, `text-combine-upright: all`), the
/// same markup a typeset Japanese EPUB uses; the text itself is untouched (no
/// full-width conversion), so cue text ↔ book text matching, lookup and mining
/// see exactly what the subtitle said. Horizontal writing ignores the rule.
///
/// Container assembly (ZIP/OPF/NCX/nav) is shared with the app-side
/// text importer via [EpubBuilder].
class CuesToEpub {
  // ── thresholds (adjust here without touching logic) ──────────────────────

  /// Maximum number of cues per chapter.
  static const int kMaxCuesPerChapter = 500;

  /// Maximum audio duration per chapter, in milliseconds (10 min).
  static const int kMaxChapterDurationMs = 10 * 60 * 1000;

  /// Inter-cue gap that triggers a new paragraph, in milliseconds (2 s).
  static const int kParagraphGapMs = 2000;

  // ── public API ────────────────────────────────────────────────────────────

  /// Generates an EPUB 3 file at [outputPath] from [cues].
  ///
  /// [title] and optional [author] are embedded in the OPF metadata.
  /// Returns the created [File].
  static Future<File> convert({
    required String title,
    required List<AudioCue> cues,
    required String outputPath,
    String? author,
  }) async {
    final List<List<AudioCue>> chapters = splitChapters(cues);

    final List<String> chapterXhtmls = <String>[
      for (int i = 0; i < chapters.length; i++)
        _chapterXhtml(
          bookTitle: title,
          chapterIndex: i,
          totalChapters: chapters.length,
          cues: chapters[i],
        ),
    ];

    final file = File(outputPath);
    await file.writeAsBytes(
      EpubBuilder.assemble(
        title: title,
        author: author,
        uidPrefix: 'fushi-',
        chapterXhtmls: chapterXhtmls,
      ),
      flush: true,
    );
    return file;
  }

  // ── chapter splitting ─────────────────────────────────────────────────────

  /// Splits [cues] into sub-lists, each within the size/duration thresholds.
  static List<List<AudioCue>> splitChapters(List<AudioCue> cues) {
    if (cues.isEmpty) {
      return [[]];
    }

    final List<List<AudioCue>> chapters = [];
    List<AudioCue> current = [];
    int chapterStartMs = cues.first.startMs;

    for (final AudioCue cue in cues) {
      final bool tooManyCues = current.length >= kMaxCuesPerChapter;
      final bool tooLong = (cue.endMs - chapterStartMs) > kMaxChapterDurationMs;

      if (current.isNotEmpty && (tooManyCues || tooLong)) {
        chapters.add(current);
        current = [];
        chapterStartMs = cue.startMs;
      }
      current.add(cue);
    }
    if (current.isNotEmpty) {
      chapters.add(current);
    }
    return chapters;
  }

  // ── paragraph grouping ────────────────────────────────────────────────────

  /// Groups [cues] into paragraphs based on timing gaps.
  ///
  /// Returns a list of paragraphs; each paragraph is a list of cues.
  static List<List<AudioCue>> _groupParagraphs(List<AudioCue> cues) {
    if (cues.isEmpty) {
      return [];
    }

    final List<List<AudioCue>> paragraphs = [];
    List<AudioCue> para = [cues.first];

    for (int i = 1; i < cues.length; i++) {
      final int gap = cues[i].startMs - cues[i - 1].endMs;
      if (gap > kParagraphGapMs) {
        paragraphs.add(para);
        para = [];
      }
      para.add(cues[i]);
    }
    paragraphs.add(para);
    return paragraphs;
  }

  // ── chapter XHTML (cue spans; unique to this converter) ───────────────────

  static String _chapterXhtml({
    required String bookTitle,
    required int chapterIndex,
    required int totalChapters,
    required List<AudioCue> cues,
  }) {
    final String chapterLabel = totalChapters > 1
        ? 'Chapter ${chapterIndex + 1}'
        : bookTitle;

    final List<List<AudioCue>> paragraphs = _groupParagraphs(cues);
    final StringBuffer body = StringBuffer();
    for (final List<AudioCue> para in paragraphs) {
      body.write('  <p>\n');
      for (final AudioCue cue in para) {
        final String start = (cue.startMs / 1000).toStringAsFixed(3);
        final String end = (cue.endMs / 1000).toStringAsFixed(3);
        body.write(
          '    <span data-cue-id="${cue.sentenceIndex}"'
          ' data-start="$start"'
          ' data-end="$end">${typesetCueText(cue.text)}</span>\n',
        );
      }
      body.write('  </p>\n');
    }

    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">\n'
        '<head>\n'
        '  <meta charset="utf-8"/>\n'
        '  <title>${_esc(chapterLabel)}</title>\n'
        '  <style type="text/css">body{margin:1em 1.5em;line-height:1.8;}p{margin:0.5em 0;}'
        '.tcy{-webkit-text-combine:horizontal;text-combine-upright:all;}</style>\n'
        '</head>\n'
        '<body>\n'
        '  <h1>${_esc(chapterLabel)}</h1>\n'
        '$body'
        '</body>\n'
        '</html>\n';
  }

  static String _esc(String s) => EpubBuilder.escXml(s);

  /// XML-escapes [text] and wraps each run of one or two half-width `!` / `?`
  /// that directly follows a Japanese character in a `tcy` span (see the class
  /// doc). Longer runs (`!!!`) stay as they are: three glyphs do not fit one
  /// em box. Latin context (`Hello!`) is never touched.
  static String typesetCueText(String text) {
    final StringBuffer out = StringBuffer();
    final List<int> runes = text.runes.toList();
    int i = 0;
    while (i < runes.length) {
      if (!_isBang(runes[i])) {
        out.write(_esc(String.fromCharCode(runes[i])));
        i++;
        continue;
      }
      int j = i;
      while (j < runes.length && _isBang(runes[j])) {
        j++;
      }
      final String run = String.fromCharCodes(runes.sublist(i, j));
      final bool afterJapanese = i > 0 && _isJapanese(runes[i - 1]);
      out.write(
        afterJapanese && j - i <= 2 ? '<span class="tcy">$run</span>' : run,
      );
      i = j;
    }
    return out.toString();
  }

  static bool _isBang(int c) => c == 0x21 || c == 0x3F;

  /// Kana, ー, CJK ideographs, CJK punctuation / brackets, full-width forms.
  static bool _isJapanese(int c) =>
      (c >= 0x3000 && c <= 0x30FF) ||
      (c >= 0x31F0 && c <= 0x31FF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xFF01 && c <= 0xFF9F);
}
