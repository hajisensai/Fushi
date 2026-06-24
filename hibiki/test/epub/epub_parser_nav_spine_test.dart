// TODO-807：日文 EPUB 常把目录页（`properties="nav"`）作为 spine 首个 linear
// 项，于是 `chapters[0]` 就是目录页。有声书被动跨章跟随不能把目录页当作导航
// 目标（否则把用户甩到目录）。
//
// 本测试锁住解析层契约：spine 含 nav 文档时，对应 chapter 被标 isNav，正文章
// 不被标；且该项**不被物理删除**（chapters 长度不变、其余 index 不移位），因为
// chapters 已按 index 序列化进 DB chaptersJson。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';

void main() {
  group('EpubParser nav-doc-in-spine 标记 (TODO-807)', () {
    late Directory extractDir;

    setUp(() {
      extractDir = Directory.systemTemp.createTempSync('epub_nav_spine_test_');
    });

    tearDown(() {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    test('目录页作为 spine 首项 → chapters[0].isNav，正文章 isNav=false', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _opfNavFirstInSpine),
        _textFile('OEBPS/nav.xhtml', _navXhtml),
        _textFile(
            'OEBPS/chapter-1.xhtml', _chapterXhtml('First chapter body.')),
        _textFile(
            'OEBPS/chapter-2.xhtml', _chapterXhtml('Second chapter body.')),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);

      // 物理不删：目录页 + 两正文章 = 3 项，index 不移位。
      expect(book.chapters, hasLength(3),
          reason: 'nav 页保留在 chapters（index 已序列化进 DB，删会移位既有书）');
      expect(book.chapters[0].href, contains('nav.xhtml'));
      expect(book.chapters[0].isNav, isTrue,
          reason: 'spine 首项目录页必须被标记，跨章不能落到它');
      expect(book.isChapterNav(0), isTrue);
      expect(book.chapters[1].isNav, isFalse);
      expect(book.chapters[2].isNav, isFalse);
      expect(book.isChapterNav(1), isFalse);
    });

    test('普通书（spine 无 nav）→ 所有章 isNav=false（不破坏既有行为）', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _opfPlain),
        _textFile('OEBPS/chapter-1.xhtml', _chapterXhtml('Only chapter.')),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);
      expect(book.chapters, hasLength(1));
      expect(book.chapters[0].isNav, isFalse);
    });
  });
}

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

const String _containerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

// 目录页 nav.xhtml 作为 spine 第一个 itemref（日文 EPUB 常见布局）。
const String _opfNavFirstInSpine = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Nav In Spine Book</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="chapter-1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter-2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="nav"/>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
''';

const String _opfPlain = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Plain Book</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter-1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
</package>
''';

const String _navXhtml = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Table of Contents</title></head>
  <body>
    <nav epub:type="toc">
      <ol>
        <li><a href="chapter-1.xhtml">Chapter 1</a></li>
        <li><a href="chapter-2.xhtml">Chapter 2</a></li>
      </ol>
    </nav>
  </body>
</html>
''';

String _chapterXhtml(String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>$body</p></body>
</html>
''';
