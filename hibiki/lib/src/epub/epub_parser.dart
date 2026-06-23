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
/// - [parse]: takes raw ZIP bytes, extracts to `extractDir`, returns [EpubBook].
/// - [parseFromExtracted]: re-parses an already-extracted directory (e.g. after
///   app restart, when the book is already on disk).
class EpubParser {
  /// Parse EPUB [bytes], extract to [extractDir], return [EpubBook].
  static Future<EpubBook> parse(Uint8List bytes, String extractDir) async {
    return parseSync(bytes, extractDir);
  }

  /// Synchronous parse — safe for use in `compute()` isolates.
  static EpubBook parseSync(Uint8List bytes, String extractDir) {
    // HBK-AUDIT-106: verify: true enables per-entry CRC32 checks so a corrupt
    // deflate stream surfaces as an error instead of being extracted as silent
    // garbage (mojibake / broken images).
    final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);
    _extractArchive(archive, extractDir);
    return parseFromExtracted(extractDir);
  }

  /// Read file from [filePath] and parse — for isolate use to avoid
  /// serializing large byte arrays across the isolate boundary.
  static EpubBook parseSyncFromPath(String filePath, String extractDir) {
    final Uint8List bytes = File(filePath).readAsBytesSync();
    // HBK-AUDIT-106: see parseSync — CRC verification on extraction.
    final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);
    _extractArchive(archive, extractDir);
    return parseFromExtracted(extractDir);
  }

  /// Parse an already-extracted EPUB directory.
  static EpubBook parseFromExtracted(String extractDir) {
    final File? containerFile = _findContainerXml(extractDir);
    if (containerFile == null) {
      throw const FormatException(
          'Invalid EPUB: missing META-INF/container.xml');
    }
    final XmlDocument containerXml =
        XmlDocument.parse(_readText(containerFile));
    final String? rootfilePath = _findRootfilePath(containerXml);
    if (rootfilePath == null) {
      throw const FormatException('Invalid EPUB: no rootfile in container.xml');
    }

    final File opfFile = File(p.join(extractDir, rootfilePath));
    if (!opfFile.existsSync()) {
      throw FormatException('Invalid EPUB: OPF not found: $rootfilePath');
    }
    final String opfDir = p.dirname(opfFile.path);
    final XmlDocument opfXml = XmlDocument.parse(_readText(opfFile));

    final Map<String, _ManifestItem> manifest =
        _parseManifest(opfXml, opfDir, extractDir);
    final List<EpubChapter> chapters =
        _parseSpine(opfXml, manifest, opfDir, extractDir);
    if (chapters.isEmpty) {
      throw const FormatException('EPUB spine contains no readable chapters');
    }

    final String title = _parseMetadata(opfXml, 'title') ??
        p.basenameWithoutExtension(extractDir);
    final String? author = _parseMetadata(opfXml, 'creator');
    final String? language = _parseMetadata(opfXml, 'language');
    final String? coverHref =
        _parseCoverHref(opfXml, manifest, opfDir, extractDir);
    final List<EpubTocItem> toc =
        _parseToc(opfXml, manifest, opfDir, extractDir);
    final String? renditionSpread = _parseRenditionSpread(opfXml);

    final String canonExtract = p.canonicalize(extractDir);
    final Map<String, EpubResource> resources = <String, EpubResource>{};
    for (final _ManifestItem item in manifest.values) {
      final String absPath = p.canonicalize(p.join(opfDir, item.href));
      if (!p.isWithin(canonExtract, absPath)) {
        continue;
      }
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
      renditionSpread: renditionSpread,
    );
  }

  // ── Extract ────────────────────────────────────────────────────────────────

  static void _extractArchive(Archive archive, String extractDir) {
    final Directory dir = Directory(extractDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final String canonicalBase = p.canonicalize(extractDir);
    final Set<String> archiveDirectories =
        _archiveDirectoryPaths(archive, extractDir, canonicalBase);
    for (final ArchiveFile file in archive) {
      final String? filePath =
          _safeArchivePath(extractDir, canonicalBase, file.name);
      if (filePath == null) {
        continue;
      }
      if (file.isFile && !archiveDirectories.contains(filePath)) {
        final File outFile = File(filePath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
      } else {
        _ensureDirectory(filePath);
      }
    }

    // HBK-AUDIT-102: release the decompressed/raw byte buffers cached on each
    // ArchiveFile (and the source InputStream views) instead of waiting for GC.
    // For large image-heavy manga EPUBs this bounds the import-time peak heap
    // and avoids OOM pressure inside the compute() isolate.
    archive.clearSync();
  }

  // NOTE on HBK-AUDIT-034: the audit suggested only treating EXPLICIT non-file
  // entries as directories. That regresses valid EPUBs: many archives mark a
  // directory with a zero-byte FILE entry (e.g. "META-INF" with no trailing
  // slash, isFile==true) that is also the parent of real entries. A path that
  // is the parent of another entry MUST be a directory on the filesystem — a
  // path cannot be both a file and a directory — so the "file with content
  // that is also a parent" case the audit describes is unrepresentable for a
  // valid archive. Treating implied parents as directories is therefore
  // correct and is kept.
  static Set<String> _archiveDirectoryPaths(
    Archive archive,
    String extractDir,
    String canonicalBase,
  ) {
    final Set<String> directories = <String>{};
    for (final ArchiveFile file in archive) {
      final String? filePath =
          _safeArchivePath(extractDir, canonicalBase, file.name);
      if (filePath == null) {
        continue;
      }
      if (!file.isFile) {
        directories.add(filePath);
      }
      _addParentDirectories(directories, filePath, canonicalBase);
    }
    return directories;
  }

  static String? _safeArchivePath(
    String extractDir,
    String canonicalBase,
    String name,
  ) {
    // TODO-739: the zip-slip boundary check and the on-disk write path must use
    // DIFFERENT forms of the joined path. p.canonicalize lower-cases the whole
    // path on case-insensitive platforms (Windows), so using its result as the
    // real write path stored 'META-INF/container.xml' on disk as 'meta-inf/...'.
    // When a Windows host re-packages the extract dir (repackageExtractedEpub)
    // and ships it to a case-sensitive peer (Android/Linux), the peer extracts a
    // lower-cased 'meta-inf' and parseFromExtracted can no longer find the
    // upper-case 'META-INF/container.xml' -> FormatException.
    //
    // Fix: keep full zip-slip protection by validating the boundary with the
    // canonicalized path (a '../' or absolute entry escaping extractDir is still
    // rejected), but write to disk using the case-preserving joined path.
    final String joined = p.join(extractDir, name);
    // p.normalize collapses '.'/'..' segments WITHOUT lower-casing, so the
    // case-sensitive boundary check below still rejects a traversal entry.
    final String normalized = p.normalize(joined);
    if (!p.isWithin(canonicalBase, p.canonicalize(joined)) ||
        !p.isWithin(p.normalize(extractDir), normalized)) {
      return null;
    }
    return normalized;
  }

  static void _addParentDirectories(
    Set<String> directories,
    String filePath,
    String canonicalBase,
  ) {
    String parent = p.dirname(filePath);
    while (p.isWithin(canonicalBase, parent)) {
      directories.add(parent);
      final String next = p.dirname(parent);
      if (next == parent) {
        return;
      }
      parent = next;
    }
  }

  static void _ensureDirectory(String path) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
      File(path).deleteSync();
    }
    Directory(path).createSync(recursive: true);
  }

  // ── container.xml ──────────────────────────────────────────────────────────

  /// Locate `META-INF/container.xml` under [extractDir] with case-insensitive
  /// matching on both path segments.
  ///
  /// TODO-739: the canonical EPUB layout is upper-case `META-INF/container.xml`,
  /// and the extraction side ([_safeArchivePath]) now preserves the archive
  /// entry case. But books that were extracted by older builds (which
  /// lower-cased the path via `p.canonicalize`) sit on disk as
  /// `meta-inf/container.xml`. When such a book is opened on a case-sensitive
  /// filesystem after a re-extraction, an exact upper-case lookup would fail.
  /// Scanning the directory for a case-insensitive match rescues those legacy
  /// extractions without weakening the on-disk fix.
  static File? _findContainerXml(String extractDir) {
    // Fast path: the spec-correct upper-case location.
    final File exact = File(p.join(extractDir, 'META-INF', 'container.xml'));
    if (exact.existsSync()) {
      return exact;
    }
    final Directory? metaInf = _findChildDir(extractDir, 'META-INF');
    if (metaInf == null) {
      return null;
    }
    return _findChildFile(metaInf.path, 'container.xml');
  }

  /// Returns the child directory of [parentDir] whose name equals [name]
  /// ignoring case, or null if none exists. Prefers an exact-case match.
  static Directory? _findChildDir(String parentDir, String name) {
    final Directory parent = Directory(parentDir);
    if (!parent.existsSync()) {
      return null;
    }
    final String lower = name.toLowerCase();
    Directory? caseInsensitiveHit;
    for (final FileSystemEntity entity in parent.listSync(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final String base = p.basename(entity.path);
      if (base == name) {
        return entity;
      }
      if (caseInsensitiveHit == null && base.toLowerCase() == lower) {
        caseInsensitiveHit = entity;
      }
    }
    return caseInsensitiveHit;
  }

  /// Returns the child file of [parentDir] whose name equals [name] ignoring
  /// case, or null if none exists. Prefers an exact-case match.
  static File? _findChildFile(String parentDir, String name) {
    final Directory parent = Directory(parentDir);
    if (!parent.existsSync()) {
      return null;
    }
    final String lower = name.toLowerCase();
    File? caseInsensitiveHit;
    for (final FileSystemEntity entity in parent.listSync(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final String base = p.basename(entity.path);
      if (base == name) {
        return entity;
      }
      if (caseInsensitiveHit == null && base.toLowerCase() == lower) {
        caseInsensitiveHit = entity;
      }
    }
    return caseInsensitiveHit;
  }

  static String? _findRootfilePath(XmlDocument container) {
    for (final XmlElement el in container.findAllElements('rootfile')) {
      final String? fullPath = el.getAttribute('full-path');
      if (fullPath != null && fullPath.isNotEmpty) {
        // Percent-decode to match the decoded manifest/chapter hrefs
        // (HBK-AUDIT-010).
        return _decodeHrefPath(fullPath);
      }
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
      if (id == null || href == null || mediaType == null) {
        continue;
      }
      result[id] = _ManifestItem(
        id: id,
        href: _decodeHrefPath(href),
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
    // HBK-AUDIT-103: spineIndex must reflect the itemref's true position in the
    // spine. The ordinal is derived from the itemref's index in the document
    // (`asMap()`), so it increments exactly once per itemref regardless of
    // which skip branch a malformed/non-HTML entry takes — the previous code
    // incremented `index` on only some `continue` paths, producing
    // inconsistent stored values.
    final List<XmlElement> itemrefs =
        opf.findAllElements('itemref').toList(growable: false);
    for (int index = 0; index < itemrefs.length; index++) {
      final XmlElement itemref = itemrefs[index];
      final String? idref = itemref.getAttribute('idref');
      if (idref == null) {
        continue;
      }
      final _ManifestItem? item = manifest[idref];
      if (item == null) {
        continue;
      }
      if (!_isHtmlMediaType(item.mediaType)) {
        continue;
      }

      final String absPath = p.canonicalize(p.join(opfDir, item.href));
      if (!p.isWithin(p.canonicalize(extractDir), absPath)) {
        continue;
      }
      final File file = File(absPath);
      if (!file.existsSync()) {
        continue;
      }

      final String relPath =
          p.relative(absPath, from: extractDir).replaceAll('\\', '/');
      final String linear =
          itemref.getAttribute('linear')?.toLowerCase() ?? 'yes';

      final String? properties = itemref.getAttribute('properties');
      String? spreadProperty;
      if (properties != null) {
        if (properties.contains('page-spread-left')) {
          spreadProperty = 'page-spread-left';
        } else if (properties.contains('page-spread-right')) {
          spreadProperty = 'page-spread-right';
        }
      }

      // TODO-296: defer the chapter XHTML read. _parseSpine still verifies the
      // file exists above, but the bytes are read + decoded lazily on first
      // [EpubChapter.html] access — open-book no longer slurps the whole book.
      chapters.add(EpubChapter.lazy(
        id: item.id,
        href: normalizeHref(relPath),
        mediaType: item.mediaType,
        filePath: absPath,
        spineIndex: index,
        linear: linear != 'no',
        spreadProperty: spreadProperty,
      ));
    }
    return chapters;
  }

  // ── Metadata ───────────────────────────────────────────────────────────────

  static String? _parseMetadata(XmlDocument opf, String localName) {
    // dc:title, dc:creator etc. — namespace: '*' matches any prefix
    for (final XmlElement el
        in opf.findAllElements(localName, namespace: '*')) {
      final String text = el.innerText.trim();
      if (text.isNotEmpty) {
        return text;
      }
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
    final String absPath = p.canonicalize(p.join(opfDir, item.href));
    if (!p.isWithin(p.canonicalize(extractDir), absPath)) {
      return null;
    }
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
        final String navPath = p.canonicalize(p.join(opfDir, item.href));
        if (!p.isWithin(p.canonicalize(extractDir), navPath)) {
          continue;
        }
        final File navFile = File(navPath);
        if (navFile.existsSync()) {
          final List<EpubTocItem> toc = _parseNavDoc(
            _readText(navFile),
            p.dirname(navFile.path),
            extractDir,
          );
          if (toc.isNotEmpty) {
            return toc;
          }
        }
      }
    }
    // EPUB 2: NCX
    for (final XmlElement spine in opf.findAllElements('spine')) {
      final String? tocId = spine.getAttribute('toc');
      if (tocId != null && manifest.containsKey(tocId)) {
        final _ManifestItem ncxItem = manifest[tocId]!;
        final String ncxPath = p.canonicalize(p.join(opfDir, ncxItem.href));
        if (!p.isWithin(p.canonicalize(extractDir), ncxPath)) {
          return <EpubTocItem>[];
        }
        final File ncxFile = File(ncxPath);
        if (ncxFile.existsSync()) {
          return _parseNcx(
            _readText(ncxFile),
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
        final String? epubType =
            nav.getAttribute('type') ?? nav.getAttribute('epub:type');
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
      if (li.name.local != 'li') {
        continue;
      }
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
      if (navMaps.isEmpty) {
        return <EpubTocItem>[];
      }
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
      if (navPoint.name.local != 'navPoint') {
        continue;
      }

      String label = '';
      String? href;
      for (final XmlElement child in navPoint.childElements) {
        if (child.name.local == 'navLabel') {
          final XmlElement? text = child.getElement('text');
          if (text != null) {
            label = text.innerText.trim();
          }
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
        rawHref.trim().replaceAll('\\', '/').replaceFirst(RegExp('^/'), '');
    if (cleaned.isEmpty) {
      return null;
    }

    final String fragment =
        cleaned.contains('#') ? cleaned.substring(cleaned.indexOf('#')) : '';
    final String base = cleaned.split('#').first.split('?').first;
    if (base.isEmpty) {
      return fragment.isEmpty ? null : fragment;
    }

    // Manifest/chapter hrefs are percent-decoded (_parseManifest), but TOC
    // src/href were not — a TOC pointing at %E7%AC%AC1.xhtml then never matched
    // the decoded chapter key. Decode the path part here too (HBK-AUDIT-010).
    final String absPath = p.join(baseDir, _decodeHrefPath(base));
    final String relPath =
        p.relative(absPath, from: extractDir).replaceAll('\\', '/');
    final String normalized = normalizeHref(relPath);
    return fragment.isEmpty ? normalized : '$normalized$fragment';
  }

  static String? _parseRenditionSpread(XmlDocument opf) {
    for (final XmlElement meta in opf.findAllElements('meta')) {
      final String? property = meta.getAttribute('property');
      if (property == 'rendition:spread') {
        final String value = meta.innerText.trim().toLowerCase();
        if (const {'landscape', 'both', 'portrait', 'none'}.contains(value)) {
          return value;
        }
      }
    }
    return null;
  }

  /// Reads a text file with the shared UTF-8/BOM-tolerant decoder
  /// ([decodeEpubText], HBK-AUDIT-033) used by both structure parse and the
  /// TODO-296 lazy chapter read.
  static String _readText(File file) {
    return decodeEpubText(file.readAsBytesSync());
  }

  /// Percent-decodes an href/path, tolerating malformed sequences (a literal
  /// '%' that is not valid percent-encoding) by returning the raw input rather
  /// than throwing ArgumentError and aborting the parse.
  static String _decodeHrefPath(String href) {
    try {
      return Uri.decodeFull(href);
    } on ArgumentError {
      return href;
    }
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
