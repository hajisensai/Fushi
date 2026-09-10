import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
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

List<int> _be32(int v) =>
    <int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

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
String _writeMokuro(String dir,
    {required String title, bool withImage = true}) {
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
    scanner =
        LibraryScanner(db: db, subtitleLanguage: 'ja', extractCovers: false);
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
      File(p.join(book.extractDir, MangaStorage.kMangaJsonFileName))
          .existsSync(),
      isTrue,
      reason: 'host 列漫画要求 extractDir/manga.json 存在',
    );
    expect(book.coverPath, startsWith('images/'));
    expect(File(p.join(book.extractDir, book.coverPath!)).existsSync(), isTrue);
    expect(
        p.isWithin(p.join(tmp.path, 'data', 'documents', 'fushi_books'),
            book.extractDir),
        isTrue,
        reason: '产物必须落在 ServerPaths.documents/fushi_books 下');
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

  test('系列目录：每个含页图的直接子目录一卷', () async {
    _writePage(p.join(libraryRoot.path, 'volume-01'), '001.png');
    _writePage(p.join(libraryRoot.path, 'volume-01', 'ch2'), '002.png');
    _writePage(p.join(libraryRoot.path, 'volume-02'), '001.png');
    File(p.join(libraryRoot.path, 'readme.txt')).writeAsStringSync('x');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 2);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title).toList()..sort(),
        <String>['volume-01', 'volume-02']);
    for (final EpubBookRow book in books) {
      await expectMangaArtifacts(book);
    }
  });

  test('.mokuro 卷按 manifest 导入，其页图目录不再重复成裸图卷', () async {
    _writeMokuro(p.join(libraryRoot.path, 'vol-a'), title: 'MokuroVolume');
    _writePage(p.join(libraryRoot.path, 'vol-b'), '001.png');

    final ScanSummary summary = await scan();

    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 2);
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title).toList()..sort(),
        <String>['MokuroVolume', 'vol-b']);
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
    _writeMokuro(p.join(libraryRoot.path, 'broken'),
        title: 'Broken', withImage: false);
    _writePage(p.join(libraryRoot.path, 'good'), '001.png');

    final ScanSummary summary = await scan();

    expect(summary.errors, hasLength(1));
    expect(summary.errors.single, contains('Broken.mokuro'));
    expect(summary.mangaAdded, 1);
    expect((await db.getAllEpubBooks()).single.title, 'good');
  });

  test('空根：0 卷、无错误', () async {
    final ScanSummary summary = await scan();
    expect(summary.errors, isEmpty);
    expect(summary.mangaAdded, 0);
    expect(await db.getAllEpubBooks(), isEmpty);
  });
}
