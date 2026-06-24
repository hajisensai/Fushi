import 'dart:convert';
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

    final String epubPath = _canonicalEpubPath(
        _decodeHrefPath(uri.path.substring('/epub/'.length)));
    final String? fragment = uri.fragment.isNotEmpty ? uri.fragment : null;

    for (int i = 0; i < chapters.length; i++) {
      if (_canonicalEpubPath(chapters[i].href) == epubPath) {
        return (chapterIndex: i, fragment: fragment);
      }
    }

    return null;
  }

  /// TODO-796: maps a stored TOC `href` (a spine-relative path that may carry a
  /// `#fragment`, percent escapes, `./`/`../` segments, or case differences from
  /// the spine chapter href) to its spine chapter index, or -1 when no spine
  /// chapter owns it.
  ///
  /// The TOC sheet previously matched with a raw `==` against the stored chapter
  /// href ([_tocHrefToChapterIndex]), a *different* standard than
  /// [resolveInternalLink]'s [_canonicalEpubPath] comparison. A cover/front-
  /// matter TOC entry whose href differed only by `./` / `%xx` / letter case
  /// then resolved to -1 and was silently dropped from the flattened TOC, so the
  /// real first chapter slid into row 0 — clicking "Cover" jumped to chapter 1.
  ///
  /// This reuses the one canonicalization standard (so link resolution and TOC
  /// matching can never disagree) and, only when the exact-canonical pass finds
  /// nothing, falls back to a case-insensitive canonical pass. Case folding is
  /// kept out of [_canonicalEpubPath] itself so [resolveInternalLink] still
  /// honours case-sensitive filesystems; the fallback is TOC-local and only ever
  /// recovers an otherwise-dropped entry — it never reroutes a path that already
  /// matched exactly.
  int chapterIndexForHref(String? href) {
    if (href == null) return -1;
    final String base = normalizeHref(href);
    if (base.isEmpty) return -1;
    final String target = _canonicalEpubPath(_decodeHrefPath(base));
    if (target.isEmpty) return -1;

    for (int i = 0; i < chapters.length; i++) {
      if (_canonicalEpubPath(chapters[i].href) == target) {
        return i;
      }
    }
    final String targetLower = target.toLowerCase();
    for (int i = 0; i < chapters.length; i++) {
      if (_canonicalEpubPath(chapters[i].href).toLowerCase() == targetLower) {
        return i;
      }
    }
    return -1;
  }

  /// TODO-807：章节 [index] 是否为 EPUB 导航/目录文档（见 [EpubChapter.isNav]）。
  /// 越界返回 false。有声书被动跨章跟随据此跳过目录页。
  bool isChapterNav(int index) {
    if (index < 0 || index >= chapters.length) return false;
    return chapters[index].isNav;
  }

  /// Percent-decodes a href path, degrading to the raw value on malformed
  /// escapes (a TOC `src` is untrusted input — a stray `%` must not abort the
  /// whole jump). Mirrors the percent-decoding [EpubParser] applies at parse
  /// time so both sides of the comparison are decoded.
  static String _decodeHrefPath(String path) {
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    }
  }

  // BUG-097: the WebView resolves a relative `<a href>` against the current
  // document URL, so the clicked link's path can carry `./` / `../` / duplicate
  // slashes that the stored chapter href (canonicalized at parse time) does not.
  // A strict `==` then missed legitimate internal links → the caller fell back
  // to opening `https://hoshi.local/...` in the OS browser (blank page) instead
  // of jumping. Canonicalize both sides (POSIX, slash-style agnostic) so the
  // comparison is symmetric regardless of redundant path segments.
  static String _canonicalEpubPath(String path) {
    final String normalized = normalizeHref(path);
    if (normalized.isEmpty) return normalized;
    return p.posix.normalize(normalized);
  }
}

class EpubChapter {
  /// Eager constructor — [html] is already in memory. Used by DB-metadata /
  /// legacy fallbacks, audiobook import dialogs, and tests.
  EpubChapter({
    required this.id,
    required this.href,
    required this.mediaType,
    required String html,
    this.spineIndex,
    this.linear = true,
    this.spreadProperty,
    this.isNav = false,
  })  : _eagerHtml = html,
        _filePath = null;

  /// TODO-296: lazy constructor — chapter XHTML is read + decoded from
  /// [filePath] on first [html] access and cached, instead of slurping every
  /// spine chapter into memory at parse/open time. The WebView already serves
  /// chapter bodies straight from disk (reader intercept), so the only in-memory
  /// consumers are [chapterPlainText]/search/spread analysis — all of which now
  /// pull the same on-disk bytes on demand, keeping the rendered/aligned text
  /// byte-identical while bounding open-book heap and latency.
  EpubChapter.lazy({
    required this.id,
    required this.href,
    required this.mediaType,
    required String filePath,
    this.spineIndex,
    this.linear = true,
    this.spreadProperty,
    this.isNav = false,
  })  : _eagerHtml = null,
        _filePath = filePath;

  final String id;
  final String href;
  final String mediaType;
  final int? spineIndex;
  final bool linear;

  /// `page-spread-left`, `page-spread-right`, or `null`.
  final String? spreadProperty;

  /// TODO-807：该 spine 项是 EPUB 导航/目录文档（`properties="nav"` /
  /// `epub:type="toc"`）或封面页——日文 EPUB 常把目录页作为 spine 首个 linear
  /// 项，于是 `chapters[0]` 就是目录页。有声书被动跨章跟随时不能把这种页当作
  /// 导航目标（会跳到目录），但它已被序列化进 DB chaptersJson（按 index 寻
  /// 址），物理删除会移位既有书的存储 index，故保留该项、只打标记，导航逻辑
  /// 跳过它。默认 false（DB 回退路径 / 旧测试构造的章节天然为正文，保持原
  /// 行为）。
  final bool isNav;

  final String? _eagerHtml;
  final String? _filePath;
  String? _lazyHtml;

  /// Chapter XHTML source. For lazy chapters this reads + decodes [_filePath]
  /// on first access and caches the result; a missing file degrades to `''`
  /// (matches the DB-fallback builder contract) rather than throwing.
  String get html {
    final String? eager = _eagerHtml;
    if (eager != null) return eager;
    return _lazyHtml ??= _readChapterFile(_filePath);
  }

  static String _readChapterFile(String? filePath) {
    if (filePath == null) return '';
    final File file = File(filePath);
    if (!file.existsSync()) return '';
    return decodeEpubText(file.readAsBytesSync());
  }
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

/// Decodes EPUB text-file bytes as UTF-8, degrading gracefully instead of
/// throwing on non-UTF-8 input. EPUB mandates UTF-8 for its XML, but legacy
/// Japanese books/raw XHTML sometimes carry Shift_JIS/EUC-JP; strict utf8
/// decoding would throw FormatException and abort the whole load
/// (HBK-AUDIT-033). A UTF-8 BOM is stripped; malformed bytes become U+FFFD.
///
/// Single source of truth shared by [EpubParser] (structure parse) and
/// [EpubChapter.html] (TODO-296 lazy read) so eager and lazy chapter text are
/// byte-identical.
String decodeEpubText(List<int> rawBytes) {
  List<int> bytes = rawBytes;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    bytes = bytes.sublist(3);
  }
  return utf8.decode(bytes, allowMalformed: true);
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
