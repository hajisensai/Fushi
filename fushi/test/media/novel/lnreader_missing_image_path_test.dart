import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_missing_images.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart'
    show lnReaderOnlineChapterFile, readLnReaderLoadedChapter;
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';
import 'package:path/path.dart' as p;

/// HBK-AUDIT-002：缺图占位里的文件名来自章节文件（第三方 EPUB / 站点正文），
/// 补取写回、重建搬图都只能落在本书 `OEBPS/images/` 下、按生成规则命名的文件上。

/// 一个最小 PNG 头（嗅探只看魔数）。
final Uint8List _png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0, 0, 0, 0,
]);

String _marker(String fileName) =>
    '<span data-fushi-lnreader-missing-file="$fileName" '
    'data-fushi-lnreader-missing-url="https://img.example/x.png" '
    'data-fushi-lnreader-missing-alt="" '
    'data-fushi-lnreader-missing-tries="1" '
    'data-fushi-lnreader-missing-referer="https://site.example/1" '
    'data-fushi-lnreader-missing-plugin="test.plugin" hidden="hidden"></span>';

String _chapter(String body) =>
    '<?xml version="1.0" encoding="utf-8"?>\n<html><body><section>\n'
    '$body\n</section></body></html>';

const List<String> _illegalNames = <String>[
  '../evil.png',
  '../../evil.png',
  'images/../../evil.png',
  'images/../evil.png',
  'images/a/../../../evil.png',
  'images\\..\\..\\evil.png',
  '..\\..\\evil.png',
  '/tmp/evil.png',
  '/images/evil.png',
  'C:/evil.png',
  'C:\\evil.png',
  'images/C:evil.png',
  'images/evil.exe',
  'images/.png',
  'images/sub/evil.png',
  'images/evil.png/',
  'images/EVIL.PNG',
  'cover.png',
  // 在 images/ 下、但不是三条管线生成的形状（封面、任意名、设备名、缺扩展名的
  // 非网页小说键、哈希位数不对）。
  'images/cover.png',
  'images/evil.png',
  'images/con.png',
  'images/nul',
  'images/0123456789ab-0',
  'images/c1-0',
  'images/0123456789-0.png',
  'images/w0123.png',
  'images/W0123456789ABCDEF.png',
  '',
];

Future<void> _write(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  await target.writeAsBytes(bytes, flush: true);
}

