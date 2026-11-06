import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart'
    show DuplicatePolicy;
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show MangaImporter;
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart'
    show BookSourceIndex;
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端库扫描的 manga 根：`.mokuro` 卷 + 纯页图目录经引擎 `MangaImporter`
/// 落 `epub_books(format=manga)`，产物落在 `ServerPaths.documents/fushi_books/`。

/// 最小合法 PNG（签名 + IHDR + IEND，CRC 正确）：导入器只读文件头取宽高
/// （`probeOrientedImageSize` 走 PNG 解码器的 `startDecode`，IHDR 的 CRC 会被校验），
/// 不解码像素，所以不需要 IDAT。
Uint8List _minimalPng({int width = 20, int height = 40}) {
  final BytesBuilder out = BytesBuilder();
  out.add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final List<int> typeBytes = ascii.encode(type);
    out.add(_be32(data.length));
    out.add(typeBytes);
    out.add(data);
    out.add(_be32(_crc32(<int>[...typeBytes, ...data])));
  }

  chunk('IHDR', <int>[..._be32(width), ..._be32(height), 8, 2, 0, 0, 0]);
  chunk('IEND', const <int>[]);
  return out.toBytes();
}

List<int> _be32(int v) => <int>[
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

int _crc32(List<int> bytes) {
  int crc = 0xFFFFFFFF;
  for (final int b in bytes) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

void _writePage(String dir, String name) {
  Directory(dir).createSync(recursive: true);
  File(p.join(dir, name)).writeAsBytesSync(_minimalPng());
}

/// 在 [dir] 写出一份最小合法 mokuro 卷（`.mokuro` + `images/` 页图），返回
/// `.mokuro` 路径。[withImage] 为 false 时故意缺页图（用于「单卷失败不中断整批」）。
String _writeMokuro(
  String dir, {
  required String title,
  bool withImage = true,
}) {
  Directory(dir).createSync(recursive: true);
  if (withImage) {
    File(p.join(dir, 'images', 'p001.jpg'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
  }
  final Map<String, Object?> payload = <String, Object?>{
    'version': '0.2.0',
    'title': title,
    'pages': <Object?>[
      <String, Object?>{
        'img_width': 800,
        'img_height': 1200,
        'img_path': 'images/p001.jpg',
        'blocks': <Object?>[],
      },
    ],
  };
  final String mokuroPath = p.join(dir, '$title.mokuro');
  File(mokuroPath).writeAsStringSync(jsonEncode(payload));
  return mokuroPath;
}

void main() {
  late Directory tmp;
  late Directory libraryRoot;
  late FushiDatabase db;
  late LibraryScanner scanner;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_manga_');
    libraryRoot = Directory(p.join(tmp.path, 'library'))..createSync();
    final ServerPaths paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
    enginePaths = paths;
    // EpubStorage 进程级缓存了书目录根：换 data_dir 后必须清掉，否则第二个
    // 测试的产物落进上一个已删除的临时目录。
    EpubStorage.debugBaseDirectoryOverride = null;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    scanner = LibraryScanner(
      db: db,
      subtitleLanguage: 'ja',
      extractCovers: false,
    );
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<ScanSummary> scan() => scanner.scanAll(<LibraryRootConfig>[
    LibraryRootConfig(id: 'm', path: libraryRoot.path, kind: 'manga'),
  ]);

  Future<void> expectMangaArtifacts(EpubBookRow book) async {
    expect(book.format, 'manga');
    expect(
      File(
        p.join(book.extractDir, MangaStorage.kMangaJsonFileName),
      ).existsSync(),
      isTrue,
      reason: 'host 列漫画要求 extractDir/manga.json 存在',
    );
    expect(book.coverPath, startsWith('images/'));
    expect(File(p.join(book.extractDir, book.coverPath!)).existsSync(), isTrue);
    expect(
      p.isWithin(
        p.join(tmp.path, 'data', 'documents', 'fushi_books'),
        book.extractDir,
      ),
      isTrue,
      reason: '产物必须落在 ServerPaths.documents/fushi_books 下',
    );
  }

  test('根目录直接有页图 → 根本身一卷（标题 = 目录名）', () async {
    _writePage(libraryRoot.path, '001.png');
    _writePage(p.join(libraryRoot.path, 'chapter'), '002.png');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 1);
    expect(summary.mangaSkipped, 0);
    expect(summary.toString(), contains('manga +1 (skipped 0)'));
    final EpubBookRow book = (await db.getAllEpubBooks()).single;
    expect(book.title, 'library');
    expect(book.chapterCount, 2);
    await expectMangaArtifacts(book);
  });

  test('BUG-3441 扫描入库后分卷按系列持久归组（无头服务端没有书架页，不在这里归 '
      '互联 client 永远拿不到系列归属）', () async {
    _writePage(p.join(libraryRoot.path, '志乃と恋 1'), '001.png');
    _writePage(p.join(libraryRoot.path, '志乃と恋 2'), '001.png');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    final MediaCollectionRow series = (await db.getAllMediaCollections())
        .singleWhere((MediaCollectionRow c) => c.name == '志乃と恋');
    expect(series.collectionType, 'playlist');
    final Map<String, String> titleByUid = <String, String>{
      for (final EpubBookRow b in await db.getAllEpubBooks()) b.uid: b.title,
    };
    expect(
      <String?>[
        for (final MediaCollectionItemRow i in await db.getCollectionItems(
          series.id,
        ))
          titleByUid[i.entryKey],
      ],
      <String>['志乃と恋 1', '志乃と恋 2'],
    );
  });

  test('系列目录：每个含页图的直接子目录一卷', () async {
    _writePage(p.join(libraryRoot.path, 'volume-01'), '001.png');
    _writePage(p.join(libraryRoot.path, 'volume-01', 'ch2'), '002.png');
    _writePage(p.join(libraryRoot.path, 'volume-02'), '001.png');
    File(p.join(libraryRoot.path, 'readme.txt')).writeAsStringSync('x');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 2);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title).toList()..sort(), <String>[
      'volume-01',
      'volume-02',
    ]);
    for (final EpubBookRow book in books) {
      await expectMangaArtifacts(book);
    }
  });

  // 反馈 n4KC1azJvw（manga-series-volume-folders-flattened）：与 app 来源扫描同一份
  // 归组 + 回收逻辑。
  test('库根/系列/Vol01..03 → 3 卷「系列名 卷名」，同在系列合集', () async {
    for (final String v in <String>['Vol01', 'Vol02', 'Vol03']) {
      _writePage(p.join(libraryRoot.path, 'ONE PIECE', v), '001.png');
    }

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 3);
    final Map<String, String> titleByUid = <String, String>{
      for (final EpubBookRow b in await db.getAllEpubBooks()) b.uid: b.title,
    };
    expect(titleByUid.values.toList()..sort(), <String>[
      'ONE PIECE Vol01',
      'ONE PIECE Vol02',
      'ONE PIECE Vol03',
    ]);
    final MediaCollectionRow series =
        (await db.getAllMediaCollections()).single;
    expect(series.name, 'ONE PIECE');
    expect(
      <String?>[
        for (final MediaCollectionItemRow i in await db.getCollectionItems(
          series.id,
        ))
          titleByUid[i.entryKey],
      ],
      <String>['ONE PIECE Vol01', 'ONE PIECE Vol02', 'ONE PIECE Vol03'],
    );
  });

  test('旧版整本导入的合订本：重扫被分卷取代、计入 mangaPruned，不留重复', () async {
    for (final String v in <String>['Vol01', 'Vol02']) {
      _writePage(p.join(libraryRoot.path, 'ONE PIECE', v), '001.png');
    }
    // 先扫一次拿到来源行，再把库还原成旧规则的落库结果：整个系列目录一本、标题 =
    // 系列目录名、索引只登记 `ONE PIECE` → 这本书。
    await scan();
    final int sourceId = (await db.getAllEpubBooks()).first.sourceId!;
    for (final EpubBookRow b in await db.getAllEpubBooks()) {
      await db.deleteEpubBook(b.bookKey);
    }
    final String oldKey = await MangaImporter.importFromImageFolder(
      db: db,
      imageDirPath: p.join(libraryRoot.path, 'ONE PIECE'),
      title: 'ONE PIECE',
      sourceId: sourceId,
      policy: const DuplicatePolicy.skip(),
    );
    final BookSourceIndex index = BookSourceIndex.empty(sourceId)
      ..put('ONE PIECE', (await db.getEpubBook(oldKey))!.uid);
    await index.save(db);

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 2);
    expect(summary.mangaPruned, 1);
    expect(await db.getEpubBook(oldKey), isNull);
    expect(
      (await db.getAllEpubBooks()).map((EpubBookRow b) => b.title).toList()
        ..sort(),
      <String>['ONE PIECE Vol01', 'ONE PIECE Vol02'],
    );
  });

  test('.mokuro 卷按 manifest 导入，其页图目录不再重复成裸图卷', () async {
    _writeMokuro(p.join(libraryRoot.path, 'vol-a'), title: 'MokuroVolume');
    _writePage(p.join(libraryRoot.path, 'vol-b'), '001.png');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 2);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title).toList()..sort(), <String>[
      'MokuroVolume',
      'vol-b',
    ]);
    for (final EpubBookRow book in books) {
      await expectMangaArtifacts(book);
    }
  });

  test('重扫幂等：mangaSkipped 增长、书数不变', () async {
    _writeMokuro(p.join(libraryRoot.path, 'vol-a'), title: 'Rescan');
    _writePage(p.join(libraryRoot.path, 'vol-b'), '001.png');

    final ScanSummary first = await scan();
    expect(first.mangaAdded, 2);
    expect(first.mangaSkipped, 0);

    final ScanSummary second = await scan();
    expect(second.errors, isEmpty);
    expect(second.mangaAdded, 0);
    expect(second.mangaSkipped, 2);
    expect(await db.getAllEpubBooks(), hasLength(2));
  });

  test('单卷失败只记 errors，不中断整批', () async {
    _writeMokuro(
      p.join(libraryRoot.path, 'broken'),
      title: 'Broken',
      withImage: false,
    );
    _writePage(p.join(libraryRoot.path, 'good'), '001.png');

    final ScanSummary summary = await scan();

    expect(summary.errors, hasLength(1));
    expect(summary.errors.single, contains('Broken.mokuro'));
    expect(summary.mangaAdded, 1);
    expect((await db.getAllEpubBooks()).single.title, 'good');
  });

  void writePagesZip(String path, List<String> entries) {
    final Archive archive = Archive();
    for (final String name in entries) {
      final List<int> png = _minimalPng();
      archive.addFile(ArchiveFile(name, png.length, png));
    }
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  test('单文件卷 .cbz / .zip 逐卷入库（此前服务端漫画根完全不认压缩包）', () async {
    final String series = p.join(libraryRoot.path, 'Veil');
    writePagesZip(p.join(series, 'Veil（1）オレンジの体温.zip'), <String>['001.png']);
    writePagesZip(p.join(series, 'Veil（2）凪いだノワール.cbz'), <String>[
      '001.png',
      '002.png',
    ]);
    // 系列目录里的封面不是一卷。
    _writePage(series, 'cover.jpg');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 2);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title).toSet(), <String>{
      'Veil（1）オレンジの体温',
      'Veil（2）凪いだノワール',
    });
    for (final EpubBookRow book in books) {
      await expectMangaArtifacts(book);
    }

    final ScanSummary second = await scan();
    expect(second.errors, isEmpty);
    expect(second.mangaAdded, 0);
    expect(second.mangaSkipped, 2);
  });

  test('已在来源索引里的 .zip 卷重扫不再开包定性', () async {
    final File zip = File(p.join(libraryRoot.path, 'vol-1.zip'));
    writePagesZip(zip.path, <String>['001.png']);
    expect((await scan()).mangaAdded, 1);

    // 换成打不开的字节：重扫若仍先开包定性，会判「不是漫画」直接跳过，这一卷就不再
    // 被记为在场。
    zip.writeAsBytesSync(<int>[1, 2, 3, 4, 5]);
    final ScanSummary second = await scan();

    expect(second.errors, isEmpty);
    expect(second.mangaSkipped, 1);
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('不同系列目录下同名的 Vol 1.cbz 是两卷：第二卷换名入库，重扫不再导入', () async {
    writePagesZip(p.join(libraryRoot.path, 'SeriesA', 'Vol 1.cbz'), <String>[
      '001.png',
    ]);
    writePagesZip(p.join(libraryRoot.path, 'SeriesB', 'Vol 1.cbz'), <String>[
      '001.png',
      '002.png',
    ]);

    final ScanSummary first = await scan();

    expect(first.errors, isEmpty);
    expect(first.mangaAdded, 2, reason: '此前只按标题判重复，SeriesB 的第 1 卷被静默跳过');
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books, hasLength(2));
    expect(books.map((EpubBookRow b) => b.title), contains('Vol 1'));

    final ScanSummary second = await scan();
    expect(second.errors, isEmpty);
    expect(second.mangaAdded, 0);
    expect(second.mangaSkipped, 2);
    expect(await db.getAllEpubBooks(), hasLength(2));
  });

  test('判过「不是漫画」的 .zip 内容不变就不再开包；内容变了才重判', () async {
    List<int> dictZip() {
      final Archive archive = Archive();
      for (final String name in <String>['index.json', 'term_bank_1.json']) {
        final List<int> bytes = utf8.encode(
          name == 'index.json' ? '{"title":"d"}' : '[]',
        );
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
      return ZipEncoder().encode(archive)!;
    }

    List<int> pagesZip() {
      final Archive archive = Archive();
      final List<int> png = _minimalPng();
      archive.addFile(ArchiveFile('001.png', png.length, png));
      return ZipEncoder().encode(archive)!;
    }

    final File zip = File(p.join(libraryRoot.path, 'vol.zip'));
    final List<int> dict = dictZip();
    final List<int> pages = pagesZip();
    // 末尾补零让两份字节数相同（EOCD 从尾部回扫，尾随填充不影响读包）：换内容后
    // 字节数与修改时刻都还原，指纹不变——这正是「只要指纹不变就不重判」的边界。
    final int size = dict.length > pages.length ? dict.length : pages.length;
    List<int> padded(List<int> bytes) => <int>[
      ...bytes,
      ...List<int>.filled(size - bytes.length, 0),
    ];
    zip.writeAsBytesSync(padded(dict));
    final DateTime mtime = DateTime(2026, 1, 2, 3, 4, 5);
    zip.setLastModifiedSync(mtime);

    final ScanSummary first = await scan();
    expect(first.errors, isEmpty);
    expect(first.mangaAdded, 0);

    // 同字节数、同修改时刻地换成页图包：负向结果命中，不开包，所以不会入库。
    zip.writeAsBytesSync(padded(pages));
    zip.setLastModifiedSync(mtime);
    final ScanSummary second = await scan();
    expect(second.errors, isEmpty);
    expect(second.mangaAdded, 0, reason: '指纹没变就不该再开包重判');

    // 修改时刻一变（文件真被换过）就重判，这次是漫画。
    zip.setLastModifiedSync(mtime.add(const Duration(minutes: 1)));
    final ScanSummary third = await scan();
    expect(third.errors, isEmpty);
    expect(third.mangaAdded, 1);
  });

  test('漫画根里的词典 .zip 不是漫画：跳过、不报错', () async {
    final Archive archive = Archive();
    for (final String name in <String>['index.json', 'term_bank_1.json']) {
      final List<int> bytes = utf8.encode(
        name == 'index.json' ? '{"title":"d"}' : '[]',
      );
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final List<int> png = _minimalPng();
    archive.addFile(ArchiveFile('img/a.png', png.length, png));
    File(
      p.join(libraryRoot.path, 'dict.zip'),
    ).writeAsBytesSync(ZipEncoder().encode(archive)!);

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 0);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('空根：0 卷、无错误', () async {
    final ScanSummary summary = await scan();
    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 0);
    expect(await db.getAllEpubBooks(), isEmpty);
  });
}
