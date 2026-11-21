import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi_audio/fushi_audio_core.dart';

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
  ///
  /// 解码留在调用方 isolate（平台字符集检测器只装配在主 isolate；超过 8 KB 的
  /// 本地编码解码自己会进后台 isolate），切章 + XHTML 拼装 + ZIP 压缩这段与输入
  /// 大小成正比的同步重活交给 [convertTextInBackground]，几 MB 的 TXT 导入时
  /// UI isolate 不再整段卡住。
  static Future<Uint8List> convert({
    required File file,
    required String title,
    String? author,
  }) async {
    final String content = await readTextWithEncoding(file);
    final String ext = file.path.split('.').last.toLowerCase();
    return convertTextInBackground(
      content: content,
      title: title,
      author: author,
      extension: ext,
    );
  }

  /// [convertText] 放到一次性后台 isolate 里跑。输出与 [convertText] 逐字节
  /// 相同（同一个函数），产物经 `Isolate.exit` 交回、不再复制一遍。
  static Future<Uint8List> convertTextInBackground({
    required String content,
    required String title,
    String? author,
    String extension = 'txt',
  }) => Isolate.run<Uint8List>(
    () => convertText(
      content: content,
      title: title,
      author: author,
      extension: extension,
    ),
    debugName: 'TextToEpub.convert',
  );

  /// Converts in-memory [content] (already decoded, e.g. pasted from the
  /// clipboard) to EPUB bytes. [extension] picks the parser exactly like the
  /// file path's extension does in [convert] (`txt` = plain text paragraphs).
  static Uint8List convertText({
    required String content,
    required String title,
    String? author,
    String extension = 'txt',
  }) {
    final List<String> chapters = _splitIntoChapters(
      content,
      extension.toLowerCase(),
    );

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
      uidPrefix: 'fushi-text-',
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
      for (final String chunk in _splitPlainTextParagraph(escaped)) {
        buf.write('<p>$chunk</p>\n');
      }
    }
    return buf.isEmpty ? '<p></p>' : buf.toString();
  }

  /// Bound even a paragraph with no blank lines before the chapter packer runs.
  /// Count the generated HTML, including its paragraph wrapper, and keep XML
  /// entities, line breaks and Unicode code points intact at every boundary.
  static Iterable<String> _splitPlainTextParagraph(String escaped) sync* {
    final int maxContentLength = kMaxCharsPerChapter - '<p></p>\n'.length;
    if (escaped.length <= maxContentLength) {
      yield escaped;
      return;
    }

    final RegExp tokens = RegExp(
      r'&(?:amp|lt|gt|quot|apos);|<br/>|.',
      unicode: true,
      dotAll: true,
    );
    int start = 0;
    for (final RegExpMatch token in tokens.allMatches(escaped)) {
      if (token.end - start > maxContentLength) {
        yield escaped.substring(start, token.start);
        start = token.start;
      }
    }
    if (start < escaped.length) yield escaped.substring(start);
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
    final bodyMatch = RegExp(
      r'<body[^>]*>([\s\S]*?)</body>',
      caseSensitive: false,
    ).firstMatch(html);
    if (bodyMatch != null) return bodyMatch.group(1)!.trim();
    // If no body tags, use as-is but strip doctype/html/head
    return html
        .replaceAll(RegExp('<!DOCTYPE[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp('</?html[^>]*>', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false),
          '',
        )
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
