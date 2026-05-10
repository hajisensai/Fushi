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

  // Must match JS isFurigana() in reader_pagination_scripts.dart — both
  // sides strip <rt>/<rp> but keep ruby base text so normalized offsets agree.
  static final RegExp _rtRpRegex =
      RegExp(r'<r[tp]c?[^>]*>.*?</r[tp]c?>', caseSensitive: false, dotAll: true);
  static final RegExp _htmlTagRegex = RegExp(r'<[^>]+>');
  static final RegExp _entityRegex = RegExp(r'&(#x([0-9a-fA-F]+)|#([0-9]+)|([a-zA-Z]+));');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  static const Map<String, String> _namedEntities = <String, String>{
    'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
    'nbsp': ' ', 'ensp': ' ', 'emsp': ' ',
    'thinsp': ' ', 'zwnj': '‌', 'zwj': '‍',
    'lrm': '‎', 'rlm': '‏', 'ndash': '–',
    'mdash': '—', 'lsquo': '‘', 'rsquo': '’',
    'ldquo': '“', 'rdquo': '”', 'hellip': '…',
  };

  static String _decodeEntity(Match m) {
    if (m[2] != null) return String.fromCharCode(int.parse(m[2]!, radix: 16));
    if (m[3] != null) return String.fromCharCode(int.parse(m[3]!));
    return _namedEntities[m[4]] ?? m[0]!;
  }

  /// Plain text of chapter at [index], with ruby annotations stripped.
  /// Used by EpubSrtMatcher and sasayaki rematch for audiobook alignment.
  String chapterPlainText(int index) {
    if (index < 0 || index >= chapters.length) return '';
    return chapters[index]
        .html
        .replaceAll(_rtRpRegex, '')
        .replaceAll(_htmlTagRegex, '')
        .replaceAllMapped(_entityRegex, _decodeEntity)
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
