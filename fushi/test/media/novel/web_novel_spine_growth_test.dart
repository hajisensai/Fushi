// novel-d6：网页小说书阅读中途 spine 末尾续挂新章的两块地基。
//
// ① 目录补丁（[LnReaderEpubAssembler.retitleChapter] / [appendChapter]）：对已解压的
//    书就地改目录三件套，结果必须与「整本重新装配」逐字一致（除修改时间），否则会话内
//    续挂的书与下次开书整本重建的书目录不同。
// ② [EpubBook.adoptTrailingChapters]：已打开的书并进同一解压树重解析出的尾部新章，
//    已有章不变、只认前缀扩展。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

LnReaderEpubChapter _chapter(String title, String body) =>
    (title: title, xhtmlBody: body, images: const <LnReaderEpubImage>[]);

Uint8List _build(List<LnReaderEpubChapter> chapters) =>
    LnReaderEpubAssembler.build(
      title: '無職転生',
      languageTag: 'ja',
      identifier: 'web-novel:test',
      author: '理不尽な孫の手',
      chapters: chapters,
    );

LnReaderPackageDocuments _docs(Uint8List epub) {
  final Archive archive = ZipDecoder().decodeBytes(epub);
  String entry(String name) =>
      utf8.decode(archive.findFile('OEBPS/$name')!.content as List<int>);
  return (
    opf: entry('content.opf'),
    ncx: entry('toc.ncx'),
    nav: entry('nav.xhtml'),
  );
}

/// OPF 的修改时间每次装配都不同，比较前抹掉。
String _withoutModified(String opf) => opf.replaceFirst(
  RegExp(r'<meta property="dcterms:modified">[^<]*</meta>'),
  '',
);

void _unzipInto(Uint8List bytes, String dir) {
  for (final ArchiveFile file in ZipDecoder().decodeBytes(bytes)) {
    if (!file.isFile) continue;
    final File out = File(p.join(dir, file.name));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(file.content as List<int>);
  }
}

