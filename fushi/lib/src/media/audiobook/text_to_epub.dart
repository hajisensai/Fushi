import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi_audio/fushi_audio.dart';

/// Converts plain text files (TXT, HTML, MD, etc.) into valid EPUB 3 bytes
/// suitable for import via [EpubImporter].
///
/// Container assembly (ZIP/OPF/NCX/nav) is shared with [CuesToEpub] via
/// [EpubBuilder]; only the input parsing and chapter body generation live
/// here.
class TextToEpub {
  static const int kMaxCharsPerChapter = 30000;

  static const Set<String> supportedExtensions = {
    'txt',
    'html',
    'htm',
    'xhtml',
    'md',
    'markdown',
    'rst',
    'org',
    'csv',
    'tsv',
    'log',
    'json',
    'xml',
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

    final List<String> chapterXhtmls = <String>[
      for (int i = 0; i < chapters.length; i++)
        _chapterXhtml(
          title: title,
          chapterIndex: i,
          totalChapters: chapters.length,
          bodyHtml: chapters[i],
        ),
    ];

    return EpubBuilder.assemble(
      title: title,
      author: author,
      uidPrefix: 'hibiki-text-',
      chapterXhtmls: chapterXhtmls,
    );
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
    final parts = html.split(RegExp('(?=<p[ >])'));
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
        .replaceAll(RegExp('<!DOCTYPE[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp('</?html[^>]*>', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), '')
        .trim();
  }

  // ── Chapter XHTML (pre-rendered body; unique to this converter) ───────────

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

  static String _esc(String s) => EpubBuilder.escXml(s);
}
