import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio_core.dart' show EpubBuilder, EpubZip;

/// EPUB 里的一张图片（封面或章节插图）。
typedef LnReaderEpubImage = ({
  String fileName,
  Uint8List bytes,
  String mediaType,
});

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
      final String chapterTitle = chapter.title.trim().isEmpty
          ? '$n'
          : chapter.title.trim();
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
      manifest.write(
        '    <item id="chapter-$n" href="chapter-$n.xhtml"'
        ' media-type="application/xhtml+xml"/>\n',
      );
      spine.write('    <itemref idref="chapter-$n"/>\n');
      navItems.write(
        '      <li><a href="chapter-$n.xhtml">${esc(chapterTitle)}</a></li>\n',
      );
      ncxPoints.write(
        '    <navPoint id="nav-$n" playOrder="$n">\n'
        '      <navLabel><text>${esc(chapterTitle)}</text></navLabel>\n'
        '      <content src="chapter-$n.xhtml"/>\n'
        '    </navPoint>\n',
      );
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
        '    <item id="nav" href="nav.xhtml"'
        ' media-type="application/xhtml+xml" properties="nav"/>\n'
        '    <item id="ncx" href="toc.ncx"'
        ' media-type="application/x-dtbncx+xml"/>\n'
        '  </manifest>\n'
        '  <spine toc="ncx">\n'
        '$spine'
        '  </spine>\n'
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
        '  </navMap>\n'
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
        '    </ol>\n'
        '  </nav>\n'
        '</body>\n'
        '</html>\n',
      ),
    );
    return zip.build();
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