void main() {
  late Directory root;
  late String extractDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hbk_audit_002_');
    extractDir = p.join(root.path, 'books', 'book1');
    await Directory(
      p.join(extractDir, 'OEBPS', 'images'),
    ).create(recursive: true);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('插图条目名判据', () {
    test('三条管线生成的名字都认，落在本书图片目录里', () {
      for (final String name in <String>[
        'images/0123456789ab-0.jpg', // 在线书
        'images/c12-3.png', // 下载书
        'images/w0123456789abcdef.webp', // 网页小说书
        'images/c1-0.gif',
      ]) {
        expect(isLnReaderBookImageKey(name), isTrue, reason: name);
        final File? file = lnReaderBookImageFile(extractDir, name);
        expect(file, isNotNull, reason: name);
        expect(
          p.isWithin(
            p.normalize(p.absolute(p.join(extractDir, 'OEBPS', 'images'))),
            file!.path,
          ),
          isTrue,
          reason: name,
        );
      }
      // 网页小说书取不到时的占位键不带扩展名：是合法键，但不是可写的文件名。
      expect(isLnReaderBookImageKey('images/w0123456789abcdef'), isTrue);
      expect(
        lnReaderBookImageFile(extractDir, 'images/w0123456789abcdef'),
        isNull,
      );
    });

    test('../、绝对路径、驱动器号、反斜杠等一律拒绝', () {
      for (final String name in _illegalNames) {
        expect(isLnReaderBookImageKey(name), isFalse, reason: name);
        expect(lnReaderBookImageFile(extractDir, name), isNull, reason: name);
      }
    });
  });

  group('retryChapterMissingImages 写入路径', () {
    Future<OnlineNovelMissingImagesRetry> retry({
      required String body,
      required String Function(LnReaderMissingImage image) nameFor,
      List<LnReaderMissingImage>? fetched,
    }) async {
      final File chapter = lnReaderOnlineChapterFile(extractDir, 0);
      await chapter.writeAsString(_chapter(body));
      return retryChapterMissingImages(
        index: 0,
        extractDir: extractDir,
        file: chapter,
        automatic: true,
        write: _write,
        fetch: (LnReaderMissingImage image, void Function(String) _) async {
          fetched?.add(image);
          return (
            fileName: nameFor(image),
            bytes: _png,
            mediaType: 'image/png',
          );
        },
      );
    }

    test('第三方 EPUB 伪造的越界占位：不计数、不取图、不落盘', () async {
      for (final String name in _illegalNames) {
        final List<LnReaderMissingImage> fetched = <LnReaderMissingImage>[];
        final OnlineNovelMissingImagesRetry result = await retry(
          body: '<p>${_marker(name)}</p>',
          nameFor: (LnReaderMissingImage image) => image.fileName,
          fetched: fetched,
        );
        expect(fetched, isEmpty, reason: name);
        expect(result.recovered, 0, reason: name);
        expect(result.remaining, 0, reason: name);
      }
      expect(
        File(p.join(root.path, 'books', 'evil.png')).existsSync(),
        isFalse,
      );
      expect(File(p.join(root.path, 'evil.png')).existsSync(), isFalse);
      expect(
        File(p.join(extractDir, 'OEBPS', 'evil.png')).existsSync(),
        isFalse,
      );
    });

    test('取图方给出越界文件名：当这张没补到（记次），不写出目录', () async {
      final OnlineNovelMissingImagesRetry result = await retry(
        body: '<p>${_marker('images/c1-0.png')}</p>',
        nameFor: (_) => 'images/../../evil.png',
      );
      expect(result.recovered, 0);
      expect(result.remaining, 1);
      expect(
        File(p.join(root.path, 'books', 'evil.png')).existsSync(),
        isFalse,
      );
      final String xhtml = await lnReaderOnlineChapterFile(
        extractDir,
        0,
      ).readAsString();
      expect(parseLnReaderMissingImages(xhtml).single.tries, 2);
      expect(xhtml, isNot(contains('<img')));
    });

    test('合规占位照常补到并写进本书图片目录（网页小说书键换真文件名）', () async {
      final OnlineNovelMissingImagesRetry result = await retry(
        body:
            '<p>${_marker('images/c1-0.png')}'
            '${_marker('images/w0123456789abcdef')}</p>',
        nameFor: (LnReaderMissingImage image) =>
            image.fileName.startsWith('images/w')
            ? '${image.fileName}.png'
            : image.fileName,
      );
      expect(result.recovered, 2);
      expect(result.remaining, 0);
      expect(
        File(p.join(extractDir, 'OEBPS', 'images', 'c1-0.png')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(extractDir, 'OEBPS', 'images', 'w0123456789abcdef.png'),
        ).existsSync(),
        isTrue,
      );
      final String xhtml = await lnReaderOnlineChapterFile(
        extractDir,
        0,
      ).readAsString();
      expect(xhtml, contains('src="images/c1-0.png"'));
      expect(xhtml, contains('src="images/w0123456789abcdef.png"'));
    });
  });

  test('重建搬图（readLnReaderLoadedChapter）不读本书图片目录外的文件', () async {
    // 书目录外放一张「图」，站点正文里用 ../ 引它。
    await File(p.join(root.path, 'books', 'secret.png')).writeAsBytes(_png);
    await File(
      p.join(extractDir, 'OEBPS', 'images', 'c1-0.png'),
    ).writeAsBytes(_png);
    await lnReaderOnlineChapterFile(extractDir, 0).writeAsString(
      _chapter(
        '<p><img src="images/c1-0.png"/>'
        '<source src="images/../../../secret.png"/></p>',
      ),
    );
    final ({String body, List<LnReaderEpubImage> images})? loaded =
        readLnReaderLoadedChapter(extractDir, 0);
    expect(loaded, isNotNull);
    expect(
      loaded!.images.map((LnReaderEpubImage image) => image.fileName),
      <String>['images/c1-0.png'],
    );
    expect(utf8.decode(loaded.images.single.bytes.sublist(1, 4)), 'PNG');
  });
}
