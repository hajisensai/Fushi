// 路线图 #3722 c26：漫画导入快路径。
//
// - manga-10（BUG-4906）：跳过策略在整包解压 / 逐页读尺寸之前判重；
// - manga-23（BUG-4908）：纯图 EPUB 分支按实际解出字节封顶，探测不为页图解压；
// - manga-29a：压缩包导入的进度总量 = 解压 + 入库；
// - manga-29b：mokuro 清单一次解析同时带出顶层对象，落库段吃已解析的文档；
// - manga-29c：逐页探尺寸先读前缀，PNG / 头部在前缀内的 JPEG 不读全量。
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show ZLibEncoder;
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/import/image_size_probe.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('manga_fastpath_');
    app = Directory.systemTemp.createTempSync('manga_fastpath_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[root, app]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Uint8List png(int width, {int height = 40}) => Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height)),
  );

  Set<String> stagingDirs() {
    final Directory booksRoot = Directory(p.join(app.path, 'fushi_books'));
    if (!booksRoot.existsSync()) return <String>{};
    return <String>{
      for (final Directory dir
          in booksRoot.listSync(followLinks: false).whereType<Directory>())
        if (p.basename(dir.path).startsWith(EpubStorage.kStagingDirPrefix))
          dir.path,
    };
  }

  group(
    'manga-10: skip policy rejects a known volume before the heavy work',
    () {
      test(
        'archive: the second copy is skipped without being extracted',
        () async {
          final String first = _writeCbz(
            Directory(p.join(root.path, 'a'))..createSync(),
            'vol 01.cbz',
            <String, Uint8List>{'1.png': png(20), '2.png': png(30)},
          );
          await MangaArchiveImporter.importArchive(
            db: db,
            archivePath: first,
            policy: const DuplicatePolicy.skip(),
          );

          // 同名的第二份是坏包（第一页 CRC 对不上）：没有预检时它会先被解压、在 CRC 上
          // 报错；有预检时根本轮不到解压，按「跳过」中止。
          final String again = _writeCorruptCbz(
            Directory(p.join(root.path, 'b'))..createSync(),
            'vol 01.cbz',
            png(20),
          );
          final Set<String> before = stagingDirs();
          await expectLater(
            MangaArchiveImporter.importArchive(
              db: db,
              archivePath: again,
              policy: const DuplicatePolicy.skip(),
            ),
            throwsA(
              isA<DuplicateImportCancelledException>().having(
                (DuplicateImportCancelledException e) => e.title,
                'title',
                'vol 01',
              ),
            ),
          );
          expect(stagingDirs().difference(before), isEmpty);
          expect(await db.getEpubBookMetas(), hasLength(1));
        },
      );

      test(
        'archive: the ask policy keeps its extract-then-ask order',
        () async {
          final String first = _writeCbz(
            Directory(p.join(root.path, 'a'))..createSync(),
            'vol.cbz',
            <String, Uint8List>{'1.png': png(20)},
          );
          await MangaArchiveImporter.importArchive(db: db, archivePath: first);

          final String again = _writeCorruptCbz(
            Directory(p.join(root.path, 'b'))..createSync(),
            'vol.cbz',
            png(20),
          );
          bool asked = false;
          await expectLater(
            MangaArchiveImporter.importArchive(
              db: db,
              archivePath: again,
              policy: DuplicatePolicy.ask((String _) async {
                asked = true;
                return DuplicateChoice.suffix;
              }),
            ),
            throwsA(
              isA<MangaImportException>().having(
                (MangaImportException e) => e.message,
                'message',
                contains('CRC'),
              ),
            ),
          );
          expect(asked, isFalse);
        },
      );

      test('image folder: pages of a known volume are not read', () async {
        final Directory a = Directory(p.join(root.path, 'a', 'vol 02'))
          ..createSync(recursive: true);
        File(p.join(a.path, '001.png')).writeAsBytesSync(png(20));
        await MangaImporter.importFromImageFolder(
          db: db,
          imageDirPath: a.path,
          policy: const DuplicatePolicy.skip(),
        );

        // 第二份同名文件夹里的页图解不开：逐页读尺寸会先报「Could not decode」。
        final Directory b = Directory(p.join(root.path, 'b', 'vol 02'))
          ..createSync(recursive: true);
        File(
          p.join(b.path, '001.png'),
        ).writeAsBytesSync(Uint8List.fromList(List<int>.filled(64, 7)));
        await expectLater(
          MangaImporter.importFromImageFolder(
            db: db,
            imageDirPath: b.path,
            policy: const DuplicatePolicy.skip(),
          ),
          throwsA(
            isA<DuplicateImportCancelledException>().having(
              (DuplicateImportCancelledException e) => e.title,
              'title',
              'vol 02',
            ),
          ),
        );
      });

      test('a new title still imports under the skip policy', () async {
        final String path = _writeCbz(root, 'fresh.cbz', <String, Uint8List>{
          '1.png': png(20),
        });
        final String key = await MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
          policy: const DuplicatePolicy.skip(),
        );
        expect(key, 'fresh');
      });
    },
  );

  group('manga-23: image-only EPUB extraction', () {
    test('the probe does not inflate page images', () {
      // 页图条目的数据区被翻转了一个字节（CRC 仍是原图的）。探测只看 spine 文档，
      // 不为页图解压，所以判得出「是纯图漫画」；导入时才在 CRC 上报错。旧探测把
      // 整本解压一遍，坏页让它误判成「不是漫画」。
      final Uint8List page = png(20);
      final Uint8List corrupted = Uint8List.fromList(page)
        ..[page.length ~/ 2] ^= 0xFF;
      final String path = p.join(root.path, 'probe.epub');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          ..._storedEpubSkeleton(),
          _RawZipEntry(
            'OEBPS/images/1.png',
            corrupted,
            declaredSize: page.length,
            crc: getCrc32(page),
            method: 0,
          ),
          _RawZipEntry(
            'OEBPS/images/2.png',
            page,
            declaredSize: page.length,
            crc: getCrc32(page),
            method: 0,
          ),
        ]),
      );
      expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);
    });

    test('an honest page above the per-entry limit is rejected', () async {
      // 随机像素的 PNG 压不动，体积远超 1 KiB 的单条上限。旧 EPUB 分支只有中央目录
      // 声明总量那一道预检，单条上限管不到，整本照常导入。
      final Random random = Random(7);
      final img.Image noisy = img.Image(width: 64, height: 64);
      for (final img.Pixel pixel in noisy) {
        pixel
          ..r = random.nextInt(256)
          ..g = random.nextInt(256)
          ..b = random.nextInt(256);
      }
      final Uint8List big = Uint8List.fromList(img.encodePng(noisy));
      expect(big.length, greaterThan(4096));
      final String path = _writeImageEpub(root, first: big, second: png(20));
      final Set<String> before = stagingDirs();
      await expectLater(
        MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
          limits: const MangaArchiveExtractionLimits(maxEntryBytes: 4096),
        ),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
      expect(stagingDirs().difference(before), isEmpty);
      expect(await db.getEpubBookMetas(), isEmpty);
    });

    test('a lying page aborts at its declared size instead of being written '
        'out in full', () async {
      // 声明 1000 字节、实际 inflate 出 64 MiB。旧路径把 64 MiB 整条写进解压树，
      // 写完才按「wrote … header says 1000」报错。
      const int bombBytes = 64 * 1024 * 1024;
      final String path = p.join(root.path, 'bomb.epub');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          ..._storedEpubSkeleton(),
          _RawZipEntry(
            'OEBPS/images/1.png',
            _deflateZeros(bombBytes),
            declaredSize: 1000,
            crc: _crc32OfZeros(bombBytes),
          ),
          _RawZipEntry(
            'OEBPS/images/2.png',
            png(20),
            declaredSize: png(20).length,
            crc: getCrc32(png(20)),
            method: 0,
          ),
        ]),
      );
      final Set<String> before = stagingDirs();
      Object? error;
      try {
        await MangaArchiveImporter.importArchive(db: db, archivePath: path);
      } catch (e) {
        error = e;
      }
      expect(
        error.toString(),
        contains('expands beyond its declared 1000 bytes'),
      );
      expect(stagingDirs().difference(before), isEmpty);
      expect(await db.getEpubBookMetas(), isEmpty);
    });

    test(
      'pages moved out of the extraction keep duplicates and order',
      () async {
        // 两页引用同一张图：第一页把它挪走，第二页要从挪到的位置拷。
        final Uint8List shared = png(30);
        final String path = _writeImageEpub(
          root,
          first: shared,
          second: png(20),
          page2Body: '<img src="../images/1.png"/>',
        );
        final String key = await MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
        );
        final EpubBookRow row = (await db.getEpubBook(key))!;
        final List<String> pages =
            Directory(p.join(row.extractDir, 'images'))
                .listSync()
                .map((FileSystemEntity e) => p.basename(e.path))
                .toList()
              ..sort();
        expect(pages, <String>['page_000000.png', 'page_000001.png']);
        for (final String page in pages) {
          expect(
            File(p.join(row.extractDir, 'images', page)).readAsBytesSync(),
            shared,
            reason: page,
          );
        }
      },
    );

    test('a page reference escaping the extraction root is neither moved '
        'nor read', () async {
      // 解压树在 `<app>/fushi_books/.tmp-*/`；第二页从 `OEBPS/text/` 往上四级，
      // 落到解压根之外的 `<app>/victim.png`。挪页是 rename——越界引用若被接受，
      // 解压树外的文件（别的书的页图、用户图片）会被挪走。
      final Uint8List victimBytes = png(25);
      final File victim = File(p.join(app.path, 'victim.png'))
        ..writeAsBytesSync(victimBytes);
      final String path = _writeImageEpub(
        root,
        first: png(30),
        second: png(20),
        page2Body: '<img src="../../../../victim.png"/>',
      );
      final Set<String> before = stagingDirs();
      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: path),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('page not found'),
          ),
        ),
      );
      expect(victim.existsSync(), isTrue);
      expect(victim.readAsBytesSync(), victimBytes);
      expect(stagingDirs().difference(before), isEmpty);
      expect(await db.getEpubBookMetas(), isEmpty);
    });
  });

  group('manga-29a: archive progress covers extraction and ingest', () {
    test('CBZ', () async {
      final String path = _writeCbz(root, 'progress.cbz', <String, Uint8List>{
        '1.png': png(20),
        '2.png': png(20),
        '3.png': png(20),
      });
      final List<(int, int)> reports = <(int, int)>[];
      await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        onProgress: (int done, int total) => reports.add((done, total)),
      );
      expect(reports.first, (0, 6));
      expect(reports, contains((3, 6)));
      expect(reports.last, (6, 6));
      for (int i = 1; i < reports.length; i++) {
        expect(reports[i].$1, greaterThanOrEqualTo(reports[i - 1].$1));
      }
    });

    test('image-only EPUB', () async {
      final String path = _writeImageEpub(
        root,
        first: png(20),
        second: png(30),
      );
      final List<(int, int)> reports = <(int, int)>[];
      await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        onProgress: (int done, int total) => reports.add((done, total)),
      );
      // 6 个文件条目（container / OPF / 2 页 XHTML / 2 张图）+ 2 页入库。
      expect(reports.first, (0, 8));
      expect(reports.last, (8, 8));
      expect(
        reports.where(((int, int) r) => r.$1 > 0 && r.$1 < 6),
        isNotEmpty,
        reason: '解压段逐条推进',
      );
    });
  });

  group('manga-29b: one parse of a mokuro manifest', () {
    test('parseMokuroDocument returns the page model and the top level', () {
      final MokuroDocument document = parseMokuroDocument(
        jsonEncode(<String, Object?>{
          'title': 'Series',
          'volume': 'Vol 3',
          'pages': <Object?>[
            <String, Object?>{
              'img_path': 'a/001.png',
              'img_width': 10,
              'img_height': 20,
              'blocks': <Object?>[],
            },
          ],
        }),
      );
      expect(document.root['title'], 'Series');
      expect(document.root['volume'], 'Vol 3');
      expect(document.payload.images.single.url, 'a/001.png');
      expect(document.payload.images.single.size.height, 20);

      final MokuroDocument array = parseMokuroDocument('[1, 2]');
      expect(array.root, isEmpty);
      expect(array.payload.images, isEmpty);
    });

    test('importMokuroDocument imports without the manifest on disk', () async {
      final Directory volume = Directory(p.join(root.path, 'mk'))..createSync();
      File(p.join(volume.path, '001.png')).writeAsBytesSync(png(40));
      final MokuroDocument document = parseMokuroDocument(
        jsonEncode(<String, Object?>{
          'title': 'Book',
          'volume': '1',
          'pages': <Object?>[
            <String, Object?>{
              'img_path': '001.png',
              'img_width': 40,
              'img_height': 40,
              'blocks': <Object?>[],
            },
          ],
        }),
      );
      final String mokuroPath = p.join(volume.path, 'vol.mokuro');
      expect(File(mokuroPath).existsSync(), isFalse);
      final String key = await MangaImporter.importMokuroDocument(
        db: db,
        document: document,
        mokuroPath: mokuroPath,
      );
      final EpubBookRow row = (await db.getEpubBook(key))!;
      expect(row.title, 'Book 1');
      expect(
        File(
          p.join(row.extractDir, MangaStorage.kMangaJsonFileName),
        ).existsSync(),
        isTrue,
      );
    });
  });

  group('manga-29c: page sizes from a file prefix', () {
    test('prefix verdicts equal full-file probes for PNG and JPEG', () {
      final List<Uint8List> samples = <Uint8List>[
        png(30, height: 20),
        Uint8List.fromList(img.encodeJpg(img.Image(width: 30, height: 20))),
        for (final int orientation in <int>[3, 6, 8])
          Uint8List.fromList(
            img.encodeJpg(
              img.Image(width: 30, height: 20)
                ..exif.imageIfd.orientation = orientation,
            ),
          ),
      ];
      for (final Uint8List bytes in samples) {
        expect(probeImageSizeFromPrefix(bytes), probeOrientedImageSize(bytes));
        expect(probeImageSizeFromPrefix(bytes), isNotNull);
      }
    });

    test('a JPEG whose headers outrun the prefix falls back to the full '
        'file', () async {
      // 三个 60 KB 的 APP2 段把 SOF 推到 128 KiB 前缀之外；EXIF 方向 6 在它们之后。
      final Uint8List jpeg = Uint8List.fromList(
        img.encodeJpg(
          img.Image(width: 30, height: 20)..exif.imageIfd.orientation = 6,
        ),
      );
      final BytesBuilder padded = BytesBuilder(copy: false)
        ..add(jpeg.sublist(0, 2));
      for (int i = 0; i < 3; i++) {
        const int payload = 60 * 1024;
        padded
          ..add(<int>[0xFF, 0xE2, (payload + 2) >> 8, (payload + 2) & 0xFF])
          ..add(Uint8List(payload));
      }
      padded.add(jpeg.sublist(2));
      final Uint8List bytes = padded.takeBytes();
      expect(
        probeImageSizeFromPrefix(
          Uint8List.sublistView(
            bytes,
            0,
            MangaImporter.kPageSizeProbePrefixBytes,
          ),
        ),
        isNull,
      );
      final File file = File(p.join(root.path, 'tall.jpg'))
        ..writeAsBytesSync(bytes);
      final MokuroSize size = await MangaImporter.pageSizeOfFile(
        file,
        'tall.jpg',
      );
      expect((size.width, size.height), (20.0, 30.0));
    });

    test('a PNG with a large tail is sized from its header', () async {
      final File file = File(p.join(root.path, 'tail.png'))
        ..writeAsBytesSync(<int>[
          ...png(33, height: 44),
          ...Uint8List(MangaImporter.kPageSizeProbePrefixBytes * 4),
        ]);
      final MokuroSize size = await MangaImporter.pageSizeOfFile(
        file,
        'tail.png',
      );
      expect((size.width, size.height), (33.0, 44.0));
    });

    test(
      'formats the prefix cannot settle (BMP) still size correctly',
      () async {
        final File file = File(p.join(root.path, 'page.bmp'))
          ..writeAsBytesSync(img.encodeBmp(img.Image(width: 24, height: 16)));
        expect(probeImageSizeFromPrefix(file.readAsBytesSync()), isNull);
        final MokuroSize size = await MangaImporter.pageSizeOfFile(
          file,
          'page.bmp',
        );
        expect((size.width, size.height), (24.0, 16.0));
      },
    );
  });
}

