import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
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
    this.language,
    this.renditionSpread,
  });

  final String title;
  final String? author;
  final String? language;

  /// Book-level `rendition:spread` value: `landscape`, `both`, `portrait`,
  /// `none`, or `null` when the OPF does not declare one.
  final String? renditionSpread;

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

  // Uses package:html DOM parser — same parsing semantics as the WebView.
  // Entities, nesting, malformed HTML are all handled by the parser, not regex.
  // Must match JS isFurigana() in reader_pagination_scripts.dart: both sides
  // drop <rt>/<rp>/<rtc> content but keep ruby base text.
  /// Plain text of chapter at [index], with ruby annotations stripped.
  /// Used by EpubSrtMatcher and sasayaki rematch for audiobook alignment.
  String chapterPlainText(int index) {
    if (index < 0 || index >= chapters.length) return '';
    final html_dom.Document doc = html_parser.parse(chapters[index].html);
    _removeRubyAnnotations(doc.body);
    final String raw = doc.body?.text ?? '';
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static void _removeRubyAnnotations(html_dom.Element? root) {
    if (root == null) return;
    root.querySelectorAll('rt, rp, rtc').forEach(
          (el) => el.remove(),
        );
  }

  /// True when chapter [index] contains no readable text and exactly one
  /// `<img>` element — i.e. a pure image page (scan, manga, illustration).
  bool isImageOnlyChapter(int index) {
    if (index < 0 || index >= chapters.length) return false;
    if (chapterPlainText(index).isNotEmpty) return false;
    final html_dom.Document doc = html_parser.parse(chapters[index].html);
    return doc.querySelectorAll('img').length == 1;
  }

  /// Extract the `src` attribute of the first `<img>` in chapter [index].
  String? chapterImageSrc(int index) {
    if (index < 0 || index >= chapters.length) return null;
    final html_dom.Document doc = html_parser.parse(chapters[index].html);
    final html_dom.Element? img = doc.querySelector('img');
    return img?.attributes['src'];
  }

  ({int chapterIndex, String? fragment})? resolveInternalLink(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host != ReaderHibikiSource.kHost) return null;
    if (!uri.path.startsWith('/epub/')) return null;

    final String epubPath =
        Uri.decodeComponent(uri.path.substring('/epub/'.length));
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
    this.spreadProperty,
  });

  final String id;
  final String href;
  final String mediaType;
  final String html;
  final int? spineIndex;
  final bool linear;

  /// `page-spread-left`, `page-spread-right`, or `null`.
  final String? spreadProperty;
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
    .replaceFirst(RegExp('^/'), '')
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
