import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/audiobook/text_file_io.dart';

/// Converts plain text files (TXT, HTML, MD, etc.) into valid EPUB 3 bytes
/// suitable for import via [TtuEpubImporter].
class TextToEpub {
  static const int kMaxCharsPerChapter = 30000;

  static const Set<String> supportedExtensions = {
    'txt', 'html', 'htm', 'xhtml', 'md', 'markdown',
    'rst', 'org', 'csv', 'tsv', 'log', 'json', 'xml',
  };

  static bool isSupported(String path) {
    final ext = path.split('.').last.toLowerCase();
    return supportedExtensions.contains(ext);
  }

  /// Reads [file], detects encoding, converts content to EPUB bytes.
  static Future<Uint8List> convert({
    required File file,
    required String title,
    String? author,
  }) async {
    final String content = await readTextWithEncoding(file);
    final String ext = file.path.split('.').last.toLowerCase();
    final List<String> chapters = _splitIntoChapters(content, ext);

    final zip = _EpubZip();
    zip.addStored('mimetype', utf8.encode('application/epub+zip'));
    zip.addDeflated('META-INF/container.xml', utf8.encode(_containerXml()));
    zip.addDeflated(
      'OEBPS/content.opf',
      utf8.encode(_contentOpf(
        title: title,
        author: author,
        chapterCount: chapters.length,
      )),
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
        utf8.encode(_chapterXhtml(
          title: title,
          chapterIndex: i,
          totalChapters: chapters.length,
          bodyHtml: chapters[i],
        )),
      );
    }