String _writeCbz(Directory dir, String name, Map<String, Uint8List> pages) {
  final Archive archive = Archive();
  pages.forEach((String entry, Uint8List bytes) {
    archive.addFile(ArchiveFile(entry, bytes.length, bytes));
  });
  final String path = p.join(dir.path, name);
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

/// 两页 STORE 的 CBZ，第一页数据区中间翻转一个字节（中央目录与 CRC 仍是原图的）。
String _writeCorruptCbz(Directory dir, String name, Uint8List page) {
  final Archive archive = Archive()
    ..addFile(ArchiveFile('1.png', page.length, page)..compress = false)
    ..addFile(ArchiveFile('2.png', page.length, page)..compress = false);
  final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
  const int dataStart = 30 + '1.png'.length;
  bytes[dataStart + page.length ~/ 2] ^= 0xFF;
  final String path = p.join(dir.path, name);
  File(path).writeAsBytesSync(bytes);
  return path;
}

const String _containerXml = '''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>''';

const String _opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Image EPUB</dc:title>
  </metadata>
  <manifest>
    <item id="page1" href="text/1.xhtml" media-type="application/xhtml+xml"/>
    <item id="page2" href="text/2.xhtml" media-type="application/xhtml+xml"/>
    <item id="image1" href="images/1.png" media-type="image/png"/>
    <item id="image2" href="images/2.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="page1"/>
    <itemref idref="page2"/>
  </spine>
</package>''';

String _xhtml(String body) =>
    '<html xmlns="http://www.w3.org/1999/xhtml"><body>$body</body></html>';

/// container / OPF / 两页 XHTML，全部 STORE、大小与 CRC 诚实。
List<_RawZipEntry> _storedEpubSkeleton() {
  _RawZipEntry stored(String name, String text) {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(text));
    return _RawZipEntry(
      name,
      bytes,
      declaredSize: bytes.length,
      crc: getCrc32(bytes),
      method: 0,
    );
  }

  return <_RawZipEntry>[
    stored('META-INF/container.xml', _containerXml),
    stored('OEBPS/content.opf', _opf),
    stored('OEBPS/text/1.xhtml', _xhtml('<img src="../images/1.png"/>')),
    stored('OEBPS/text/2.xhtml', _xhtml('<img src="../images/2.png"/>')),
  ];
}

String _writeImageEpub(
  Directory root, {
  required Uint8List first,
  required Uint8List second,
  String page2Body = '<img src="../images/2.png"/>',
}) {
  final Map<String, List<int>> entries = <String, List<int>>{
    'META-INF/container.xml': utf8.encode(_containerXml),
    'OEBPS/content.opf': utf8.encode(_opf),
    'OEBPS/text/1.xhtml': utf8.encode(_xhtml('<img src="../images/1.png"/>')),
    'OEBPS/text/2.xhtml': utf8.encode(_xhtml(page2Body)),
    'OEBPS/images/1.png': first,
    'OEBPS/images/2.png': second,
  };
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final String path = p.join(root.path, 'book.epub');
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

/// [length] 个零字节的 raw deflate，分块喂编码器。
Uint8List _deflateZeros(int length) {
  final BytesBuilder out = BytesBuilder(copy: false);
  final ByteConversionSink encoder = io.ZLibEncoder(
    raw: true,
  ).startChunkedConversion(ByteConversionSink.withCallback(out.add));
  final Uint8List zeros = Uint8List(1024 * 1024);
  for (int done = 0; done < length; done += zeros.length) {
    final int n = length - done < zeros.length ? length - done : zeros.length;
    encoder.addSlice(zeros, 0, n, false);
  }
  encoder.close();
  return out.takeBytes();
}

/// [length] 个零字节的 CRC-32（分块续算）。
int _crc32OfZeros(int length) {
  final Uint8List zeros = Uint8List(1024 * 1024);
  int crc = 0;
  for (int done = 0; done < length; done += zeros.length) {
    final int n = length - done < zeros.length ? length - done : zeros.length;
    crc = getCrc32(n == zeros.length ? zeros : Uint8List(n), crc);
  }
  return crc;
}

/// 手工拼的 zip 条目：[data] 已按 [method] 编码好，[declaredSize] / [crc] 原样写进
/// 本地头与中央目录（可以谎报）。
class _RawZipEntry {
  _RawZipEntry(
    this.name,
    this.data, {
    required this.declaredSize,
    required this.crc,
    this.method = 8,
  });

  final String name;
  final Uint8List data;
  final int declaredSize;
  final int crc;
  final int method;
}

Uint8List _buildRawZip(List<_RawZipEntry> entries) {
  final BytesBuilder out = BytesBuilder(copy: false);
  final List<int> offsets = <int>[];
  Uint8List u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  Uint8List u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

  for (final _RawZipEntry entry in entries) {
    final List<int> name = utf8.encode(entry.name);
    offsets.add(out.length);
    out
      ..add(u32(0x04034b50))
      ..add(u16(20))
      ..add(u16(0))
      ..add(u16(entry.method))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(entry.crc))
      ..add(u32(entry.data.length))
      ..add(u32(entry.declaredSize))
      ..add(u16(name.length))
      ..add(u16(0))
      ..add(name)
      ..add(entry.data);
  }
  final int directoryOffset = out.length;
  for (int i = 0; i < entries.length; i++) {
    final _RawZipEntry entry = entries[i];
    final List<int> name = utf8.encode(entry.name);
    out
      ..add(u32(0x02014b50))
      ..add(u16(20))
      ..add(u16(20))
      ..add(u16(0))
      ..add(u16(entry.method))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(entry.crc))
      ..add(u32(entry.data.length))
      ..add(u32(entry.declaredSize))
      ..add(u16(name.length))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u32(0))
      ..add(u32(offsets[i]))
      ..add(name);
  }
  final int directorySize = out.length - directoryOffset;
  out
    ..add(u32(0x06054b50))
    ..add(u16(0))
    ..add(u16(0))
    ..add(u16(entries.length))
    ..add(u16(entries.length))
    ..add(u32(directorySize))
    ..add(u32(directoryOffset))
    ..add(u16(0));
  return out.takeBytes();
}
