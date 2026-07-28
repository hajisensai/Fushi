import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

/// BUG-1218：解析出的章节/资源路径必须保留磁盘上的**真实大小写**。
///
/// `p.canonicalize` 在 Windows/macOS 等大小写不敏感平台会把整条路径折成小写。解析侧
/// 曾直接拿它的结果当真实读写路径，于是用户书（Calibre/Sigil 重打包）的
/// `OEBPS/Dick_9780345508553_epub_c01_r1.htm` 被记成 `oebps/dick_...htm`：
/// Windows 文件系统不区分大小写所以侥幸能读，但在 **Android / Linux 上
/// `existsSync()` 全部为 false**，spine 里的章节被逐条静默跳过（整本只剩路径恰好
/// 全小写的那一两章），且不写任何错误日志。
///
/// 本地跑在 Windows 上时 `File.exists` 不区分大小写，所以**只断言 existsSync 抓不到
/// 这个 bug**；这里改为把解析结果与 `listSync` 列出的真实磁盘条目名做**逐字节比对**，
/// 从而在任何平台上都能复现大小写敏感平台的查找语义。
void main() {
  late Directory extractDir;

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('epub_path_case_');
  });

  tearDown(() {
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
  });

  /// 磁盘上真实存在的、相对 extractDir 的正斜杠路径集合（大小写原样）。
  Set<String> onDiskEntries() => <String>{
        for (final FileSystemEntity e in extractDir.listSync(recursive: true))
          if (e is File)
            p.relative(e.path, from: extractDir.path).replaceAll('\\', '/'),
      };

  test('章节 href 与磁盘上的实际大小写逐字节一致', () {
    final EpubBook book =
        EpubParser.parseSync(_mixedCaseEpub(), extractDir.path);
    final Set<String> onDisk = onDiskEntries();

    expect(book.chapters, hasLength(2), reason: '两章都必须进 spine');
    for (final EpubChapter c in book.chapters) {
      expect(onDisk, contains(c.href),
          reason: 'href「${c.href}」与磁盘大小写不符 —— 大小写敏感的 '
              'Android/Linux 上 existsSync 会失败，该章被静默跳过');
    }
  });

  test('资源表的键与 filePath 都保留真实大小写', () {
    final EpubBook book =
        EpubParser.parseSync(_mixedCaseEpub(), extractDir.path);
    final Set<String> onDisk = onDiskEntries();

    for (final MapEntry<String, EpubResource> e in book.resources.entries) {
      expect(onDisk, contains(e.key),
          reason: '资源键「${e.key}」与磁盘大小写不符 —— 拦截器（BUG-1203）按真实 '
              'href 回查 OPF media-type 时会查不中，静默退回扩展名兜底');
      final String rel = p
          .relative(e.value.filePath!, from: extractDir.path)
          .replaceAll('\\', '/');
      expect(onDisk, contains(rel),
          reason: '资源 filePath「$rel」与磁盘大小写不符，读不到文件');
    }
  });

  test('封面 href 保留真实大小写', () {
    final EpubBook book =
        EpubParser.parseSync(_mixedCaseEpub(), extractDir.path);
    expect(book.coverHref, 'Images/COVER.jpeg');
    expect(onDiskEntries(), contains(book.coverHref));
  });

  test('NCX 目录能被找到（路径折成小写会导致 TOC 整个为空）', () {
    final EpubBook book =
        EpubParser.parseSync(_mixedCaseEpub(), extractDir.path);
    expect(book.toc, isNotEmpty,
        reason: 'NCX 在 `Meta/TOC.ncx`，路径被折成小写就读不到，TOC 静默变空');
    expect(book.chapterIndexForHref(book.toc.first.href), isNot(-1),
        reason: 'TOC 条目必须能解析回 spine 章节');
  });

  test('大小写保留不削弱 zip-slip 防护', () {
    final EpubBook book =
        EpubParser.parseSync(_traversalEpub(), extractDir.path);
    for (final EpubChapter c in book.chapters) {
      expect(c.href.contains('..'), isFalse,
          reason: '逃逸出 extractDir 的 manifest 条目必须被丢弃');
    }
    for (final String key in book.resources.keys) {
      expect(key.contains('..'), isFalse);
    }
    // 逃逸条目被丢掉后，合法那一章仍须保留。
    expect(book.chapters, hasLength(1));
    expect(book.chapters.single.href, 'OEBPS/Ch1.htm');
  });
}

/// 复刻用户书的结构：OPF 在压缩包**根目录**、内容在混合大小写的 `OEBPS/`、
/// 章节扩展名 `.htm`、封面在 `Images/COVER.jpeg`、NCX 在 `Meta/TOC.ncx`。
Uint8List _mixedCaseEpub() {
  const String opf = '''
<?xml version="1.0" encoding="utf-8"?>
<package version="2.0" unique-identifier="uid" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Do Androids Dream of Electric Sheep?</dc:title>
    <dc:creator>Philip K. Dick</dc:creator>
  </metadata>
  <manifest>
    <item id="cover" href="Images/COVER.jpeg" media-type="image/jpeg"/>
    <item id="css" href="Styles/Main.css" media-type="text/css"/>
    <item id="ncx" href="Meta/TOC.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c01" href="OEBPS/Dick_9780345508553_epub_c01_r1.htm" media-type="application/xhtml+xml"/>
    <item id="c02" href="OEBPS/Dick_9780345508553_epub_c02_r1.htm" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c01"/>
    <itemref idref="c02"/>
  </spine>
</package>
''';
  const String ncx = '''
<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>Chapter 1</text></navLabel>
      <content src="../OEBPS/Dick_9780345508553_epub_c01_r1.htm"/>
    </navPoint>
  </navMap>
</ncx>
''';
  return _encodeArchive(<ArchiveFile>[
    _textFile('META-INF/container.xml', _rootLevelContainerXml),
    _textFile('content.opf', opf),
    _textFile('Meta/TOC.ncx', ncx),
    _textFile('OEBPS/Dick_9780345508553_epub_c01_r1.htm', _chapterHtml),
    _textFile('OEBPS/Dick_9780345508553_epub_c02_r1.htm', _chapterHtml),
    _textFile('Styles/Main.css', 'body { margin: 0; }'),
    _binFile('Images/COVER.jpeg', <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
  ]);
}

Uint8List _traversalEpub() {
  const String opf = '''
<?xml version="1.0" encoding="utf-8"?>
<package version="2.0" unique-identifier="uid" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Traversal</dc:title>
  </metadata>
  <manifest>
    <item id="ok" href="OEBPS/Ch1.htm" media-type="application/xhtml+xml"/>
    <item id="evil" href="../../escaped.htm" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ok"/>
    <itemref idref="evil"/>
  </spine>
</package>
''';
  return _encodeArchive(<ArchiveFile>[
    _textFile('META-INF/container.xml', _rootLevelContainerXml),
    _textFile('content.opf', opf),
    _textFile('OEBPS/Ch1.htm', _chapterHtml),
  ]);
}

const String _rootLevelContainerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _chapterHtml = '''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Rick Deckard</p></body></html>
''';

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile f in files) {
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

ArchiveFile _binFile(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);