void main() {
  final LnReaderEpubChapter first = _chapter('第一話 <転生>', '<p>一</p>');
  final LnReaderEpubChapter second = _chapter('第二話 & 家族', '<p>二</p>');
  final LnReaderEpubChapter pendingNext = _chapter('NEXT', '<p>…</p>');

  group('目录补丁', () {
    test('末尾占位取回后改章名 + 续挂新占位 == 整本重新装配', () {
      // 会话前：第 1 话 + 「下一章」占位。
      final LnReaderPackageDocuments before = _docs(
        _build(<LnReaderEpubChapter>[first, pendingNext]),
      );
      LnReaderPackageDocuments patched = LnReaderEpubAssembler.retitleChapter(
        before,
        number: 2,
        title: second.title,
      );
      patched = LnReaderEpubAssembler.appendChapter(
        patched,
        number: 3,
        title: 'NEXT',
      );
      // 下次开书整本重建会装出的：第 1 话 + 第 2 话 + 新占位。
      final LnReaderPackageDocuments rebuilt = _docs(
        _build(<LnReaderEpubChapter>[first, second, pendingNext]),
      );
      expect(patched.nav, rebuilt.nav);
      expect(patched.ncx, rebuilt.ncx);
      expect(_withoutModified(patched.opf), _withoutModified(rebuilt.opf));
      for (final String doc in <String>[
        patched.opf,
        patched.ncx,
        patched.nav,
      ]) {
        expect(() => XmlDocument.parse(doc), returnsNormally);
      }
    });

    test('追加可重放：spine 里已有这一章时原样返回', () {
      final LnReaderPackageDocuments docs = _docs(
        _build(<LnReaderEpubChapter>[first, pendingNext]),
      );
      final LnReaderPackageDocuments once = LnReaderEpubAssembler.appendChapter(
        docs,
        number: 3,
        title: 'NEXT',
      );
      final LnReaderPackageDocuments twice =
          LnReaderEpubAssembler.appendChapter(once, number: 3, title: 'NEXT');
      expect(twice, once);
      expect(
        LnReaderEpubAssembler.appendChapter(docs, number: 2, title: 'x'),
        docs,
      );
    });

    test('追加可重放：nav / NCX 已写上、OPF 没写上就被杀，重放不在目录里重复加项', () {
      final LnReaderPackageDocuments docs = _docs(
        _build(<LnReaderEpubChapter>[first, pendingNext]),
      );
      final LnReaderPackageDocuments once = LnReaderEpubAssembler.appendChapter(
        docs,
        number: 3,
        title: 'NEXT',
      );
      // 落盘顺序是 nav → NCX → OPF：复现「OPF 还是旧的」的中断现场。
      final LnReaderPackageDocuments interrupted = (
        opf: docs.opf,
        ncx: once.ncx,
        nav: once.nav,
      );
      final LnReaderPackageDocuments replayed =
          LnReaderEpubAssembler.appendChapter(
            interrupted,
            number: 3,
            title: 'NEXT',
          );
      expect(replayed, once);
      expect('chapter-3.xhtml">NEXT<'.allMatches(replayed.nav), hasLength(1));
      expect('id="nav-3"'.allMatches(replayed.ncx), hasLength(1));
    });

    test('不是本装配器的格式：抛 FormatException，不出半成品', () {
      const LnReaderPackageDocuments foreign = (
        opf: '<package><manifest/><spine/></package>',
        ncx: '<ncx><navMap/></ncx>',
        nav: '<nav><ol/></nav>',
      );
      expect(
        () =>
            LnReaderEpubAssembler.appendChapter(foreign, number: 2, title: 'x'),
        throwsFormatException,
      );
      expect(
        () => LnReaderEpubAssembler.retitleChapter(
          foreign,
          number: 1,
          title: 'x',
        ),
        throwsFormatException,
      );
    });
  });

  group('EpubBook.adoptTrailingChapters', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('web_novel_spine_growth_');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    EpubBook parse(List<LnReaderEpubChapter> chapters, String name) {
      final String dir = p.join(root.path, name);
      _unzipInto(_build(chapters), dir);
      return EpubParser.parseFromExtracted(dir);
    }

    test('并进尾部新章：已有章原样、目录换成新的、章节与目录同长', () {
      final EpubBook open = parse(<LnReaderEpubChapter>[
        first,
        pendingNext,
      ], 'open');
      final EpubChapter keptFirst = open.chapters[0];
      final EpubBook grown = parse(<LnReaderEpubChapter>[
        first,
        second,
        pendingNext,
      ], 'grown');

      expect(open.adoptTrailingChapters(grown), isTrue);
      expect(open.chapters, hasLength(3));
      expect(identical(open.chapters[0], keptFirst), isTrue);
      expect(open.chapters[2].href, grown.chapters[2].href);
      expect(open.toc.map((EpubTocItem e) => e.label).toList(), <String>[
        '第一話 <転生>',
        '第二話 & 家族',
        'NEXT',
      ]);
      expect(open.chapterIndexForHref(grown.chapters[2].href), 2);
    });

    test('不是前缀扩展（没变长 / 已有章 href 不一致）：不动、返回 false', () {
      final EpubBook open = parse(<LnReaderEpubChapter>[
        first,
        pendingNext,
      ], 'open');
      final EpubBook same = parse(<LnReaderEpubChapter>[first, second], 'same');
      expect(open.adoptTrailingChapters(same), isFalse);
      expect(open.chapters, hasLength(2));

      final EpubBook foreign = EpubBook(
        title: 'x',
        chapters: <EpubChapter>[
          for (int i = 0; i < 3; i++)
            EpubChapter(
              id: 'c$i',
              href: 'OEBPS/other-$i.xhtml',
              mediaType: 'application/xhtml+xml',
              html: '<html/>',
            ),
        ],
      );
      expect(open.adoptTrailingChapters(foreign), isFalse);
      expect(open.chapters, hasLength(2));
      expect(open.toc.map((EpubTocItem e) => e.label).last, 'NEXT');
    });
  });
}
