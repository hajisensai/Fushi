import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show ZLibEncoder;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('manga_archive_');
    app = Directory.systemTemp.createTempSync('manga_archive_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (app.existsSync()) app.deleteSync(recursive: true);
  });

  test(
    'CBZ with a corrupt page entry fails on CRC instead of importing junk',
    () async {
      // 流式打开只读中央目录、不整包 verify；写盘条目必须补 CRC 校验，否则位翻转
      // 的坏页会被当正常页写进书。STORE 条目：翻转数据区一个字节，中央目录仍完好。
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 80)),
      );
      final Archive archive = Archive()
        ..addFile(ArchiveFile('1.png', png.length, png)..compress = false)
        ..addFile(ArchiveFile('2.png', png.length, png)..compress = false);
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
      // 本地文件头 30 字节 + 文件名 5 字节后就是第一页的原始数据；翻转其中间一个字节。
      const int dataStart = 30 + '1.png'.length;
      bytes[dataStart + png.length ~/ 2] ^= 0xFF;
      final String path = p.join(root.path, 'corrupt.cbz');
      File(path).writeAsBytesSync(bytes);

      expect(
        MangaArchiveImporter.looksLikeImageArchive(path),
        isTrue,
        reason: '探测只看条目名，不为坏页整包解压',
      );
      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: path),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('CRC'),
          ),
        ),
      );
      expect(await db.getEpubBookMetas(), isEmpty, reason: '不落任何行');
    },
  );

  group('zip extraction enforces limits on actually inflated bytes', () {
    // 这组用例手工拼 zip（[_buildRawZip]），这样中央目录 / 本地头声明的大小、
    // CRC、加密位都能随意谎报——`ZipEncoder` 只会写诚实的包。

    test('a lying 512 MiB deflate bomb aborts at its declared size, '
        'without inflating it into memory or leaving staging behind', () async {
      // 声明 1000 字节，实际 inflate 出 512 MiB 全零（CRC 写的是真实内容的，
      // 只有大小在撒谎）。旧实现按声明大小做预检（1000 字节轻松通过），再用
      // `entry.content` 把整条 512 MiB 解进内存、写盘。
      const int bombBytes = 512 * 1024 * 1024;
      final Uint8List compressed = _deflateZeros(bombBytes);
      final String path = p.join(root.path, 'bomb.cbz');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          _RawZipEntry(
            '001.png',
            compressed,
            declaredSize: 1000,
            crc: _crc32OfZeros(bombBytes),
          ),
        ]),
      );
      final Set<String> stagingBefore = _mangaStagingDirs();
      final int rssBefore = ProcessInfo.currentRss;
      final int peakBefore = ProcessInfo.maxRss;

      Object? error;
      try {
        await MangaArchiveImporter.importArchive(db: db, archivePath: path);
      } catch (e) {
        error = e;
      }

      // 峰值 RSS 要么没刷新，要么只比导入前多出远小于炸弹体积的量（一个 inflate
      // 分片的产出 + 读缓冲）。旧实现会在这里多出 ≥ 512 MiB。先断言内存再断言
      // 报错文案，免得文案先红把内存这条断言遮住。
      final int peakAfter = ProcessInfo.maxRss;
      expect(
        peakAfter <= peakBefore || peakAfter - rssBefore < 128 * 1024 * 1024,
        isTrue,
        reason:
            'peak RSS grew from $rssBefore to $peakAfter (previous peak '
            '$peakBefore) while rejecting the bomb',
      );
      expect(
        _mangaStagingDirs().difference(stagingBefore),
        isEmpty,
        reason: '中止后 staging（含写了一半的页）必须删掉',
      );
      expect(
        error,
        isA<MangaImportException>().having(
          (MangaImportException e) => e.message,
          'message',
          contains('expands beyond its declared 1000 bytes'),
        ),
      );
      expect(await db.getAllEpubBooks(), isEmpty);
    });

    test(
      'an entry that inflates to fewer bytes than declared is corrupt',
      () async {
        final Uint8List page = Uint8List.fromList(
          List<int>.generate(1000, (int i) => i % 251),
        );
        final String path = p.join(root.path, 'short.cbz');
        File(path).writeAsBytesSync(
          _buildRawZip(<_RawZipEntry>[
            _RawZipEntry(
              '001.png',
              _deflate(page),
              declaredSize: 2000,
              crc: getCrc32(page),
            ),
          ]),
        );

        await expectLater(
          MangaArchiveImporter.importArchive(db: db, archivePath: path),
          throwsA(
            isA<MangaImportException>().having(
              (MangaImportException e) => e.message,
              'message',
              contains('size mismatch: declares 2000 bytes, contains 1000'),
            ),
          ),
        );
        expect(await db.getAllEpubBooks(), isEmpty);
      },
    );

    test('a deflated entry whose CRC does not match fails on CRC', () async {
      final Uint8List page = Uint8List.fromList(
        List<int>.generate(4096, (int i) => i % 253),
      );
      final String path = p.join(root.path, 'badcrc.cbz');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          _RawZipEntry(
            '001.png',
            _deflate(page),
            declaredSize: page.length,
            crc: getCrc32(page) ^ 0x1,
          ),
        ]),
      );

      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: path),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('CRC mismatch'),
          ),
        ),
      );
    });

    test('an honest entry above the per-entry limit is rejected', () async {
      final Uint8List page = Uint8List(2 * 1024 * 1024);
      final String path = p.join(root.path, 'huge_page.cbz');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          _RawZipEntry(
            '001.png',
            _deflate(page),
            declaredSize: page.length,
            crc: getCrc32(page),
          ),
        ]),
      );
      final Set<String> stagingBefore = _mangaStagingDirs();

      await expectLater(
        MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
          limits: const MangaArchiveExtractionLimits(
            maxEntryBytes: 1024 * 1024,
          ),
        ),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('Manga archive entry is too large: 001.png'),
          ),
        ),
      );
      expect(_mangaStagingDirs().difference(stagingBefore), isEmpty);
      expect(await db.getAllEpubBooks(), isEmpty);
    });

    test('pages that together exceed the total limit are rejected', () async {
      final Uint8List page = Uint8List(400 * 1024);
      final String path = p.join(root.path, 'many_pages.cbz');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          for (int i = 1; i <= 3; i++)
            _RawZipEntry(
              '00$i.png',
              _deflate(page),
              declaredSize: page.length,
              crc: getCrc32(page),
            ),
        ]),
      );

      await expectLater(
        MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
          limits: const MangaArchiveExtractionLimits(
            maxTotalBytes: 1024 * 1024,
          ),
        ),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('Manga archive is too large'),
          ),
        ),
      );
      expect(await db.getAllEpubBooks(), isEmpty);
    });

    test('encrypted entries are reported as unsupported', () async {
      final Uint8List page = Uint8List.fromList(
        List<int>.generate(64, (int i) => i),
      );
      final String path = p.join(root.path, 'encrypted.cbz');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          _RawZipEntry(
            '001.png',
            page,
            method: 0,
            declaredSize: page.length,
            crc: getCrc32(page),
            flags: 0x1,
          ),
        ]),
      );

      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: path),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('encrypted'),
          ),
        ),
      );
    });

    test('a hand-built honest deflate + store archive still imports', () async {
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 80)),
      );
      final String path = p.join(root.path, 'honest.cbz');
      File(path).writeAsBytesSync(
        _buildRawZip(<_RawZipEntry>[
          _RawZipEntry(
            '1.png',
            _deflate(png),
            declaredSize: png.length,
            crc: getCrc32(png),
          ),
          _RawZipEntry(
            '2.png',
            png,
            method: 0,
            declaredSize: png.length,
            crc: getCrc32(png),
          ),
        ]),
      );

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
      );
      final EpubBookRow row = (await db.getEpubBook(key))!;
      for (final String name in <String>['1.png', '2.png']) {
        expect(
          File(p.join(row.extractDir, 'images', name)).readAsBytesSync(),
          png,
          reason: '$name must be written byte-for-byte',
        );
      }
    });
  });

  test(
    'CBZ of AVIF pages imports with displayed (irot / grid) page sizes',
    () async {
      // 用户反馈「不支持含 AVIF 图片的 CBZ」：以前 `.avif` 不在页图白名单里，整包报
      // 「Manga archive has no images」；放进白名单后尺寸回退又走 package:image 解不开。
      // 样本与 native/fushi_compute 的单元测试共用（libavif 生成）。
      Uint8List avif(String name) => File(
        p.join(
          '..',
          'packages',
          'fushi_engine',
          'test',
          'media',
          'image_kernels',
          'fixtures',
          'avif',
          '$name.avif',
        ),
      ).readAsBytesSync();
      final Uint8List rotated = avif('orient6'); // 40×24 编码，irot → 24×40
      final Uint8List grid = avif('grid'); // 2×2 瓦片拼成 72×60
      final Uint8List plain = avif('rgb420'); // 61×47
      final String path = _writeArchive(root, <ArchiveFile>[
        ArchiveFile('001.avif', rotated.length, rotated),
        ArchiveFile('002.AVIF', grid.length, grid),
        ArchiveFile('003.avif', plain.length, plain),
      ]);
      expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
      );
      final MokuroPayload payload = await _readImportedPayload(db, key);
      expect(
        payload.images
            .map((MokuroImage i) => (i.size.width, i.size.height))
            .toList(),
        <(double, double)>[(24, 40), (72, 60), (61, 47)],
      );
      final EpubBookRow row = (await db.getEpubBook(key))!;
      for (final MokuroImage image in payload.images) {
        expect(
          File(p.join(row.extractDir, image.url)).existsSync(),
          isTrue,
          reason: image.url,
        );
      }
    },
  );

  test('CBZ images import in natural order', () async {
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 80)),
    );
    final String path = _writeArchive(root, <ArchiveFile>[
      ArchiveFile('10.png', png.length, png),
      ArchiveFile('2.png', png.length, png),
      ArchiveFile('1.png', png.length, png),
    ]);
    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final EpubBookRow row = (await db.getEpubBook(key))!;
    final String json = File(
      p.join(row.extractDir, MangaStorage.kMangaJsonFileName),
    ).readAsStringSync();
    expect(
      json.indexOf('images/1.png'),
      lessThan(json.indexOf('images/2.png')),
    );
    expect(
      json.indexOf('images/2.png'),
      lessThan(json.indexOf('images/10.png')),
    );
  });

  test(
    'RAR images import through 7-Zip with path and size preflight',
    () async {
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 80)),
      );
      final String archivePath = p.join(root.path, 'book.rar');
      File(archivePath).writeAsBytesSync(<int>[0x52, 0x61, 0x72, 0x21]);
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'RAR manga',
          mediaKind: 'manga',
          rootPath: root.path,
          createdAt: 1000,
        ),
      );
      final List<List<String>> calls = <List<String>>[];
      final MangaSevenZipExtractor extractor = MangaSevenZipExtractor(
        sevenZipOverride: 'fake-7z',
        runProcess: (String executable, List<String> arguments) async {
          calls.add(arguments);
          if (arguments.first == 'l') {
            return ProcessResult(1, 0, '''
Path = $archivePath
Type = Rar

----------
Path = pages\\001.png
Size = ${png.length}
Attributes = A

Path = notes.txt
Size = 5000000000
Attributes = A
''', '');
          }
          final String outputArg = arguments.firstWhere(
            (String arg) => arg.startsWith('-o'),
          );
          final File page = File(
            p.join(outputArg.substring(2), 'pages', '001.png'),
          );
          page.parent.createSync(recursive: true);
          page.writeAsBytesSync(png);
          return ProcessResult(2, 0, '', '');
        },
      );

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: archivePath,
        sourceId: sourceId,
        sevenZipExtractor: extractor,
      );

      expect((await db.getEpubBook(key))!.sourceId, sourceId);
      expect(calls.map((List<String> args) => args.first), <String>['l', 'x']);
      expect(calls.last, contains('-ir!*.png'));
    },
  );

  test('RAR traversal is rejected before extraction', () async {
    final String archivePath = p.join(root.path, 'unsafe.cbr');
    File(archivePath).writeAsBytesSync(<int>[0x52, 0x61, 0x72, 0x21]);
    bool extracted = false;
    final MangaSevenZipExtractor extractor = MangaSevenZipExtractor(
      sevenZipOverride: 'fake-7z',
      runProcess: (String executable, List<String> arguments) async {
        if (arguments.first == 'l') {
          return ProcessResult(1, 0, '''
Path = $archivePath
Type = Rar

----------
Path = ..\\escape.png
Size = 3
Attributes = A
''', '');
        }
        extracted = true;
        return ProcessResult(2, 0, '', '');
      },
    );

    await expectLater(
      MangaArchiveImporter.importArchive(
        db: db,
        archivePath: archivePath,
        sevenZipExtractor: extractor,
      ),
      throwsA(isA<MangaImportException>()),
    );
    expect(extracted, isFalse);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  for (final String extension in <String>['.cbz', '.zip']) {
    test('embedded root Mokuro OCR survives $extension import', () async {
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 80)),
      );
      final String path = _writeArchive(root, <ArchiveFile>[
        _textEntry('book.mokuro', _mokuroJson('images/001.png', '埋め込み')),
        _textEntry('legacy.html', '<html>legacy mokuro reader</html>'),
        ArchiveFile('images/001.png', png.length, png),
      ], name: 'book$extension');
      expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
      );
      final MokuroPayload payload = await _readImportedPayload(db, key);
      expect(payload.images, hasLength(1));
      expect(payload.images.single.url, 'images/001.png');
      expect(payload.images.single.size.width, 40);
      final MokuroBlock block = payload.images.single.blocks.single;
      expect(block.lines, <String>['埋め込み']);
      expect(block.rectangle, const MokuroRect.fromLTRB(1, 2, 30, 40));
      expect(block.isVertical, isTrue);
      expect(block.fontSize, 17);
      expect(block.linesCoords, isNotNull);
    });
  }

  test('exact sibling .mokuro supplies OCR for a CBZ', () async {
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 80)),
    );
    final String path = _writeArchive(root, <ArchiveFile>[
      ArchiveFile('001.png', png.length, png),
    ]);
    File(
      p.join(root.path, 'book.mokuro'),
    ).writeAsStringSync(_mokuroJson('001.png', 'サイドカー'));

    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final MokuroPayload payload = await _readImportedPayload(db, key);
    expect(payload.images.single.blocks.single.lines, <String>['サイドカー']);
  });

  test(
    'nested manifest resolves its volume subdirectory without cross-binding',
    () async {
      final Uint8List wanted = Uint8List.fromList(
        img.encodePng(img.Image(width: 41, height: 80)),
      );
      final Uint8List decoy = Uint8List.fromList(
        img.encodePng(img.Image(width: 99, height: 80)),
      );
      final String path = _writeArchive(root, <ArchiveFile>[
        _textEntry(
          'Series/Vol.mokuro',
          _mokuroJson('001.png', '正しい巻', width: 41),
        ),
        ArchiveFile('Series/Vol/001.png', wanted.length, wanted),
        ArchiveFile('Other/001.png', decoy.length, decoy),
      ]);

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
      );
      final MokuroPayload payload = await _readImportedPayload(db, key);
      expect(payload.images.single.size.width, 41);
      expect(payload.images.single.blocks.single.lines, <String>['正しい巻']);
    },
  );

  test('Windows separators in Mokuro and ZIP entries are normalized', () async {
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 80)),
    );
    final String path = _writeArchive(root, <ArchiveFile>[
      _textEntry('book.mokuro', _mokuroJson(r'images\001.png', 'Windows path')),
      ArchiveFile(r'images\001.png', png.length, png),
    ]);

    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final MokuroPayload payload = await _readImportedPayload(db, key);
    expect(payload.images.single.url, isNot(contains(r'\')));
    expect(payload.images.single.blocks.single.lines, <String>['Windows path']);
  });

  test(
    'multiple manifests deterministically prefer the matching archive name',
    () async {
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 80)),
      );
      final String path = _writeArchive(root, <ArchiveFile>[
        _textEntry('decoy.mokuro', _mokuroJson('missing.png', 'wrong')),
        _textEntry('book.mokuro', _mokuroJson('001.png', 'right')),
        ArchiveFile('001.png', png.length, png),
      ]);

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
      );
      final MokuroPayload payload = await _readImportedPayload(db, key);
      expect(payload.images.single.blocks.single.lines, <String>['right']);
    },
  );

  test(
    'invalid embedded Mokuro fails instead of silently discarding OCR',
    () async {
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 40, height: 80)),
      );
      final String path = _writeArchive(root, <ArchiveFile>[
        _textEntry('book.mokuro', '{not json'),
        ArchiveFile('001.png', png.length, png),
      ]);

      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: path),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException error) => error.message,
            'message',
            contains('Mokuro OCR metadata'),
          ),
        ),
      );
      expect(await db.getAllEpubBooks(), isEmpty);
    },
  );

  test('rejects traversal before extracting any archive entry', () async {
    final String path = _writeArchive(root, <ArchiveFile>[
      ArchiveFile('../escape.png', 3, <int>[1, 2, 3]),
    ]);
    await expectLater(
      MangaArchiveImporter.importArchive(db: db, archivePath: path),
      throwsA(isA<MangaImportException>()),
    );
    expect(File(p.join(root.parent.path, 'escape.png')).existsSync(), isFalse);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('pure image EPUB imports in spine order', () async {
    final Uint8List first = Uint8List.fromList(
      img.encodePng(img.Image(width: 20, height: 40)),
    );
    final Uint8List second = Uint8List.fromList(
      img.encodePng(img.Image(width: 30, height: 40)),
    );
    final String path = _writeImageEpub(
      root,
      first: first,
      second: second,
      firstSpineId: 'page2',
    );
    expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);

    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final EpubBookRow row = (await db.getEpubBook(key))!;
    final img.Image importedFirst = img.decodeImage(
      File(
        p.join(row.extractDir, 'images', 'page_000000.png'),
      ).readAsBytesSync(),
    )!;
    expect(importedFirst.width, 30);
  });

  test('KCC Panel View EPUB imports one manga page per spine page', () async {
    // Each KCC page references its image once visibly plus four hidden
    // `.PV-P` magnify regions; every <img> used to become its own page, so a
    // 197-page volume imported as 985 pages (each page five times).
    final Uint8List first = Uint8List.fromList(
      img.encodePng(img.Image(width: 20, height: 40)),
    );
    final Uint8List second = Uint8List.fromList(
      img.encodePng(img.Image(width: 30, height: 40)),
    );
    const String region =
        '<div class="PV-P">'
        '<img src="../images/1.png" width="40" height="80"/></div>';
    final String path = _writeImageEpub(
      root,
      first: first,
      second: second,
      firstSpineId: 'page1',
      page1Body:
          '<div><img src="../images/1.png"/></div>'
          '<div id="PV"><div id="PV-TL"><a class="app-amzn-magnify"></a>'
          '</div></div>'
          '${region * 4}',
    );
    expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);

    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final EpubBookRow row = (await db.getEpubBook(key))!;
    final List<String> pages =
        Directory(
            p.join(row.extractDir, 'images'),
          ).listSync().map((FileSystemEntity e) => p.basename(e.path)).toList()
          ..sort();
    expect(pages, <String>['page_000000.png', 'page_000001.png']);
    final img.Image importedSecond = img.decodeImage(
      File(
        p.join(row.extractDir, 'images', 'page_000001.png'),
      ).readAsBytesSync(),
    )!;
    expect(importedSecond.width, 30);
  });

  test('EPUB containing a text spine page stays a normal EPUB', () {
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 20, height: 40)),
    );
    final String path = _writeImageEpub(
      root,
      first: png,
      second: png,
      firstSpineId: 'page1',
      page1Body: '<p>これは画像だけではない本文ページです。</p>',
    );
    expect(MangaArchiveImporter.looksLikeImageArchive(path), isFalse);
  });
}

