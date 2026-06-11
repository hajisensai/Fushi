import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show charCountsFromChaptersJson, countChapterChars, parseBookOnly;

/// TODO-131: 守卫开书路径的「DB 计数复用」与「解析/计数拆分」契约。
/// 核心不变量：从 chaptersJson 复用的每章字符数，必须与对解析出的 EpubBook 逐章
/// countChapterChars() 的结果严格等价——否则进度/统计总字数会错（Never break
/// userspace）。
void main() {
  late Directory extractDir;

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('book_open_char_counts_');
    final Uint8List bytes = _encodeArchive(<ArchiveFile>[
      _textFile('META-INF/container.xml', _containerXml),
      _textFile('OEBPS/content.opf', _contentOpf),
      _textFile('OEBPS/chapter1.xhtml', _chapter('First chapter body text.')),
      _textFile('OEBPS/chapter2.xhtml',
          _chapter('Second chapter has a different length of body text here.')),
    ]);
    EpubParser.parseSync(bytes, extractDir.path);
  });

  tearDown(() {
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
  });

  test('parseBookOnly 与 parseFromExtracted 解析出同样的章节结构', () {
    final EpubBook a = parseBookOnly(extractDir.path);
    final EpubBook b = EpubParser.parseFromExtracted(extractDir.path);
    expect(a.chapters.length, b.chapters.length);
    expect(a.chapters.map((c) => c.href).toList(),
        b.chapters.map((c) => c.href).toList());
  });

  test('charCountsFromChaptersJson 与逐章 countChapterChars 等价（DB 计数复用契约）', () {
    final EpubBook book = parseBookOnly(extractDir.path);
    final List<int> expected = countChapterChars(book);

    // 模拟 EpubImporter 写入的 chaptersJson（含 characters 字段）。
    final String chaptersJson = _importerChaptersJson(book, expected);

    final List<int>? fromDb =
        charCountsFromChaptersJson(chaptersJson, book.chapters.length);
    expect(fromDb, isNotNull);
    expect(fromDb, expected);
    // 防全零假等价。
    expect(expected.every((int c) => c > 0), isTrue);
  });

  test('characters 字段缺失 → 返回 null（旧书安全降级到后台重算）', () {
    final EpubBook book = parseBookOnly(extractDir.path);
    // 旧导入：只有 id/href，没有 characters。
    final String legacyJson = jsonEncode(
      book.chapters
          .map((c) => <String, Object?>{'id': c.id, 'href': c.href})
          .toList(),
    );
    expect(
      charCountsFromChaptersJson(legacyJson, book.chapters.length),
      isNull,
    );
  });

  test('章节数不匹配 → 返回 null（不按错索引映射计数）', () {
    final EpubBook book = parseBookOnly(extractDir.path);
    final List<int> counts = countChapterChars(book);
    final String chaptersJson = _importerChaptersJson(book, counts);
    // 期望多一章，DB 只有两章 → 拒绝复用。
    expect(
      charCountsFromChaptersJson(chaptersJson, book.chapters.length + 1),
      isNull,
    );
  });

  test('characters 非 int / 负数 → 返回 null', () {
    final String badType = jsonEncode(<Object>[
      <String, Object?>{'characters': 'oops'},
      <String, Object?>{'characters': 5},
    ]);
    expect(charCountsFromChaptersJson(badType, 2), isNull);

    final String negative = jsonEncode(<Object>[
      <String, Object?>{'characters': -1},
      <String, Object?>{'characters': 5},
    ]);
    expect(charCountsFromChaptersJson(negative, 2), isNull);
  });

  test('chaptersJson 非法 JSON → 返回 null', () {
    expect(charCountsFromChaptersJson('not json', 2), isNull);
  });
}

String _importerChaptersJson(EpubBook book, List<int> counts) {
  return jsonEncode(
    book.chapters
        .asMap()
        .entries
        .map((entry) => <String, Object>{
              'id': entry.value.id,
              'href': entry.value.href,
              'mediaType': entry.value.mediaType,
              'characters': counts[entry.key],
            })
        .toList(),
  );
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

String _chapter(String body) => '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml">\n'
    '  <head><title>Chapter</title></head>\n'
    '  <body><p>$body</p></body>\n'
    '</html>\n';

const String _containerXml = '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '  <rootfiles>\n'
    '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
    '  </rootfiles>\n'
    '</container>\n';

const String _contentOpf = '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">\n'
    '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '    <dc:title>Two Chapter Book</dc:title>\n'
    '  </metadata>\n'
    '  <manifest>\n'
    '    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>\n'
    '    <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>\n'
    '  </manifest>\n'
    '  <spine>\n'
    '    <itemref idref="ch1"/>\n'
    '    <itemref idref="ch2"/>\n'
    '  </spine>\n'
    '</package>\n';
