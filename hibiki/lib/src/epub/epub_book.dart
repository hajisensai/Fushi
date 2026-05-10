import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
import 'package:path/path.dart' as p;

class EpubBook {
  EpubBook({
    required this.title,
    required this.chapters,
    this.toc = const [],
    this.coverHref,
    this.resources = const {},
    this.rootDirectory,
    this.author,
  });

  final String title;
  final String? author;
  final List<EpubChapter> chapters;
  final List<EpubTocItem> toc;
  final String? coverHref;
  final Map<String, EpubResource> resources;
  final String? rootDirectory;

  Uint8List? readResource(String path) {
    final String normalized = normalizeHref(path);
    final EpubResource? resource = resources[normalized];
    if (resource != null) return resource.readBytes();
    if (rootDirectory == null) return null;
    final File file = File(p.join(rootDirectory!, normalized));
    if (file.existsSync()) return file.readAsBytesSync();
    return null;
  }

  String mediaType(String path) {
    return resources[normalizeHref(path)]?.mediaType ?? fallbackMimeType(path);
  }

  static final RegExp _rtRpRegex =
      RegExp(r'<r[tp][^>]*>.*?</r[tp]>', dotAll: true);
  static final RegExp _htmlTagRegex = RegExp(r'<[^>]+>');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// Plain text of chapter at [index], with ruby annotations stripped.
  /// Used by EpubSrtMatcher and sasayaki rematch for audiobook alignment.
  String chapterPlainText(int index) {
    if (index < 0 || index >= chapters.length) return '';
    return chapters[index]
        .html
        .replaceAll(_rtRpRegex, '')
        .replaceAll(_htmlTagRegex, '')
        .replaceAll(_whitespaceRegex, ' ')
        .trim();
  }

  ({int chapterIndex, String? fragment})? resolveInternalLink(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host != ReaderHoshiSource.kHost) return null;
    if (!uri.path.startsWith('/epub/')) return null;

    final String epubPath = Uri.decodeComponent(uri.path.substring('/epub/'.length));
    final String? fragment = uri.fragment.isNotEmpty ? uri.fragment : null;

    for (int i = 0; i < chapters.length; i++) {
      if (chapters[i].href == epubPath) {
        return (chapterIndex: i, fragment: fragment);
      }
    }

    return null;
  }
}

class EpubChapter {
  EpubChapter({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.html,
    this.spineIndex,
    this.linear = true,
  });

  final String id;
  final String href;
  final String mediaType;
  final String html;
  final int? spineIndex;
  final bool linear;
}

class EpubTocItem {
  EpubTocItem({required this.label, this.href, this.children = const []});

  final String label;
  final String? href;
  final List<EpubTocItem> children;
}

class EpubResource {
  EpubResource({required this.mediaType, this.bytes, this.filePath});

  final String mediaType;
  final Uint8List? bytes;
  final String? filePath;

  Uint8List? readBytes() {
    if (bytes != null) return bytes;
    if (filePath == null) return null;
    final File file = File(filePath!);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }
}

String normalizeHref(String href) => href
    .trim()
    .replaceAll('\\', '/')
    .replaceFirst(RegExp(r'^/'), '')
    .split('#')
    .first
    .split('?')
    .first;

String fallbackMimeType(String path) {
  switch (p.extension(path).toLowerCase()) {
    case '.css':
      return 'text/css';
    case '.js':
      return 'application/javascript';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.svg':
      return 'image/svg+xml';
    case '.xhtml':
    case '.html':
      return 'text/html';
    case '.woff':
      return 'font/woff';
    case '.woff2':
      return 'font/woff2';
    case '.ttf':
      return 'font/ttf';
    case '.otf':
      return 'font/otf';
    default:
      return 'application/octet-stream';
  }
}