String _writeArchive(
  Directory root,
  List<ArchiveFile> entries, {
  String name = 'book.cbz',
}) {
  final Archive archive = Archive();
  for (final ArchiveFile entry in entries) {
    archive.addFile(entry);
  }
  final String path = p.join(root.path, name);
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

/// 系统临时目录里导入器的 staging 目录名（`fushi_manga_archive_*`）。
Set<String> _mangaStagingDirs() => Directory.systemTemp
    .listSync(followLinks: false)
    .whereType<Directory>()
    .map((Directory dir) => p.basename(dir.path))
    .where((String name) => name.startsWith('fushi_manga_archive_'))
    .toSet();

/// raw deflate（zip method 8 的数据格式）。
Uint8List _deflate(List<int> bytes) =>
    Uint8List.fromList(io.ZLibEncoder(raw: true).convert(bytes));

/// [length] 个零字节的 raw deflate，分块喂编码器，不在测试里先分配 [length] 字节。
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

/// [length] 个零字节的 CRC-32（分块续算，同样不先分配 [length] 字节）。
int _crc32OfZeros(int length) {
  final Uint8List zeros = Uint8List(1024 * 1024);
  int crc = 0;
  for (int done = 0; done < length; done += zeros.length) {
    final int n = length - done < zeros.length ? length - done : zeros.length;
    crc = getCrc32(n == zeros.length ? zeros : Uint8List(n), crc);
  }
  return crc;
}

/// 手工拼的 zip 条目：[data] 是**已经按 [method] 编码好**的数据，
/// [declaredSize] / [crc] / [flags] 原样写进本地头与中央目录（可以谎报）。
class _RawZipEntry {
  _RawZipEntry(
    this.name,
    this.data, {
    required this.declaredSize,
    required this.crc,
    this.method = 8,
    this.flags = 0,
  });

  final String name;
  final Uint8List data;
  final int declaredSize;
  final int crc;
  final int method;
  final int flags;
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
      ..add(u16(entry.flags))
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
      ..add(u16(entry.flags))
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

ArchiveFile _textEntry(String name, String value) {
  final List<int> bytes = utf8.encode(value);
  return ArchiveFile(name, bytes.length, bytes);
}

String _mokuroJson(String imagePath, String text, {int width = 40}) {
  return jsonEncode(<String, Object?>{
    'title': 'Book',
    'pages': <Object?>[
      <String, Object?>{
        'img_path': imagePath,
        'img_width': width,
        'img_height': 80,
        'blocks': <Object?>[
          <String, Object?>{
            'box': <int>[1, 2, 30, 40],
            'vertical': true,
            'font_size': 17,
            'lines': <String>[text],
            'lines_coords': <Object?>[
              <Object?>[
                <int>[1, 2],
                <int>[30, 40],
              ],
            ],
          },
        ],
      },
    ],
  });
}

Future<MokuroPayload> _readImportedPayload(FushiDatabase db, String key) async {
  final EpubBookRow row = (await db.getEpubBook(key))!;
  final String json = File(
    p.join(row.extractDir, MangaStorage.kMangaJsonFileName),
  ).readAsStringSync();
  return parseMangaJson(json);
}

String _writeImageEpub(
  Directory root, {
  required Uint8List first,
  required Uint8List second,
  required String firstSpineId,
  String page1Body = '<img src="../images/1.png"/>',
}) {
  final String secondSpineId = firstSpineId == 'page1' ? 'page2' : 'page1';
  final Map<String, List<int>> entries = <String, List<int>>{
    'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>'''),
    'OEBPS/content.opf': utf8.encode('''
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
    <itemref idref="$firstSpineId"/>
    <itemref idref="$secondSpineId"/>
  </spine>
</package>'''),
    'OEBPS/text/1.xhtml': utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>$page1Body</body></html>',
    ),
    'OEBPS/text/2.xhtml': utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
      '<img src="../images/2.png"/></body></html>',
    ),
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
