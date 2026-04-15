import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

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
    final List<List<AudioCue>> chapters = _splitChapters(cues);
    final _EpubZip zip = _EpubZip();

    // mimetype MUST be the first entry and stored (no compression) per EPUB spec.
    zip.addStored('mimetype', utf8.encode('application/epub+zip'));

    zip.addDeflated('META-INF/container.xml', utf8.encode(_containerXml()));
    zip.addDeflated(
      'OEBPS/content.opf',
      utf8.encode(
        _contentOpf(title: title, author: author, chapterCount: chapters.length),
      ),
    );
    zip.addDeflated(
      'OEBPS/toc.ncx',
      utf8.encode(_tocNcx(title: title, chapterCount: chapters.length)),
    );
    zip.addDeflated(
      'OEBPS/nav.xhtml',
      utf8.encode(_navXhtml(title: title, chapterCount: chapters.length)),
    );

    for (int i = 0; i < chapters.length; i++) {
      zip.addDeflated(
        'OEBPS/chapter-${i + 1}.xhtml',
        utf8.encode(
          _chapterXhtml(
            bookTitle: title,
            chapterIndex: i,
            totalChapters: chapters.length,
            cues: chapters[i],
          ),
        ),
      );
    }

    final file = File(outputPath);
    await file.writeAsBytes(zip.build(), flush: true);
    return file;
  }

  // ── chapter splitting ─────────────────────────────────────────────────────

  /// Splits [cues] into sub-lists, each within the size/duration thresholds.
  static List<List<AudioCue>> _splitChapters(List<AudioCue> cues) {
    if (cues.isEmpty) {
      return [[]];
    }

    final List<List<AudioCue>> chapters = [];
    List<AudioCue> current = [];
    int chapterStartMs = cues.first.startMs;

    for (final AudioCue cue in cues) {
      final bool tooManyCues = current.length >= kMaxCuesPerChapter;
      final bool tooLong =
          (cue.endMs - chapterStartMs) > kMaxChapterDurationMs;

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

  // ── XML / XHTML generators ────────────────────────────────────────────────

  static String _containerXml() => '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<container version="1.0"'
      ' xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
      '  <rootfiles>\n'
      '    <rootfile full-path="OEBPS/content.opf"'
      ' media-type="application/oebps-package+xml"/>\n'
      '  </rootfiles>\n'
      '</container>\n';

  static String _contentOpf({
    required String title,
    required int chapterCount,
    String? author,
  }) {
    final String authorTag = (author != null && author.isNotEmpty)
        ? '\n    <dc:creator>${_esc(author)}</dc:creator>'
        : '';
    final String now = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

    final StringBuffer manifest = StringBuffer();
    final StringBuffer spine = StringBuffer();
    for (int i = 1; i <= chapterCount; i++) {
      manifest.write(
          '    <item id="chapter-$i" href="chapter-$i.xhtml"'
          ' media-type="application/xhtml+xml"/>\n');
      spine.write('    <itemref idref="chapter-$i"/>\n');
    }

    final String uid = 'hibiki-${DateTime.now().millisecondsSinceEpoch}';
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"\n'
        '         unique-identifier="uid" xml:lang="ja">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '    <dc:identifier id="uid">$uid</dc:identifier>\n'
        '    <dc:title>${_esc(title)}</dc:title>$authorTag\n'
        '    <dc:language>ja</dc:language>\n'
        '    <meta property="dcterms:modified">$now</meta>\n'
        '  </metadata>\n'
        '  <manifest>\n'
        '$manifest'
        '    <item id="nav" href="nav.xhtml"'
        ' media-type="application/xhtml+xml" properties="nav"/>\n'
        '    <item id="ncx" href="toc.ncx"'
        ' media-type="application/x-dtbncx+xml"/>\n'
        '  </manifest>\n'
        '  <spine toc="ncx">\n'
        '$spine'
        '  </spine>\n'
        '</package>\n';
  }

  static String _tocNcx({
    required String title,
    required int chapterCount,
  }) {
    final StringBuffer navPoints = StringBuffer();
    for (int i = 1; i <= chapterCount; i++) {
      navPoints.write(
        '  <navPoint id="chapter-$i" playOrder="$i">\n'
        '    <navLabel><text>Chapter $i</text></navLabel>\n'
        '    <content src="chapter-$i.xhtml"/>\n'
        '  </navPoint>\n',
      );
    }
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"'
        ' "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"'
        ' version="2005-1">\n'
        '  <head>\n'
        '    <meta name="dtb:uid" content="hibiki-toc"/>\n'
        '    <meta name="dtb:depth" content="1"/>\n'
        '  </head>\n'
        '  <docTitle><text>${_esc(title)}</text></docTitle>\n'
        '  <navMap>\n'
        '$navPoints'
        '  </navMap>\n'
        '</ncx>\n';
  }

  static String _navXhtml({
    required String title,
    required int chapterCount,
  }) {
    final StringBuffer items = StringBuffer();
    for (int i = 1; i <= chapterCount; i++) {
      items.write('      <li><a href="chapter-$i.xhtml">Chapter $i</a></li>\n');
    }
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml"'
        ' xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">\n'
        '<head><meta charset="utf-8"/><title>${_esc(title)}</title></head>\n'
        '<body>\n'
        '  <nav epub:type="toc" id="toc">\n'
        '    <ol>\n'
        '$items'
        '    </ol>\n'
        '  </nav>\n'
        '</body>\n'
        '</html>\n';
  }

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
          ' data-end="$end">${_esc(cue.text)}</span>\n',
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
        '  <style type="text/css">body{margin:1em 1.5em;line-height:1.8;}p{margin:0.5em 0;}</style>\n'
        '</head>\n'
        '<body>\n'
        '  <h1>${_esc(chapterLabel)}</h1>\n'
        '$body'
        '</body>\n'
        '</html>\n';
  }

  // ── ttu IndexedDB payload ────────────────────────────────────────────────

  /// Generates the ッツ Ebook Reader IndexedDB payload for [cues].
  ///
  /// The returned [TtuIdbPayload] can be injected into the ttu reader's
  /// "books" IndexedDB via JavaScript to make the book immediately accessible
  /// without a manual file-picker import.
  ///
  /// The `elementHtml` follows the ttu reader's internal format:
  /// each chapter is a `<div id="ttu-chapter-N">` with paragraph/span content.
  /// The `sections` array matches ttu's navigation structure.
  static TtuIdbPayload buildIdbPayload({
    required String title,
    required List<AudioCue> cues,
  }) {
    final List<List<AudioCue>> chapters = _splitChapters(cues);
    final StringBuffer elementHtml = StringBuffer();
    final List<TtuSection> sections = [];
    int totalChars = 0;

    for (int i = 0; i < chapters.length; i++) {
      final String chapterRef = 'ttu-chapter-${i + 1}';
      final String chapterLabel =
          chapters.length > 1 ? 'Chapter ${i + 1}' : title;
      final StringBuffer body = StringBuffer();

      final List<List<AudioCue>> paragraphs = _groupParagraphs(chapters[i]);
      int chapterChars = 0;
      for (final List<AudioCue> para in paragraphs) {
        body.write('<p>');
        for (final AudioCue cue in para) {
          final String start = (cue.startMs / 1000).toStringAsFixed(3);
          final String end = (cue.endMs / 1000).toStringAsFixed(3);
          body.write(
            '<span data-cue-id="${cue.sentenceIndex}"'
            ' data-start="$start"'
            ' data-end="$end">${_esc(cue.text)}</span>',
          );
          chapterChars += cue.text.length;
        }
        body.write('</p>');
      }

      sections.add(TtuSection(
        reference: chapterRef,
        charactersWeight: chapterChars == 0 ? 1 : chapterChars,
        label: chapterLabel,
        startCharacter: totalChars,
      ));
      totalChars += chapterChars;

      elementHtml
        ..write('<div id="$chapterRef">')
        ..write('<h1>${_esc(chapterLabel)}</h1>')
        ..write(body.toString())
        ..write('</div>');
    }

    return TtuIdbPayload(
      title: title,
      styleSheet:
          'body{margin:1em 1.5em;line-height:1.8;}p{margin:0.5em 0;}',
      elementHtml: elementHtml.toString(),
      characters: totalChars == 0 ? 1 : totalChars,
      sections: sections,
      lastBookModified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ── XML escaping ──────────────────────────────────────────────────────────

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

// ── Self-contained ZIP builder ───────────────────────────────────────────────
//
// Implements just enough of the ZIP spec (PKZIP 2.0, APPNOTE.TXT) for EPUB:
//   • STORE  (method 0) for mimetype (required by EPUB spec)
//   • DEFLATE (method 8) for all other files
//
// Uses dart:io ZLibCodec with raw=true for raw DEFLATE output.

class _EpubZip {
  final List<_ZipEntry> _entries = [];

  void addStored(String name, List<int> data) =>
      _entries.add(_ZipEntry(name: name, data: Uint8List.fromList(data), store: true));

  void addDeflated(String name, List<int> data) =>
      _entries.add(_ZipEntry(name: name, data: Uint8List.fromList(data), store: false));

  Uint8List build() {
    final buf = BytesBuilder(copy: false);
    final List<_LocalRecord> locals = [];

    for (final entry in _entries) {
      final int localOffset = buf.length;

      final Uint8List nameBytes = Uint8List.fromList(utf8.encode(entry.name));
      final int crc = _crc32(entry.data);

      Uint8List compressed;
      int method;
      if (entry.store) {
        compressed = entry.data;
        method = 0; // STORE
      } else {
        // raw DEFLATE (wbits = -15)
        compressed = Uint8List.fromList(
          ZLibCodec(raw: true).encode(entry.data),
        );
        method = 8; // DEFLATE
      }

      // Local file header (signature 0x04034b50)
      buf.add(_le32(0x04034b50));
      buf.add(_le16(20)); // version needed: 2.0
      buf.add(_le16(0)); // general purpose bit flag
      buf.add(_le16(method));
      buf.add(_le16(0)); // last mod time
      buf.add(_le16(0)); // last mod date
      buf.add(_le32(crc));
      buf.add(_le32(compressed.length));
      buf.add(_le32(entry.data.length));
      buf.add(_le16(nameBytes.length));
      buf.add(_le16(0)); // extra field length
      buf.add(nameBytes);
      buf.add(compressed);

      locals.add(_LocalRecord(
        nameBytes: nameBytes,
        method: method,
        crc: crc,
        compressedSize: compressed.length,
        uncompressedSize: entry.data.length,
        localOffset: localOffset,
      ));
    }

    // Central directory
    final int cdOffset = buf.length;
    for (final rec in locals) {
      buf.add(_le32(0x02014b50)); // central directory signature
      buf.add(_le16(20)); // version made by
      buf.add(_le16(20)); // version needed
      buf.add(_le16(0)); // general purpose bit flag
      buf.add(_le16(rec.method));
      buf.add(_le16(0)); // last mod time
      buf.add(_le16(0)); // last mod date
      buf.add(_le32(rec.crc));
      buf.add(_le32(rec.compressedSize));
      buf.add(_le32(rec.uncompressedSize));
      buf.add(_le16(rec.nameBytes.length));
      buf.add(_le16(0)); // extra field length
      buf.add(_le16(0)); // file comment length
      buf.add(_le16(0)); // disk number start
      buf.add(_le16(0)); // internal file attributes
      buf.add(_le32(0)); // external file attributes
      buf.add(_le32(rec.localOffset));
      buf.add(rec.nameBytes);
    }
    final int cdSize = buf.length - cdOffset;

    // End of central directory record
    buf.add(_le32(0x06054b50)); // signature
    buf.add(_le16(0)); // disk number
    buf.add(_le16(0)); // disk with start of central directory
    buf.add(_le16(locals.length)); // entries on this disk
    buf.add(_le16(locals.length)); // total entries
    buf.add(_le32(cdSize));
    buf.add(_le32(cdOffset));
    buf.add(_le16(0)); // comment length

    return buf.toBytes();
  }

  // ── CRC-32 (ISO 3309) ────────────────────────────────────────────────────

  static final Uint32List _table = _buildCrcTable();

  static Uint32List _buildCrcTable() {
    final t = Uint32List(256);
    for (int n = 0; n < 256; n++) {
      int c = n;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }

  static int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  // ── Little-endian helpers ─────────────────────────────────────────────────

  static Uint8List _le16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  static Uint8List _le32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}

class _ZipEntry {
  _ZipEntry({required this.name, required this.data, required this.store});
  final String name;
  final Uint8List data;
  final bool store;
}

// ── ttu IndexedDB data classes ───────────────────────────────────────────────

/// A section entry for the ッツ Ebook Reader's IndexedDB navigation structure.
class TtuSection {
  const TtuSection({
    required this.reference,
    required this.charactersWeight,
    required this.label,
    required this.startCharacter,
  });

  /// Element ID of the chapter div, e.g. `"ttu-chapter-1"`.
  final String reference;

  /// Approximate character count for this section (used for progress math).
  final int charactersWeight;

  /// Display label shown in the ttu reader's chapter navigation.
  final String label;

  /// Cumulative character count before this section (0-based).
  final int startCharacter;

  Map<String, dynamic> toJson() => {
        'reference': reference,
        'charactersWeight': charactersWeight,
        'label': label,
        'startCharacter': startCharacter,
      };
}

/// Payload to be inserted into the ッツ Ebook Reader's "books" IndexedDB.
class TtuIdbPayload {
  const TtuIdbPayload({
    required this.title,
    required this.styleSheet,
    required this.elementHtml,
    required this.characters,
    required this.sections,
    required this.lastBookModified,
  });

  final String title;
  final String styleSheet;

  /// All chapters concatenated as `<div id="ttu-chapter-N">...</div>`.
  final String elementHtml;

  /// Total character count (used for reading-progress percentage).
  final int characters;

  final List<TtuSection> sections;
  final int lastBookModified;

  Map<String, dynamic> toJson() => {
        'title': title,
        'hasThumb': false,
        'styleSheet': styleSheet,
        'elementHtml': elementHtml,
        'blobs': <String, dynamic>{},
        'characters': characters,
        'sections': sections.map((s) => s.toJson()).toList(),
        'lastBookModified': lastBookModified,
        'lastBookOpen': 0,
      };
}

class _LocalRecord {
  _LocalRecord({
    required this.nameBytes,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
  });
  final Uint8List nameBytes;
  final int method;
  final int crc;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
}
