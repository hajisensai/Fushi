import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio_core.dart' show EpubBuilder, EpubZip;

/// EPUB 里的一张图片（封面或章节插图）。
typedef LnReaderEpubImage = ({
  String fileName,
  Uint8List bytes,
  String mediaType,
});

/// 解压树里的目录三件套：`OEBPS/content.opf`、`OEBPS/toc.ncx`、`OEBPS/nav.xhtml`
/// 的全文。
typedef LnReaderPackageDocuments = ({String opf, String ncx, String nav});

/// 一章：标题 + 规整好的 XHTML 片段（`<body>` 内部）+ 它引用的图片。
typedef LnReaderEpubChapter = ({
  String title,
  String xhtmlBody,
  List<LnReaderEpubImage> images,
});

/// 把 LNReader 抓下来的章节打成 EPUB 3。
///
/// 与 `EpubBuilder.assemble` 共用 ZIP 打包器与 XML 转义，但自己出 OPF / NCX /
/// nav：网文要**章节标题进目录**、要封面、要章内插图，而那个通用装配器只按
/// 章数生成「Chapter N」。
class LnReaderEpubAssembler {
  const LnReaderEpubAssembler._();

  static Uint8List build({
    required String title,
    required String languageTag,
    required String identifier,
    required List<LnReaderEpubChapter> chapters,
    String? author,
    String? description,
    LnReaderEpubImage? cover,
  }) {
    String esc(String value) => EpubBuilder.escXml(value);
    final String lang = esc(languageTag);
    final EpubZip zip = EpubZip();
    zip.addStored('mimetype', utf8.encode('application/epub+zip'));
    zip.addDeflated(
      'META-INF/container.xml',
      utf8.encode(EpubBuilder.containerXml()),
    );

    final StringBuffer manifest = StringBuffer();
    final StringBuffer spine = StringBuffer();
    final StringBuffer navItems = StringBuffer();
    final StringBuffer ncxPoints = StringBuffer();
    final Set<String> imageNames = <String>{};

    if (cover != null) {
      final String coverName = 'images/${cover.fileName}';
      imageNames.add(coverName);
      zip.addStored('OEBPS/$coverName', cover.bytes);
      manifest.write(
        '    <item id="cover-image" href="${esc(coverName)}"'
        ' media-type="${esc(cover.mediaType)}" properties="cover-image"/>\n',
      );
    }

    for (int i = 0; i < chapters.length; i++) {
      final LnReaderEpubChapter chapter = chapters[i];
      final int n = i + 1;
      final String chapterTitle = _chapterTitle(n, chapter.title);
      zip.addDeflated(
        'OEBPS/chapter-$n.xhtml',
        utf8.encode(
          chapterXhtml(
            title: chapterTitle,
            body: chapter.xhtmlBody,
            languageTag: languageTag,
          ),
        ),
      );
      manifest.write(_manifestItem(n));
      spine.write(_spineItem(n));
      navItems.write(_navItem(n, chapterTitle));
      ncxPoints.write(_ncxPoint(n, chapterTitle));
      for (final LnReaderEpubImage image in chapter.images) {
        if (!imageNames.add(image.fileName)) continue;
        // 图片本就是压缩格式，再 deflate 只费 CPU。
        zip.addStored('OEBPS/${image.fileName}', image.bytes);
        manifest.write(
          '    <item id="img-${imageNames.length}"'
          ' href="${esc(image.fileName)}"'
          ' media-type="${esc(image.mediaType)}"/>\n',
        );
      }
    }

    final String modified = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    final String authorTag = author != null && author.trim().isNotEmpty
        ? '    <dc:creator>${esc(author.trim())}</dc:creator>\n'
        : '';
    final String descriptionTag =
        description != null && description.trim().isNotEmpty
        ? '    <dc:description>${esc(description.trim())}</dc:description>\n'
        : '';
    final String coverMeta = cover != null
        ? '    <meta name="cover" content="cover-image"/>\n'
        : '';
    zip.addDeflated(
      'OEBPS/content.opf',
      utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"'
        ' unique-identifier="uid" xml:lang="$lang">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '    <dc:identifier id="uid">${esc(identifier)}</dc:identifier>\n'
        '    <dc:title>${esc(title)}</dc:title>\n'
        '$authorTag$descriptionTag'
        '    <dc:language>$lang</dc:language>\n'
        '    <meta property="dcterms:modified">$modified</meta>\n'
        '$coverMeta'
        '  </metadata>\n'
        '  <manifest>\n'
        '$manifest'
        '$_navManifestItem'
        ' media-type="application/xhtml+xml" properties="nav"/>\n'
        '    <item id="ncx" href="toc.ncx"'
        ' media-type="application/x-dtbncx+xml"/>\n'
        '  </manifest>\n'
        '  <spine toc="ncx">\n'
        '$spine'
        '$_spineEnd'
        '</package>\n',
      ),
    );
    zip.addDeflated(
      'OEBPS/toc.ncx',
      utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        '  <head>\n'
        '    <meta name="dtb:uid" content="${esc(identifier)}"/>\n'
        '    <meta name="dtb:depth" content="1"/>\n'
        '  </head>\n'
        '  <docTitle><text>${esc(title)}</text></docTitle>\n'
        '  <navMap>\n'
        '$ncxPoints'
        '$_navMapEnd'
        '</ncx>\n',
      ),
    );
    zip.addDeflated(
      'OEBPS/nav.xhtml',
      utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml"'
        ' xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="$lang">\n'
        '<head><meta charset="utf-8"/><title>${esc(title)}</title></head>\n'
        '<body>\n'
        '  <nav epub:type="toc" id="toc">\n'
        '    <ol>\n'
        '$navItems'
        '$_navListEnd'
        '  </nav>\n'
        '</body>\n'
        '</html>\n',
      ),
    );
    return zip.build();
  }

  // 目录三件套里与章节有关的行。[build] 与就地补丁（[retitleChapter] /
  // [appendChapter]）共用同一份模板，补丁才能按行定位、不会与装配格式漂移。
  static String _chapterTitle(int n, String title) =>
      title.trim().isEmpty ? '$n' : title.trim();
  static String _manifestItem(int n) =>
      '    <item id="chapter-$n" href="chapter-$n.xhtml"'
      ' media-type="application/xhtml+xml"/>\n';
  static String _spineItem(int n) => '    <itemref idref="chapter-$n"/>\n';
  static String _navItem(int n, String title) =>
      '      <li><a href="chapter-$n.xhtml">${EpubBuilder.escXml(title)}'
      '</a></li>\n';
  static String _ncxLabel(int n, String title) =>
      '    <navPoint id="nav-$n" playOrder="$n">\n'
      '      <navLabel><text>${EpubBuilder.escXml(title)}</text></navLabel>\n';
  static String _ncxPoint(int n, String title) =>
      '${_ncxLabel(n, title)}'
      '      <content src="chapter-$n.xhtml"/>\n'
      '    </navPoint>\n';
  static const String _navManifestItem = '    <item id="nav" href="nav.xhtml"';
  static const String _spineEnd = '  </spine>\n';
  static const String _navMapEnd = '  </navMap>\n';
  static const String _navListEnd = '    </ol>\n';

  /// 本装配器产出、已解压的书：把第 [number] 章（1 基）在目录（nav + NCX）里的
  /// 标题换成 [title]。网页小说书末尾的「下一章」占位取回正文后用它把占位标题
  /// 换成章名（与整本重建时写进目录的一致）。目录里没有这一章（不是本装配器的
  /// 格式）抛 [FormatException]。
  static LnReaderPackageDocuments retitleChapter(
    LnReaderPackageDocuments docs, {
    required int number,
    required String title,
  }) {
    final String chapterTitle = _chapterTitle(number, title);
    final RegExp navLine = RegExp(
      '      <li><a href="chapter-$number\\.xhtml">[^<]*</a></li>\n',
    );
    final RegExp ncxLabel = RegExp(
      '    <navPoint id="nav-$number" playOrder="$number">\n'
      '      <navLabel><text>[^<]*</text></navLabel>\n',
    );
    if (!navLine.hasMatch(docs.nav) || !ncxLabel.hasMatch(docs.ncx)) {
      throw FormatException('chapter $number is not in the table of contents');
    }
    return (
      opf: docs.opf,
      nav: docs.nav.replaceFirstMapped(
        navLine,
        (_) => _navItem(number, chapterTitle),
      ),
      ncx: docs.ncx.replaceFirstMapped(
        ncxLabel,
        (_) => _ncxLabel(number, chapterTitle),
      ),
    );
  }

  /// 本装配器产出、已解压的书：在 manifest / spine / nav / NCX 末尾追加第
  /// [number] 章（1 基，文件 `chapter-<number>.xhtml`），目录标题 [title]。
  /// spine 里已有这一章时原样返回（补丁可重放：上一次写到一半被杀，重取时
  /// 再走一遍）。找不到插入点（不是本装配器的格式）抛 [FormatException]。
  static LnReaderPackageDocuments appendChapter(
    LnReaderPackageDocuments docs, {
    required int number,
    required String title,
  }) {
    if (docs.opf.contains(_spineItem(number))) return docs;
    final String chapterTitle = _chapterTitle(number, title);
    String insertBefore(String text, String anchor, String line) {
      final int at = text.lastIndexOf(anchor);
      if (at < 0) {
        throw FormatException('no "${anchor.trim()}" to append chapter to');
      }
      return text.replaceRange(at, at, line);
    }

    return (
      opf: insertBefore(
        insertBefore(docs.opf, _spineEnd, _spineItem(number)),
        _navManifestItem,
        _manifestItem(number),
      ),
      ncx: insertBefore(docs.ncx, _navMapEnd, _ncxPoint(number, chapterTitle)),
      nav: insertBefore(docs.nav, _navListEnd, _navItem(number, chapterTitle)),
    );
  }

  /// 单章 XHTML。插件正文自带标题（Syosetu 给 `<h1>`、Kakuyomu 给 `<h2>`）时
  /// 不再补一个，否则每章开头标题重复两遍。
  static String chapterXhtml({
    required String title,
    required String body,
    required String languageTag,
  }) {
    final String esc = EpubBuilder.escXml(title);
    final String lang = EpubBuilder.escXml(languageTag);
    final String head = body.length > 400 ? body.substring(0, 400) : body;
    final bool hasHeading = RegExp(r'<h[1-3][\s>]').hasMatch(head);
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="$lang"'
        ' lang="$lang">\n'
        '<head><meta charset="utf-8"/><title>$esc</title></head>\n'
        '<body>\n'
        '<section>\n'
        '${hasHeading ? '' : '<h2>$esc</h2>\n'}'
        '$body\n'
        '</section>\n'
        '</body>\n'
        '</html>\n';
  }
}

/// 按文件头魔数判图片类型；认不出返回 null（调用方丢弃这张图）。
String? sniffLnReaderImageMediaType(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (int i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(<int>[0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(<int>[0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(<int>[0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(<int>[0x52, 0x49, 0x46, 0x46]) &&
      startsWith(<int>[0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
