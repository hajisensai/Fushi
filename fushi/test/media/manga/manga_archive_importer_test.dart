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
import 'package:fushi_engine/utils/archive/archive_passwords.dart';
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
      final Set<String> stagingBefore = _mangaStagingDirs(app);
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
        _mangaStagingDirs(app).difference(stagingBefore),
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
      final Set<String> stagingBefore = _mangaStagingDirs(app);

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
      expect(_mangaStagingDirs(app).difference(stagingBefore), isEmpty);
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

  group('zip containers written by real-world archivers', () {
    test('names without the UTF-8 flag (Shift_JIS) still probe and import, '
        'in natural order', () async {
      // Windows 日文环境的压缩工具把文件名按 Shift_JIS 写、且不置通用位 11。
      // archive 3.6.1 读本地头文件名走 InputFileStream.readString，严格 UTF-8 解码
      // 直接抛 FormatException，整个包打不开：导入框里表现为「不支持的文件格式 .zip」。
      // 「第1話/」= 91 E6 31 98 62 2F。
      const List<int> folder = <int>[0x91, 0xE6, 0x31, 0x98, 0x62, 0x2F];
      final Uint8List narrow = Uint8List.fromList(
        img.encodePng(img.Image(width: 30, height: 60)),
      );
      final Uint8List wide = Uint8List.fromList(
        img.encodePng(img.Image(width: 50, height: 70)),
      );
      final String path = p.join(root.path, 'sjis.zip');
      File(path).writeAsBytesSync(
        _buildZip(<_ZipSpec>[
          _ZipSpec(<int>[...folder, ...ascii.encode('10.png')], wide),
          _ZipSpec(<int>[...folder, ...ascii.encode('2.png')], narrow),
        ]),
      );

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
        <(double, double)>[(30, 60), (50, 70)],
        reason: '2.png before 10.png inside the Shift_JIS folder',
      );
    });

    test(
      'names without the UTF-8 flag are decoded with their real legacy '
      'encoding (0x5C / 0x7C trail bytes stay inside the character)',
      () async {
        // design-zip-cp932-names：逐字节名里「表」「ソ」的尾字节 0x5C 被当成 `\` 多切一级目录，
        // 「ポ」的尾字节 0x7C 变成 Windows 不许出现在文件名里的 `|`（整本写盘失败）。
        // 「第1話/」= 91 E6 31 98 62 2F；「ポ」= 83 7C；「表紙/」= 95 5C 8E 86 2F；「ソ」= 83 5C。
        const List<int> episode = <int>[0x91, 0xE6, 0x31, 0x98, 0x62, 0x2F];
        const List<int> po = <int>[0x83, 0x7C];
        const List<int> cover = <int>[0x95, 0x5C, 0x8E, 0x86, 0x2F];
        const List<int> so = <int>[0x83, 0x5C];
        Uint8List page(int width) => Uint8List.fromList(
          img.encodePng(img.Image(width: width, height: 60)),
        );
        final String path = p.join(root.path, 'sjis_trail_bytes.zip');
        File(path).writeAsBytesSync(
          _buildZip(<_ZipSpec>[
            _ZipSpec(<int>[
              ...cover,
              ...so,
              ...ascii.encode('1.png'),
            ], page(10)),
            _ZipSpec(<int>[
              ...episode,
              ...po,
              ...ascii.encode('10.png'),
            ], page(30)),
            _ZipSpec(<int>[
              ...episode,
              ...po,
              ...ascii.encode('2.png'),
            ], page(20)),
          ]),
        );

        final String key = await MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
        );
        final MokuroPayload payload = await _readImportedPayload(db, key);
        // 页图拷进书目录的 `images/` 下，保留包内子目录结构。
        expect(payload.images.map((MokuroImage i) => i.url).toList(), <String>[
          'images/第1話/ポ2.png',
          'images/第1話/ポ10.png',
          'images/表紙/ソ1.png',
        ]);
        expect(
          payload.images.map((MokuroImage i) => i.size.width).toList(),
          <double>[20, 30, 10],
        );
      },
    );

    test(
      'UTF-8 names without the UTF-8 flag (macOS Archive Utility) keep their '
      'names and Mokuro OCR',
      () async {
        // macOS「压缩」按 UTF-8 写名字、却不置通用位 11。archive 本来就按 UTF-8 解对了；
        // 本地编码判据没有排除 UTF-8 的维度，这些名字若送去重解会被判成 Shift_JIS
        // 解成「隨ｬ1蟾ｻ/001.png」这类乱码，清单 img_path 对不上，整本导入失败。
        Uint8List page(int width) => Uint8List.fromList(
          img.encodePng(img.Image(width: width, height: 80)),
        );
        final String path = p.join(root.path, 'mac.cbz');
        File(path).writeAsBytesSync(
          _buildZip(<_ZipSpec>[
            _ZipSpec(
              utf8.encode('ポスター.mokuro'),
              Uint8List.fromList(
                utf8.encode(_mokuroJson('第1巻/001.png', 'マック', width: 40)),
              ),
              utf8Flag: false,
            ),
            _ZipSpec(utf8.encode('第1巻/001.png'), page(40), utf8Flag: false),
          ]),
        );

        expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);
        final String key = await MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
        );
        final MokuroPayload payload = await _readImportedPayload(db, key);
        expect(payload.images, hasLength(1));
        // 页图拷进书目录的 `images/` 下，保留包内子目录结构。
        expect(payload.images.single.url, 'images/第1巻/001.png');
        expect(payload.images.single.size.width, 40);
        expect(payload.images.single.blocks.single.lines, <String>['マック']);
      },
    );

    test(
      'ZIP64 records with 8-byte data descriptors import byte-for-byte',
      () async {
        // 超过 4 GiB 的包（或流式写出的包）用 ZIP64：中央目录大小 / 偏移是 0xFFFFFFFF，
        // 真值在 ZIP64 extra 与 ZIP64 EOCD 里；数据描述符（通用位 3）的大小字段是
        // 8 字节。archive 3.6.1 把描述符按 4 字节读、覆盖 ArchiveFile.size（读成 0），
        // 流式解压随即报「expands beyond its declared 0 bytes」。中央目录才是权威。
        // 这里用小条目把同一种记录形状写出来，不必真造 4 GiB。
        final Uint8List first = Uint8List.fromList(
          img.encodePng(img.Image(width: 40, height: 80)),
        );
        final Uint8List second = Uint8List.fromList(
          img.encodePng(img.Image(width: 64, height: 32)),
        );
        final String path = p.join(root.path, 'zip64.cbz');
        File(path).writeAsBytesSync(
          _buildZip(<_ZipSpec>[
            _ZipSpec(utf8.encode('001.png'), first, deflate: true),
            _ZipSpec(utf8.encode('002.png'), second),
          ], zip64: true),
        );

        expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);
        final String key = await MangaArchiveImporter.importArchive(
          db: db,
          archivePath: path,
        );
        final EpubBookRow row = (await db.getEpubBook(key))!;
        expect(
          File(p.join(row.extractDir, 'images', '001.png')).readAsBytesSync(),
          first,
        );
        expect(
          File(p.join(row.extractDir, 'images', '002.png')).readAsBytesSync(),
          second,
        );
      },
    );

    test('the expanded-size budget scales with the archive, not a fixed '
        '2 GiB', () {
      // 此前总量上限是与包大小无关的 2 GiB：解出超过 2 GiB 的正常漫画包一律
      // 「Manga archive is too large」。页图进 zip 压不动，预算按包体积 × 8 推。
      const int gib = 1024 * 1024 * 1024;
      expect(mangaArchiveExpandedBudget(50 * 1024 * 1024), 2 * gib);
      expect(mangaArchiveExpandedBudget(3 * gib), 24 * gib);
      expect(
        const MangaArchiveExtractionLimits().totalBudgetFor(5 * gib),
        40 * gib,
      );
      expect(
        const MangaArchiveExtractionLimits(
          maxTotalBytes: 1024,
        ).totalBudgetFor(5 * gib),
        1024,
      );
    });

    test('the derived budget is measured from the archive file size', () async {
      // 预算按「包文件体积 × 倍数」推：体积必须取文件长度，而不是
      // `InputFileStream.length`（读完中央目录后的**剩余**字节，只有几十字节）。
      // 下限压到 1 字节、倍数 1：3 张 STORE 页（解出≈包体积）恰好放得下；
      // 若体积量错，预算只剩几十字节，这里就会报 too large。
      final Uint8List page = Uint8List.fromList(<int>[
        ...img.encodePng(img.Image(width: 20, height: 30)),
        ...Uint8List(400 * 1024),
      ]);
      final List<_RawZipEntry> entries = <_RawZipEntry>[
        for (int i = 1; i <= 3; i++)
          _RawZipEntry(
            '00$i.png',
            page,
            method: 0,
            declaredSize: page.length,
            crc: getCrc32(page),
          ),
      ];
      final String path = p.join(root.path, 'ratio.cbz');
      File(path).writeAsBytesSync(_buildRawZip(entries));
      const MangaArchiveExtractionLimits tight = MangaArchiveExtractionLimits(
        minTotalBytes: 1,
        maxExpansionRatio: 1,
      );

      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        limits: tight,
      );
      expect((await db.getEpubBook(key))!.chapterCount, 3);
    });

    test('a tiny archive declaring more than its budget is still rejected '
        'before anything is extracted', () async {
      // 按比例放宽后炸弹防线仍在：几百字节的包诚实声明 9 × 255 MiB（> 2 GiB 底），
      // 预检就拒，不解任何条目。
      final List<_RawZipEntry> entries = <_RawZipEntry>[
        for (int i = 1; i <= 9; i++)
          _RawZipEntry(
            '00$i.png',
            Uint8List.fromList(<int>[3, 0]),
            declaredSize: 255 * 1024 * 1024,
            crc: 0,
          ),
      ];
      final String path = p.join(root.path, 'declared_bomb.cbz');
      File(path).writeAsBytesSync(_buildRawZip(entries));
      final Set<String> stagingBefore = _mangaStagingDirs(app);

      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: path),
        throwsA(
          isA<MangaImportException>().having(
            (MangaImportException e) => e.message,
            'message',
            contains('Manga archive is too large'),
          ),
        ),
      );
      expect(_mangaStagingDirs(app).difference(stagingBefore), isEmpty);
      expect(await db.getAllEpubBooks(), isEmpty);
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
        runProcess:
            (String executable, List<String> arguments, {String? stdin}) async {
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
      runProcess:
          (String executable, List<String> arguments, {String? stdin}) async {
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

  group('encrypted archives', () {
    const String fixtures = '../packages/fushi_compute/test/fixtures/archive';

    for (final (String fixture, String extension) in <(String, String)>[
      ('aes256.zip', '.cbz'),
      ('zipcrypto.zip', '.zip'),
      ('header_encrypted.7z', '.cb7'),
    ]) {
      test(
        '$fixture as $extension imports after the password prompt',
        () async {
          final String archivePath = p.join(root.path, 'locked$extension');
          File(p.join(fixtures, fixture)).copySync(archivePath);
          final _AnswerPasswords passwords = _AnswerPasswords(<String?>[
            'wrong',
            'fushi-pw',
          ]);

          final String key = await MangaArchiveImporter.importArchive(
            db: db,
            archivePath: archivePath,
            sevenZipExtractor: MangaSevenZipExtractor(passwords: passwords),
          );

          expect(await db.getEpubBook(key), isNotNull);
          expect(passwords.previousWrong, <bool>[false, true]);
          expect(passwords.rememberedPasswords, <String>['fushi-pw']);
        },
      );
    }

    test('cancelling the prompt fails with a password error and imports '
        'nothing', () async {
      final String archivePath = p.join(root.path, 'locked.cbz');
      File(p.join(fixtures, 'aes256.zip')).copySync(archivePath);

      await expectLater(
        MangaArchiveImporter.importArchive(
          db: db,
          archivePath: archivePath,
          sevenZipExtractor: MangaSevenZipExtractor(
            passwords: _AnswerPasswords(<String?>[null]),
          ),
        ),
        throwsA(
          isA<MangaArchivePasswordException>().having(
            (MangaArchivePasswordException e) => e.cancelled,
            'cancelled',
            isTrue,
          ),
        ),
      );
      expect(await db.getAllEpubBooks(), isEmpty);
    });
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

/// 导入器留下的 staging 目录名。BUG-4840 起 staging 是书库根（[app] 下的
/// `fushi_books`）里的 `.tmp-*`；系统临时目录里的旧名 `fushi_manga_archive_*` 一并
/// 盯着——哪天有人把 staging 挪回去，残留也照样被抓到。
Set<String> _mangaStagingDirs(Directory app) {
  final Directory booksRoot = Directory(p.join(app.path, 'fushi_books'));
  return <String>{
    if (booksRoot.existsSync())
      for (final Directory dir
          in booksRoot.listSync(followLinks: false).whereType<Directory>())
        if (p.basename(dir.path).startsWith(EpubStorage.kStagingDirPrefix))
          dir.path,
    for (final Directory dir
        in Directory.systemTemp
            .listSync(followLinks: false)
            .whereType<Directory>())
      if (p.basename(dir.path).startsWith('fushi_manga_archive_')) dir.path,
  };
}

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

/// [_buildZip] 的一个条目：[name] 是**原始字节**（可以不是 UTF-8，此时不置通用位
/// 11），[data] 是解压后的内容。[utf8Flag] 给了就按它置 / 不置通用位 11（macOS「压缩」
/// 写 UTF-8 名字却不置标志），否则名字是合法 UTF-8 才置。
class _ZipSpec {
  _ZipSpec(this.name, this.data, {this.deflate = false, this.utf8Flag});

  final List<int> name;
  final Uint8List data;
  final bool deflate;
  final bool? utf8Flag;
}

/// 按真实压缩工具的记录形状拼 zip。
///
/// - 名字是合法 UTF-8 才置通用位 11（与 Info-ZIP / 7-Zip 一致），否则按原字节写；
/// - [zip64]：每个条目带数据描述符（通用位 3、8 字节大小）、本地头与中央目录的
///   大小 / 偏移写 0xFFFFFFFF 并把真值放进 ZIP64 extra，末尾写 ZIP64 EOCD + 定位器，
///   普通 EOCD 的字段全部打满——超过 4 GiB 的包就是这个形状。
Uint8List _buildZip(List<_ZipSpec> entries, {bool zip64 = false}) {
  final BytesBuilder out = BytesBuilder(copy: false);
  Uint8List u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  Uint8List u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  Uint8List u64(int v) =>
      (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();
  bool isUtf8(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  final List<({int offset, int crc, int flags, Uint8List stored})> written =
      <({int offset, int crc, int flags, Uint8List stored})>[];
  for (final _ZipSpec entry in entries) {
    final Uint8List stored = entry.deflate ? _deflate(entry.data) : entry.data;
    final int crc = getCrc32(entry.data);
    final int flags =
        ((entry.utf8Flag ?? isUtf8(entry.name)) ? 0x0800 : 0) |
        (zip64 ? 0x08 : 0);
    written.add((offset: out.length, crc: crc, flags: flags, stored: stored));
    out
      ..add(u32(0x04034b50))
      ..add(u16(zip64 ? 45 : 20))
      ..add(u16(flags))
      ..add(u16(entry.deflate ? 8 : 0))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(zip64 ? 0 : crc))
      ..add(u32(zip64 ? 0xFFFFFFFF : stored.length))
      ..add(u32(zip64 ? 0xFFFFFFFF : entry.data.length))
      ..add(u16(entry.name.length))
      ..add(u16(zip64 ? 20 : 0))
      ..add(entry.name);
    if (zip64) {
      out
        ..add(u16(0x0001))
        ..add(u16(16))
        ..add(u64(entry.data.length))
        ..add(u64(stored.length));
    }
    out.add(stored);
    if (zip64) {
      out
        ..add(u32(0x08074b50))
        ..add(u32(crc))
        ..add(u64(stored.length))
        ..add(u64(entry.data.length));
    }
  }

  final int directoryOffset = out.length;
  for (int i = 0; i < entries.length; i++) {
    final _ZipSpec entry = entries[i];
    final ({int offset, int crc, int flags, Uint8List stored}) w = written[i];
    out
      ..add(u32(0x02014b50))
      ..add(u16(zip64 ? 45 : 20))
      ..add(u16(zip64 ? 45 : 20))
      ..add(u16(w.flags))
      ..add(u16(entry.deflate ? 8 : 0))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(w.crc))
      ..add(u32(zip64 ? 0xFFFFFFFF : w.stored.length))
      ..add(u32(zip64 ? 0xFFFFFFFF : entry.data.length))
      ..add(u16(entry.name.length))
      ..add(u16(zip64 ? 28 : 0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u32(0))
      ..add(u32(zip64 ? 0xFFFFFFFF : w.offset))
      ..add(entry.name);
    if (zip64) {
      out
        ..add(u16(0x0001))
        ..add(u16(24))
        ..add(u64(entry.data.length))
        ..add(u64(w.stored.length))
        ..add(u64(w.offset));
    }
  }
  final int directorySize = out.length - directoryOffset;
  if (zip64) {
    final int zip64EocdOffset = out.length;
    out
      ..add(u32(0x06064b50))
      ..add(u64(44))
      ..add(u16(45))
      ..add(u16(45))
      ..add(u32(0))
      ..add(u32(0))
      ..add(u64(entries.length))
      ..add(u64(entries.length))
      ..add(u64(directorySize))
      ..add(u64(directoryOffset))
      ..add(u32(0x07064b50))
      ..add(u32(0))
      ..add(u64(zip64EocdOffset))
      ..add(u32(1));
  }
  out
    ..add(u32(0x06054b50))
    ..add(u16(0))
    ..add(u16(0))
    ..add(u16(zip64 ? 0xFFFF : entries.length))
    ..add(u16(zip64 ? 0xFFFF : entries.length))
    ..add(u32(zip64 ? 0xFFFFFFFF : directorySize))
    ..add(u32(zip64 ? 0xFFFFFFFF : directoryOffset))
    ..add(u16(0));
  return out.takeBytes();
}

/// 依次作答的口令来源（null = 取消）；答对的都勾「记住」。
final class _AnswerPasswords implements ArchivePasswordProvider {
  _AnswerPasswords(this.answers);

  final List<String?> answers;
  final List<bool> previousWrong = <bool>[];
  final List<String> rememberedPasswords = <String>[];

  @override
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request) async {
    previousWrong.add(request.previousWrong);
    final String? answer = answers.isEmpty ? null : answers.removeAt(0);
    return answer == null
        ? null
        : ArchivePasswordAnswer(answer, remember: true);
  }

  @override
  Future<void> forget(String fingerprint) async {}

  @override
  Future<void> remember(String fingerprint, String password) async =>
      rememberedPasswords.add(password);

  @override
  Future<String?> remembered(String fingerprint) async => null;
}
