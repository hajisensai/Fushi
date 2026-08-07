import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 在 [dir] 写一份内部 `manga.json`（[parseMangaJson] 格式，= 内置 OCR `ocrFolder`
/// 产出）+ 同级页图，返回 manga.json 路径。
String _writeMangaJson(String dir, {String basename = 'manga'}) {
  Directory(dir).createSync(recursive: true);
  final Directory images = Directory(p.join(dir, 'images'))
    ..createSync(recursive: true);
  File(p.join(images.path, 'p001.png')).writeAsBytesSync(<int>[1, 2, 3]);
  File(p.join(images.path, 'p002.png')).writeAsBytesSync(<int>[4, 5, 6]);
  final Map<String, Object?> payload = <String, Object?>{
    'pages': <Object?>[
      <String, Object?>{
        'url': 'images/p001.png',
        'width': 1200,
        'height': 1700,
        'blocks': <Object?>[
          <String, Object?>{
            'box': <int>[10, 20, 110, 220],
            'vertical': true,
            'font_size': 30,
            'z_index': 0,
            'lines': <String>['一行目'],
          },
        ],
      },
      <String, Object?>{
        'url': 'images/p002.png',
        'width': 1200,
        'height': 1700,
        'blocks': <Object?>[],
      },
    ],
  };
  final String jsonPath = p.join(dir, MangaStorage.kMangaJsonFileName);
  File(jsonPath).writeAsStringSync(jsonEncode(payload));
  return jsonPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDocDir;
  late Directory srcRoot;
  late FushiDatabase db;

  setUp(() async {
    appDocDir = await Directory.systemTemp.createTemp('manga_json_app');
    srcRoot = await Directory.systemTemp.createTemp('manga_json_src');
    EpubStorage.debugBaseDirectoryOverride = appDocDir.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[appDocDir, srcRoot]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  test('importFromMangaJson stages an EpubBooks(manga) row + copies pages',
      () async {
    final String jsonPath =
        _writeMangaJson(p.join(srcRoot.path, 'vol'), basename: 'vol');

    final String bookKey = await MangaImporter.importFromMangaJson(
      db: db,
      mangaJsonPath: jsonPath,
      title: 'OCR Volume',
    );

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull);
    expect(row!.format, 'manga');
    expect(row.title, 'OCR Volume');
    expect(row.chapterCount, 2);
    expect(row.epubPath, 'manga.json');
    expect(row.coverPath, 'images/p001.png');
    expect(File(p.join(row.extractDir, 'manga.json')).existsSync(), isTrue);
    expect(File(p.join(row.extractDir, 'images', 'p001.png')).existsSync(),
        isTrue);
    expect(File(p.join(row.extractDir, 'images', 'p002.png')).existsSync(),
        isTrue);
  });

  test('title falls back to folder name when none provided', () async {
    final String jsonPath = _writeMangaJson(p.join(srcRoot.path, 'MyVolume'));
    final String bookKey = await MangaImporter.importFromMangaJson(
        db: db, mangaJsonPath: jsonPath);
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row!.title, 'MyVolume');
  });

  // 漫画 P3 修正：OCR 引擎（内置 ocrFolder / 远程代跑）把 manga.json 落在被扫描
  // 目录的 manga_ocr_out/ 子目录里，而页 url 相对**被扫描目录**——导入必须显式传
  // imageRootPath 才能解析到页图（旧默认「json 同级目录」对该布局必然缺图）。
  test('imageRootPath resolves pages relative to the volume root (OCR layout)',
      () async {
    final String volRoot = p.join(srcRoot.path, 'ocr_vol');
    final Directory images = Directory(p.join(volRoot, 'images'))
      ..createSync(recursive: true);
    File(p.join(images.path, 'p001.png')).writeAsBytesSync(<int>[1, 2, 3]);
    final Directory outDir = Directory(p.join(volRoot, 'manga_ocr_out'))
      ..createSync(recursive: true);
    final String jsonPath = p.join(outDir.path, 'manga.json');
    File(jsonPath).writeAsStringSync(jsonEncode(<String, Object?>{
      'pages': <Object?>[
        <String, Object?>{
          'url': 'images/p001.png',
          'width': 100,
          'height': 200,
          'blocks': <Object?>[],
        },
      ],
    }));

    // 不带 imageRootPath（旧默认 = json 同级 manga_ocr_out/）：页图必缺，导入拒绝。
    await expectLater(
      MangaImporter.importFromMangaJson(
        db: db,
        mangaJsonPath: jsonPath,
        title: 'Broken Layout',
      ),
      throwsA(isA<MangaImportException>()),
    );

    // 显式指向被扫描目录：导入成功、页图拷贝到位。
    final String bookKey = await MangaImporter.importFromMangaJson(
      db: db,
      mangaJsonPath: jsonPath,
      imageRootPath: volRoot,
      title: 'OCR Layout',
    );
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull);
    expect(row!.format, 'manga');
    expect(File(p.join(row.extractDir, 'images', 'p001.png')).existsSync(),
        isTrue);
  });

  test('throws when manga.json is missing', () async {
    await expectLater(
      MangaImporter.importFromMangaJson(
        db: db,
        mangaJsonPath: p.join(srcRoot.path, 'nope', 'manga.json'),
      ),
      throwsA(isA<MangaImportException>()),
    );
  });
}
