import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 在 [srcDir] 写出一份合法的 mokuro 样本（含 sibling 图片），返回 .mokuro 路径。
String _writeValidSample(
  String srcDir, {
  required String title,
  String basename = 'vol1',
}) {
  Directory(srcDir).createSync(recursive: true);
  final Directory images = Directory(p.join(srcDir, 'images'))
    ..createSync(recursive: true);
  File(p.join(images.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
  File(p.join(images.path, 'p002.jpg')).writeAsBytesSync(<int>[4, 5, 6]);
  final Map<String, Object?> payload = <String, Object?>{
    'version': '0.2.0',
    'title': title,
    'pages': <Object?>[
      <String, Object?>{
        'img_width': 1200,
        'img_height': 1700,
        'img_path': 'images/p001.jpg',
        'blocks': <Object?>[
          <String, Object?>{
            'box': <int>[10, 20, 110, 220],
            'vertical': true,
            'font_size': 32,
            'lines': <String>['一行目', '二行目'],
          },
        ],
      },
      <String, Object?>{
        'img_width': 1200,
        'img_height': 1700,
        'img_path': 'images/p002.jpg',
        'blocks': <Object?>[],
      },
    ],
  };
  final String mokuroPath = p.join(srcDir, '$basename.mokuro');
  File(mokuroPath).writeAsStringSync(jsonEncode(payload));
  return mokuroPath;
}

Map<String, Object?> _readMangaJson(String extractDir) => jsonDecode(
      File(p.join(extractDir, MangaStorage.kMangaJsonFileName))
          .readAsStringSync(),
    ) as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDocDir;
  late Directory srcRoot;
  late FushiDatabase db;

  setUp(() async {
    appDocDir = await Directory.systemTemp.createTemp('manga_importer_app');
    srcRoot = await Directory.systemTemp.createTemp('manga_importer_src');
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

  test('importFromMokuroPath stages an EpubBooks(manga) row + on-disk dir',
      () async {
    final String mokuro =
        _writeValidSample(p.join(srcRoot.path, 'a'), title: 'vol1');

    final String bookKey =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro);

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull);
    expect(row!.format, 'manga');
    expect(row.title, 'vol1');
    expect(row.chapterCount, 2);
    expect(row.epubPath, 'manga.json');
    expect(row.chaptersJson, '[]');
    // 导入时阅读模式留空 = 跟随阅读器自动判定。
    expect(row.mangaReadingMode, isNull);
    // 封面 = 第一页页图相对路径。
    expect(row.coverPath, 'images/p001.jpg');
    // extractDir 指向真实 bookKey 目录，磁盘上有 images + manga.json。
    expect(p.basename(row.extractDir), bookKey);
    expect(File(p.join(row.extractDir, 'manga.json')).existsSync(), isTrue);
    expect(File(p.join(row.extractDir, 'images', 'p001.jpg')).existsSync(),
        isTrue);
    expect(File(p.join(row.extractDir, 'images', 'p002.jpg')).existsSync(),
        isTrue);
  });

  test(
      'image folder imports immediately readable empty-OCR manga in natural order',
      () async {
    final Directory source = Directory(p.join(srcRoot.path, 'raw'))
      ..createSync(recursive: true);
    for (final String name in <String>['10.png', '2.png', '1.png']) {
      File(p.join(source.path, name)).writeAsBytesSync(
        img.encodePng(img.Image(width: 80, height: 120)),
      );
    }

    final String bookKey = await MangaImporter.importFromImageFolder(
      db: db,
      imageDirPath: source.path,
      title: 'Raw Manga',
    );
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final Map<String, Object?> json = _readMangaJson(row.extractDir);
    final List<Object?> pages = json['pages']! as List<Object?>;
    expect(
      pages.map((Object? page) => (page! as Map)['url']).toList(),
      <String>['images/1.png', 'images/2.png', 'images/10.png'],
    );
    expect(
      pages.every((Object? page) => ((page! as Map)['blocks'] as List).isEmpty),
      isTrue,
    );
    expect(row.format, 'manga');
    expect(row.coverPath, 'images/1.png');
  });

  test('rollback on bad JSON: no orphan row, no orphan dir', () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'bad'))
      ..createSync(recursive: true);
    Directory(p.join(srcDir.path, 'images')).createSync(recursive: true);
    File(p.join(srcDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    final String mokuro = p.join(srcDir.path, 'bad.mokuro');
    File(mokuro).writeAsStringSync('{ this is not json');

    await expectLater(
      MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro),
      throwsA(isA<Object>()),
    );

    expect(await db.getAllEpubBooks(), isEmpty);
    // 无残留书目录。
    final Directory booksRoot =
        Directory(p.join(appDocDir.path, 'fushi_books'));
    final bool hasResidual = booksRoot.existsSync() &&
        booksRoot.listSync().whereType<Directory>().isNotEmpty;
    expect(hasResidual, isFalse,
        reason: 'failed import must not leave any manga directory');
  });

  test('same-basename pages in different subdirs do not alias (ERRATA H2)',
      () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'multivol'))
      ..createSync(recursive: true);
    Directory(p.join(srcDir.path, 'vol1')).createSync(recursive: true);
    Directory(p.join(srcDir.path, 'vol2')).createSync(recursive: true);
    File(p.join(srcDir.path, 'vol1', 'p001.jpg')).writeAsBytesSync(<int>[1, 1]);
    File(p.join(srcDir.path, 'vol2', 'p001.jpg')).writeAsBytesSync(<int>[2, 2]);
    final Map<String, Object?> payload = <String, Object?>{
      'version': '0.2.0',
      'title': 'multivol',
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'vol1/p001.jpg',
          'blocks': <Object?>[],
        },
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'vol2/p001.jpg',
          'blocks': <Object?>[],
        },
      ],
    };
    final String mokuro = p.join(srcDir.path, 'multivol.mokuro');
    File(mokuro).writeAsStringSync(jsonEncode(payload));

    final String bookKey =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;

    final File f1 = File(p.join(row.extractDir, 'images', 'vol1', 'p001.jpg'));
    final File f2 = File(p.join(row.extractDir, 'images', 'vol2', 'p001.jpg'));
    expect(f1.existsSync(), isTrue, reason: 'vol1 页应独立落盘');
    expect(f2.existsSync(), isTrue, reason: 'vol2 页应独立落盘');
    expect(f1.readAsBytesSync(), <int>[1, 1]);
    expect(f2.readAsBytesSync(), <int>[2, 2]);

    final List<Object?> pages =
        _readMangaJson(row.extractDir)['pages'] as List<Object?>;
    final String u0 = (pages[0] as Map<String, Object?>)['url'] as String;
    final String u1 = (pages[1] as Map<String, Object?>)['url'] as String;
    expect(u0, isNot(u1), reason: '两页 url 必须各自独立，不能 alias 到同一图');
    expect(u0.split('/').contains('vol1'), isTrue);
    expect(u1.split('/').contains('vol2'), isTrue);
  });

  test('manga.json urls use forward slashes (portable), never backslashes',
      () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'slashtest'))
      ..createSync(recursive: true);
    Directory(p.join(srcDir.path, 'sub')).createSync(recursive: true);
    File(p.join(srcDir.path, 'sub', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    final Map<String, Object?> payload = <String, Object?>{
      'version': '0.2.0',
      'title': 'slashtest',
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'sub/p001.jpg',
          'blocks': <Object?>[],
        },
      ],
    };
    final String mokuro = p.join(srcDir.path, 'slashtest.mokuro');
    File(mokuro).writeAsStringSync(jsonEncode(payload));

    final String bookKey =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final String u0 = ((_readMangaJson(row.extractDir)['pages']
        as List<Object?>)[0] as Map<String, Object?>)['url'] as String;
    expect(u0, 'images/sub/p001.jpg',
        reason: 'url 必须是正斜杠相对路径，含 images/ 前缀 + 保留子目录');
    expect(u0.contains('\\'), isFalse, reason: 'url 绝不能含反斜杠（不可移植）');
    expect(
        File(p.join(row.extractDir, 'images', 'sub', 'p001.jpg')).existsSync(),
        isTrue);
  });

  test('colliding sanitized paths get unique dest (no alias, ERRATA H2/LOW)',
      () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'collide'))
      ..createSync(recursive: true);
    Directory(p.join(srcDir.path, 'images')).createSync(recursive: true);
    File(p.join(srcDir.path, 'images', 'a.jpg')).writeAsBytesSync(<int>[1, 1]);
    File(p.join(srcDir.path, 'a.jpg')).writeAsBytesSync(<int>[2, 2]);
    final Map<String, Object?> payload = <String, Object?>{
      'version': '0.2.0',
      'title': 'collide',
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'images/a.jpg',
          'blocks': <Object?>[],
        },
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'a.jpg',
          'blocks': <Object?>[],
        },
      ],
    };
    final String mokuro = p.join(srcDir.path, 'collide.mokuro');
    File(mokuro).writeAsStringSync(jsonEncode(payload));

    final String bookKey =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final List<Object?> pages =
        _readMangaJson(row.extractDir)['pages'] as List<Object?>;
    final String u0 = (pages[0] as Map<String, Object?>)['url'] as String;
    final String u1 = (pages[1] as Map<String, Object?>)['url'] as String;
    expect(u0, isNot(u1), reason: 'sanitize 碰撞的两页 url 必须去重不 alias');
    final File f0 = File(p.joinAll(<String>[row.extractDir, ...u0.split('/')]));
    final File f1 = File(p.joinAll(<String>[row.extractDir, ...u1.split('/')]));
    expect(f0.existsSync(), isTrue);
    expect(f1.existsSync(), isTrue);
    expect(f0.readAsBytesSync(), <int>[1, 1]);
    expect(f1.readAsBytesSync(), <int>[2, 2]);
  });

  test('duplicate title gets numeric suffix bookKey, never overwrites',
      () async {
    final String first =
        _writeValidSample(p.join(srcRoot.path, 'one'), title: 'dupe');
    final String second =
        _writeValidSample(p.join(srcRoot.path, 'two'), title: 'dupe');

    final String key1 =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: first);
    final String key2 =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: second);

    expect(key1, isNot(key2));
    final EpubBookRow r1 = (await db.getEpubBook(key1))!;
    final EpubBookRow r2 = (await db.getEpubBook(key2))!;
    expect(r1.title, 'dupe');
    expect(r2.title, 'dupe (2)');
    expect((await db.getAllEpubBooks()).length, 2);
  });

  test('title/volume are combined so each volume gets a unique identity',
      () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'series'))
      ..createSync(recursive: true);
    Directory(p.join(srcDir.path, 'images')).createSync(recursive: true);
    File(p.join(srcDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    final Map<String, Object?> payload = <String, Object?>{
      'version': '0.2.0',
      'title': 'My Series',
      'volume': 'Vol.1',
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'images/p001.jpg',
          'blocks': <Object?>[],
        },
      ],
    };
    final String mokuro = p.join(srcDir.path, 'anything.mokuro');
    File(mokuro).writeAsStringSync(jsonEncode(payload));

    final String bookKey =
        await MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.title, 'My Series Vol.1');
  });

  test('explicit title overrides the mokuro-derived title', () async {
    final String mokuro =
        _writeValidSample(p.join(srcRoot.path, 'x'), title: 'ignored');

    final String bookKey = await MangaImporter.importFromMokuroPath(
      db: db,
      mokuroPath: mokuro,
      title: 'User Chosen Title',
    );
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.title, 'User Chosen Title');
  });

  test('rejects path traversal in img_path (no row, no dir)', () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'evil'))
      ..createSync(recursive: true);
    Directory(p.join(srcDir.path, 'images')).createSync(recursive: true);
    File(p.join(srcDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    final Map<String, Object?> payload = <String, Object?>{
      'version': '0.2.0',
      'title': 'evil',
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': '../../etc/passwd',
          'blocks': <Object?>[],
        },
      ],
    };
    final String mokuro = p.join(srcDir.path, 'evil.mokuro');
    File(mokuro).writeAsStringSync(jsonEncode(payload));

    await expectLater(
      MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro),
      throwsA(isA<MangaImportException>()),
    );
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('missing page image gives a readable error and no partial import',
      () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'missing'))
      ..createSync(recursive: true);
    // images/ dir exists (passes canImport) but the referenced page file does not.
    Directory(p.join(srcDir.path, 'images')).createSync(recursive: true);
    File(p.join(srcDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    final Map<String, Object?> payload = <String, Object?>{
      'version': '0.2.0',
      'title': 'missing',
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'images/p001.jpg',
          'blocks': <Object?>[],
        },
        <String, Object?>{
          'img_width': 1200,
          'img_height': 1700,
          'img_path': 'images/does_not_exist.jpg',
          'blocks': <Object?>[],
        },
      ],
    };
    final String mokuro = p.join(srcDir.path, 'missing.mokuro');
    File(mokuro).writeAsStringSync(jsonEncode(payload));

    await expectLater(
      MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro),
      throwsA(isA<MangaImportException>()),
    );
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('not-a-manga-folder (.mokuro with no sibling images) is rejected',
      () async {
    final Directory srcDir = Directory(p.join(srcRoot.path, 'nofolder'))
      ..createSync(recursive: true);
    final String mokuro = p.join(srcDir.path, 'x.mokuro');
    File(mokuro).writeAsStringSync('{"pages":[]}');

    await expectLater(
      MangaImporter.importFromMokuroPath(db: db, mokuroPath: mokuro),
      throwsA(isA<MangaImportException>()),
    );
  });

  test('user cancelling the duplicate dialog bubbles as cancellation',
      () async {
    final String first =
        _writeValidSample(p.join(srcRoot.path, 'c1'), title: 'same');
    final String second =
        _writeValidSample(p.join(srcRoot.path, 'c2'), title: 'same');

    await MangaImporter.importFromMokuroPath(db: db, mokuroPath: first);

    await expectLater(
      MangaImporter.importFromMokuroPath(
        db: db,
        mokuroPath: second,
        policy: DuplicatePolicy.ask((String _) async => DuplicateChoice.cancel),
      ),
      throwsA(isA<DuplicateImportCancelledException>()),
    );
    // 取消后不落第二本。
    expect((await db.getAllEpubBooks()).length, 1);
  });
}