    return zip.build();
  }

  // ── Content splitting ─────────────────────────────────────────────────────

  static List<String> _splitIntoChapters(String content, String ext) {
    String html;
    switch (ext) {
      case 'html':
      case 'htm':
      case 'xhtml':
        html = _extractBody(content);
        break;
      case 'md':
      case 'markdown':
        html = _markdownToHtml(content);
        break;
      default:
        html = _plainTextToHtml(content);
        break;
    }

    if (html.length <= kMaxCharsPerChapter) return [html];

    // Split at paragraph boundaries
    final parts = html.split(RegExp(r'(?=<p[ >])'));
    final List<String> chapters = [];
    final buf = StringBuffer();
    for (final part in parts) {
      if (buf.length + part.length > kMaxCharsPerChapter && buf.isNotEmpty) {
        chapters.add(buf.toString());
        buf.clear();
      }
      buf.write(part);
    }
    if (buf.isNotEmpty) chapters.add(buf.toString());
    if (chapters.isEmpty) chapters.add(html);
    return chapters;
  }

  static String _plainTextToHtml(String text) {
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // Remove BOM
    if (text.startsWith('﻿')) text = text.substring(1);

    final paragraphs = text.split(RegExp(r'\n{2,}'));
    final buf = StringBuffer();
    for (final para in paragraphs) {
      final trimmed = para.trim();
      if (trimmed.isEmpty) continue;
      // Preserve single newlines as <br/>
      final escaped = _esc(trimmed).replaceAll('\n', '<br/>');
      buf.write('<p>$escaped</p>\n');
    }
    return buf.isEmpty ? '<p></p>' : buf.toString();
  }

  static String _markdownToHtml(String md) {
    md = md.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (md.startsWith('﻿')) md = md.substring(1);

    final lines = md.split('\n');
    final buf = StringBuffer();
    final paraBuf = StringBuffer();

    void flushPara() {
      if (paraBuf.isNotEmpty) {
        buf.write('<p>${paraBuf.toString().trim()}</p>\n');
        paraBuf.clear();
      }
    }

    for (final line in lines) {
      // Headings
      final hMatch = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
      if (hMatch != null) {
        flushPara();
        final level = hMatch.group(1)!.length;
        buf.write('<h$level>${_esc(hMatch.group(2)!)}</h$level>\n');
        continue;
      }
      // Blank line = paragraph break
      if (line.trim().isEmpty) {
        flushPara();
        continue;
      }
      // Normal text
      if (paraBuf.isNotEmpty) paraBuf.write('<br/>');
      paraBuf.write(_esc(line));
    }
    flushPara();
    return buf.isEmpty ? '<p></p>' : buf.toString();
  }

  static String _extractBody(String html) {
    // Try to extract <body> content
    final bodyMatch =
        RegExp(r'<body[^>]*>([\s\S]*?)</body>', caseSensitive: false)
            .firstMatch(html);
    if (bodyMatch != null) return bodyMatch.group(1)!.trim();
    // If no body tags, use as-is but strip doctype/html/head
    return html
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'</?html[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), '')
        .trim();
  }

  // ── XML/XHTML generators ──────────────────────────────────────────────────

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
    final authorTag = (author != null && author.isNotEmpty)
        ? '\n    <dc:creator>${_esc(author)}</dc:creator>'
        : '';
    final now = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

    final manifest = StringBuffer();
    final spine = StringBuffer();
    for (int i = 1; i <= chapterCount; i++) {
      manifest.write(
          '    <item id="chapter-$i" href="chapter-$i.xhtml"'
          ' media-type="application/xhtml+xml"/>\n');
      spine.write('    <itemref idref="chapter-$i"/>\n');
    }

    final uid = 'hibiki-text-${DateTime.now().millisecondsSinceEpoch}';
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

  static String _tocNcx({required String title, required int chapterCount}) {
    final navPoints = StringBuffer();
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

  static String _navXhtml({required String title, required int chapterCount}) {
    final items = StringBuffer();
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
    required String title,
    required int chapterIndex,
    required int totalChapters,
    required String bodyHtml,
  }) {
    final label = totalChapters > 1 ? 'Chapter ${chapterIndex + 1}' : title;
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">\n'
        '<head>\n'
        '  <meta charset="utf-8"/>\n'
        '  <title>${_esc(label)}</title>\n'
        '  <style type="text/css">body{margin:1em 1.5em;line-height:1.8;}p{margin:0.5em 0;}</style>\n'
        '</head>\n'
        '<body>\n'
        '$bodyHtml'
        '</body>\n'
        '</html>\n';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

// ── Minimal ZIP builder (same as in cues_to_epub.dart) ───────────────────────

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
        method = 0;
      } else {
        compressed = Uint8List.fromList(ZLibCodec(raw: true).encode(entry.data));
        method = 8;
      }

      buf.add(_le32(0x04034b50));
      buf.add(_le16(20));
      buf.add(_le16(0));
      buf.add(_le16(method));
      buf.add(_le16(0));
      buf.add(_le16(0));
      buf.add(_le32(crc));
      buf.add(_le32(compressed.length));
      buf.add(_le32(entry.data.length));
      buf.add(_le16(nameBytes.length));
      buf.add(_le16(0));
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

    final int cdOffset = buf.length;
    for (final rec in locals) {
      buf.add(_le32(0x02014b50));
      buf.add(_le16(20));
      buf.add(_le16(20));
      buf.add(_le16(0));
      buf.add(_le16(rec.method));
      buf.add(_le16(0));
      buf.add(_le16(0));
      buf.add(_le32(rec.crc));
      buf.add(_le32(rec.compressedSize));
      buf.add(_le32(rec.uncompressedSize));
      buf.add(_le16(rec.nameBytes.length));
      buf.add(_le16(0));
      buf.add(_le16(0));
      buf.add(_le16(0));
      buf.add(_le16(0));
      buf.add(_le32(0));
      buf.add(_le32(rec.localOffset));
      buf.add(rec.nameBytes);
    }
    final int cdSize = buf.length - cdOffset;

    buf.add(_le32(0x06054b50));
    buf.add(_le16(0));
    buf.add(_le16(0));
    buf.add(_le16(locals.length));
    buf.add(_le16(locals.length));
    buf.add(_le32(cdSize));
    buf.add(_le32(cdOffset));
    buf.add(_le16(0));

    return buf.toBytes();
  }

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
