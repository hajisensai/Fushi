import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// Pure Dart EPUB parser — no native FFI, no WebView, no IndexedDB.
///
/// Two entry points:
/// - [parse]: takes raw ZIP bytes, extracts to [extractDir], returns [EpubBook].
/// - [parseFromExtracted]: re-parses an already-extracted directory (e.g. after
///   app restart, when the book is already on disk).
class EpubParser {
  /// Parse EPUB [bytes], extract to [extractDir], return [EpubBook].
  static Future<EpubBook> parse(Uint8List bytes, String extractDir) async {
    return parseSync(bytes, extractDir);
  }

  /// Synchronous parse — safe for use in `compute()` isolates.
  static EpubBook parseSync(Uint8List bytes, String extractDir) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    _extractArchive(archive, extractDir);
    return parseFromExtracted(extractDir);
  }

  /// Parse an already-extracted EPUB directory.
  static EpubBook parseFromExtracted(String extractDir) {
    final File containerFile =
        File(p.join(extractDir, 'META-INF', 'container.xml'));
    if (!containerFile.existsSync()) {
      throw FormatException('Invalid EPUB: missing META-INF/container.xml');
    }
    final XmlDocument containerXml =
        XmlDocument.parse(containerFile.readAsStringSync());
    final String? rootfilePath = _findRootfilePath(containerXml);
    if (rootfilePath == null) {
      throw FormatException('Invalid EPUB: no rootfile in container.xml');
    }

    final File opfFile = File(p.join(extractDir, rootfilePath));
    if (!opfFile.existsSync()) {
      throw FormatException('Invalid EPUB: OPF not found: $rootfilePath');
    }
    final String opfDir = p.dirname(opfFile.path);
    final XmlDocument opfXml = XmlDocument.parse(opfFile.readAsStringSync());

    final Map<String, _ManifestItem> manifest =
        _parseManifest(opfXml, opfDir, extractDir);
    final List<EpubChapter> chapters =
        _parseSpine(opfXml, manifest, opfDir, extractDir);
    if (chapters.isEmpty) {
      throw FormatException('EPUB spine contains no readable chapters');
    }

    final String title =
        _parseMetadata(opfXml, 'title') ?? p.basenameWithoutExtension(extractDir);
    final String? author = _parseMetadata(opfXml, 'creator');
    final String? language = _parseMetadata(opfXml, 'language');
    final String? coverHref =
        _parseCoverHref(opfXml, manifest, opfDir, extractDir);
    final List<EpubTocItem> toc =
        _parseToc(opfXml, manifest, opfDir, extractDir);

    final Map<String, EpubResource> resources = <String, EpubResource>{};
    for (final _ManifestItem item in manifest.values) {
      final String absPath = p.join(opfDir, item.href);
      final String relPath =
          p.relative(absPath, from: extractDir).replaceAll('\\', '/');
      resources[normalizeHref(relPath)] = EpubResource(
        mediaType: item.mediaType,
        filePath: absPath,
      );
    }

    return EpubBook(
      title: title,
      author: author,
      language: language,
      chapters: chapters,
      toc: toc,
      coverHref: coverHref,
      resources: resources,
      rootDirectory: extractDir,
    );
  }

  // ── Extract ────────────────────────────────────────────────────────────────

  static void _extractArchive(Archive archive, String extractDir) {
    final Directory dir = Directory(extractDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final String canonicalBase = p.canonicalize(extractDir);
    for (final ArchiveFile file in archive) {
      final String filePath = p.canonicalize(p.join(extractDir, file.name));
      if (!filePath.startsWith(canonicalBase)) continue;
      if (file.isFile) {
        final File outFile = File(filePath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
      } else {
        Directory(filePath).createSync(recursive: true);
      }
    }
  }

  // ── container.xml ──────────────────────────────────────────────────────────

  static String? _findRootfilePath(XmlDocument container) {
    for (final XmlElement el in container.findAllElements('rootfile')) {
      final String? fullPath = el.getAttribute('full-path');
      if (fullPath != null && fullPath.isNotEmpty) return fullPath;
    }
    return null;
  }

  // ── OPF manifest ───────────────────────────────────────────────────────────

  static Map<String, _ManifestItem> _parseManifest(
    XmlDocument opf,
    String opfDir,
    String extractDir,
  ) {
    final Map<String, _ManifestItem> result = <String, _ManifestItem>{};
    for (final XmlElement item in opf.findAllElements('item')) {
      final String? id = item.getAttribute('id');
      final String? href = item.getAttribute('href');
      final String? mediaType = item.getAttribute('media-type');
      if (id == null || href == null || mediaType == null) continue;
      result[id] = _ManifestItem(
        id: id,
        href: Uri.decodeFull(href),
        mediaType: mediaType,
        properties: item.getAttribute('properties'),
      );
    }
    return result;
  }

  // ── OPF spine ──────────────────────────────────────────────────────────────

  static List<EpubChapter> _parseSpine(
    XmlDocument opf,
    Map<String, _ManifestItem> manifest,
    String opfDir,
    String extractDir,
  ) {
    final List<EpubChapter> chapters = <EpubChapter>[];
    int index = 0;
    for (final XmlElement itemref in opf.findAllElements('itemref')) {
      final String? idref = itemref.getAttribute('idref');
      if (idref == null) continue;
      final _ManifestItem? item = manifest[idref];
      if (item == null) continue;
      if (!_isHtmlMediaType(item.mediaType)) continue;

      final String absPath = p.join(opfDir, item.href);
      final File file = File(absPath);
      if (!file.existsSync()) {
        index++;
        continue;
      }

      final String relPath =
          p.relative(absPath, from: extractDir).replaceAll('\\', '/');
      final String linear =
          itemref.getAttribute('linear')?.toLowerCase() ?? 'yes';

      chapters.add(EpubChapter(
        id: item.id,
        href: normalizeHref(relPath),
        mediaType: item.mediaType,
        html: file.readAsStringSync(),
        spineIndex: index,
        linear: linear != 'no',
      ));
      index++;
    }
    return chapters;
  }

  // ── Metadata ───────────────────────────────────────────────────────────────

  static String? _parseMetadata(XmlDocument opf, String localName) {
    // dc:title, dc:creator etc. — namespace: '*' matches any prefix
    for (final XmlElement el
        in opf.findAllElements(localName, namespace: '*')) {
      final String text = el.innerText.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  // ── Cover ──────────────────────────────────────────────────────────────────

  static String? _parseCoverHref(
    XmlDocument opf,
    Map<String, _ManifestItem> manifest,
    String opfDir,
    String extractDir,
  ) {
    // EPUB 3: manifest item with properties="cover-image"
    for (final _ManifestItem item in manifest.values) {
      if (item.properties != null && item.properties!.contains('cover-image')) {
        return _itemRelHref(item, opfDir, extractDir);
      }
    }
    // EPUB 2: <meta name="cover" content="cover-id"/>
    for (final XmlElement meta in opf.findAllElements('meta')) {
      if (meta.getAttribute('name')?.toLowerCase() == 'cover') {
        final String? coverId = meta.getAttribute('content');
        if (coverId != null && manifest.containsKey(coverId)) {
          return _itemRelHref(manifest[coverId]!, opfDir, extractDir);
        }
      }
    }
    // Fallback: first image resource
    for (final _ManifestItem item in manifest.values) {
      if (item.mediaType.startsWith('image/')) {
        return _itemRelHref(item, opfDir, extractDir);
      }
    }
    return null;
  }

  static String? _itemRelHref(
    _ManifestItem item,
    String opfDir,
    String extractDir,
  ) {
    final String absPath = p.join(opfDir, item.href);
    final String relPath =
        p.relative(absPath, from: extractDir).replaceAll('\\', '/');
    return normalizeHref(relPath);
  }

  // ── TOC ────────────────────────────────────────────────────────────────────

  static List<EpubTocItem> _parseToc(
    XmlDocument opf,
    Map<String, _ManifestItem> manifest,
    String opfDir,
    String extractDir,
  ) {
    // EPUB 3: nav document
    for (final _ManifestItem item in manifest.values) {
      if (item.properties != null && item.properties!.contains('nav')) {
        final File navFile = File(p.join(opfDir, item.href));
        if (navFile.existsSync()) {
          final List<EpubTocItem> toc = _parseNavDoc(
            navFile.readAsStringSync(),
            p.dirname(navFile.path),
            extractDir,
          );
          if (toc.isNotEmpty) return toc;
        }
      }
    }
    // EPUB 2: NCX
    for (final XmlElement spine in opf.findAllElements('spine')) {
      final String? tocId = spine.getAttribute('toc');
      if (tocId != null && manifest.containsKey(tocId)) {
        final _ManifestItem ncxItem = manifest[tocId]!;
        final File ncxFile = File(p.join(opfDir, ncxItem.href));
        if (ncxFile.existsSync()) {
          return _parseNcx(
            ncxFile.readAsStringSync(),
            p.dirname(ncxFile.path),
            extractDir,
          );
        }
      }
    }
    return <EpubTocItem>[];
  }

  /// Parse EPUB 3 nav document (XHTML with <nav epub:type="toc">).
  static List<EpubTocItem> _parseNavDoc(
    String navHtml,
    String navDir,
    String extractDir,
  ) {
    try {
      final XmlDocument doc = XmlDocument.parse(navHtml);
      for (final XmlElement nav in doc.findAllElements('nav')) {
        final String? epubType = nav.getAttribute('type') ??
            nav.getAttribute('epub:type');
        if (epubType == 'toc') {
          final XmlElement? ol = nav.getElement('ol');
          if (ol != null) {
            return _parseNavOl(ol, navDir, extractDir);
          }
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('EpubParser.parseNav', e, stack);
      // Malformed nav doc — fall through to NCX
    }
    return <EpubTocItem>[];
  }

  static List<EpubTocItem> _parseNavOl(
    XmlElement ol,
    String navDir,
    String extractDir,
  ) {
    final List<EpubTocItem> items = <EpubTocItem>[];
    for (final XmlElement li in ol.childElements) {
      if (li.name.local != 'li') continue;
      String? label;
      String? href;
      List<EpubTocItem> children = <EpubTocItem>[];

      for (final XmlElement child in li.childElements) {
        if (child.name.local == 'a') {
          label = child.innerText.trim();
          final String? rawHref = child.getAttribute('href');
          if (rawHref != null) {
            href = _resolveTocHref(rawHref, navDir, extractDir);
          }
        } else if (child.name.local == 'span') {
          label ??= child.innerText.trim();
        } else if (child.name.local == 'ol') {
          children = _parseNavOl(child, navDir, extractDir);
        }
      }

      if (label != null && label.isNotEmpty) {
        items.add(EpubTocItem(
          label: label,
          href: href,
          children: children,
        ));
      }
    }
    return items;
  }

  /// Parse EPUB 2 NCX table of contents.
  static List<EpubTocItem> _parseNcx(
    String ncxContent,
    String ncxDir,
    String extractDir,
  ) {
    try {
      final XmlDocument doc = XmlDocument.parse(ncxContent);
      final Iterable<XmlElement> navMaps = doc.findAllElements('navMap');
      if (navMaps.isEmpty) return <EpubTocItem>[];
      return _parseNavPoints(navMaps.first, ncxDir, extractDir);
    } catch (e, stack) {
      ErrorLogService.instance.log('EpubParser.parseNcx', e, stack);
      return <EpubTocItem>[];
    }
  }

  static List<EpubTocItem> _parseNavPoints(
    XmlElement parent,
    String ncxDir,
    String extractDir,
  ) {
    final List<EpubTocItem> items = <EpubTocItem>[];
    for (final XmlElement navPoint in parent.childElements) {
      if (navPoint.name.local != 'navPoint') continue;

      String label = '';
      String? href;
      for (final XmlElement child in navPoint.childElements) {
        if (child.name.local == 'navLabel') {
          final XmlElement? text = child.getElement('text');
          if (text != null) label = text.innerText.trim();
        } else if (child.name.local == 'content') {
          final String? src = child.getAttribute('src');
          if (src != null) {
            href = _resolveTocHref(src, ncxDir, extractDir);
          }
        }
      }

      final List<EpubTocItem> children =
          _parseNavPoints(navPoint, ncxDir, extractDir);

      if (label.isNotEmpty) {
        items.add(EpubTocItem(
          label: label,
          href: href,
          children: children,
        ));
      }
    }
    return items;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String? _resolveTocHref(
    String rawHref,
    String baseDir,
    String extractDir,
  ) {
    final String cleaned =
        rawHref.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^/'), '');
    if (cleaned.isEmpty) return null;

    final String fragment =
        cleaned.contains('#') ? cleaned.substring(cleaned.indexOf('#')) : '';
    final String base = cleaned.split('#').first.split('?').first;
    if (base.isEmpty) return fragment.isEmpty ? null : fragment;

    final String absPath = p.join(baseDir, base);
    final String relPath =
        p.relative(absPath, from: extractDir).replaceAll('\\', '/');
    final String normalized = normalizeHref(relPath);
    return fragment.isEmpty ? normalized : '$normalized$fragment';
  }

  static bool _isHtmlMediaType(String mediaType) {
    final String lower = mediaType.toLowerCase();
    return lower == 'application/xhtml+xml' ||
        lower == 'text/html' ||
        lower.endsWith('+html');
  }
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    this.properties,
  });

  final String id;
  final String href;
  final String mediaType;
  final String? properties;
}
