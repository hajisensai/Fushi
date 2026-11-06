/// 「从 app 外用 Fushi 打开书 / 漫画」（文件关联 / argv / 单实例转交）的契约。
///
/// 用户诉求：「fushi 支援一下 epub 等打开方式」。原生层（Windows WM_COPYDATA /
/// Linux D-Bus）本来就把任意候选路径交给 Dart，只是 Dart 侧只认视频、其余静默丢掉；
/// 安装包也只登记了视频关联。这里钉住三件事：白名单的形状、安装包登记的扩展名与
/// 白名单逐一对应、同一本书再次外部打开复用已在库那一本（不在书架上多出 `X (2)`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/external_book.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/ctl_library_import.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/video/external_video.dart';
import 'package:path/path.dart' as p;

void main() {
  group('isSupportedExternalBookFile / firstExternalBookArg', () {
    test('书与漫画的分发格式都认，大小写不敏感', () {
      for (final String path in <String>[
        r'C:\b\a.epub',
        r'C:\b\a.EPUB',
        '/b/a.pdf',
        '/b/a.txt',
        '/b/vol1.cbz',
        '/b/vol1.cbr',
        '/b/vol1.cb7',
        '/b/vol1.mokuro',
      ]) {
        expect(isSupportedExternalBookFile(path), isTrue, reason: path);
      }
    });

    test('不认词典 zip / json 等「导得进但没人会去打开」的格式', () {
      for (final String path in <String>['/a.zip', '/a.json', '/a.html']) {
        expect(isSupportedExternalBookFile(path), isFalse, reason: path);
      }
    });

    test('与视频白名单互斥：同一个 argv 不会两边都认', () {
      for (final String ext in kExternalBookOpenExtensions) {
        expect(isSupportedVideoFile('/x/a$ext'), isFalse, reason: ext);
      }
    });

    test('跳过 flag，取第一个书路径；没有则 null', () {
      expect(
        firstExternalBookArg(<String>['--debug', '', r'C:\b\a.epub', 'b.pdf']),
        r'C:\b\a.epub',
      );
      expect(firstExternalBookArg(<String>['--x', 'a.mkv']), isNull);
    });
  });

  test('Windows 安装包 bookassoc 登记的扩展名与白名单逐一对应', () {
    final String iss = File(
      p.join('windows', 'installer', 'fushi.iss'),
    ).readAsStringSync();
    final RegExp openWith = RegExp(
      r'Subkey: "Software\\Classes\\(\.[a-z0-9]+)\\OpenWithProgids"; '
      r'ValueType: string; ValueName: "Fushi\.Book".*Tasks: bookassoc',
    );
    final RegExp supported = RegExp(
      r'SupportedTypes"; ValueType: string; ValueName: "(\.[a-z0-9]+)"; '
      r'ValueData: ""; Tasks: bookassoc',
    );
    final Set<String> openWithExts = openWith
        .allMatches(iss)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
    final Set<String> supportedExts = supported
        .allMatches(iss)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
    expect(
      openWithExts,
      kExternalBookOpenExtensions,
      reason: '登记了 Dart 不认的扩展名 = 「打开方式」里点了没反应；反之用户找不到入口',
    );
    expect(supportedExts, kExternalBookOpenExtensions);
    expect(
      iss,
      contains(
        'Applications\\fushi.exe\\shell\\open\\command"; ValueType: '
        'string; ValueData: """{app}\\fushi.exe"" ""%1"""; Flags: '
        'uninsdeletekey; Tasks: videoassoc or bookassoc',
      ),
      reason: '只勾书籍关联时 fushi.exe 也必须出现在「打开方式」应用列表里',
    );
  });

  group('再次外部打开同一本书 → 复用已在库那一本', () {
    late FushiDatabase db;
    late Directory tmp;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tmp = Directory.systemTemp.createTempSync('fushi_external_book_');
      EpubStorage.debugBaseDirectoryOverride = p.join(tmp.path, 'app');
    });

    tearDown(() async {
      await db.close();
      EpubStorage.debugBaseDirectoryOverride = null;
      tmp.deleteSync(recursive: true);
    });

    LibraryCtlImporter importer() => LibraryCtlImporter(
      db: db,
      galgameRepo: GalgameRepository(db),
      isKindEnabled: (LibraryCtlKind _) => true,
      keepDuplicates: false,
    );

    test('第二次 skipped 但带回第一次的 book key，库里仍只有一本', () async {
      final File book = File(p.join(tmp.path, '銀河鉄道の夜.txt'))
        ..writeAsStringSync('ジョバンニは走った。\nカムパネルラもいた。\n');

      final LibraryCtlImportResult first = (await importer().importAll(<String>[
        book.path,
      ])).single;
      expect(
        first.status,
        LibraryCtlImportStatus.imported,
        reason: first.message,
      );

      final LibraryCtlImportResult again = (await importer().importAll(<String>[
        book.path,
      ])).single;
      expect(again.status, LibraryCtlImportStatus.skipped);
      expect(again.keys, first.keys, reason: '外部打开据这个 key 直接打开已在库那本、保留阅读进度');
      expect((await db.getEpubBookMetas()).length, 1);
    });

    // 审查发现：同名 ≠ 同一本（两部作品的 `01.cbz`）。外部打开有人在屏幕前，同名时
    // 必须交给用户裁决，而不是凭标题替用户打开另一本书。
    group('外部打开传 askOnDuplicate：同名交给用户', () {
      late File book;
      late List<String> asked;

      setUp(() {
        book = File(p.join(tmp.path, '01.txt'))..writeAsStringSync('本文。\n');
        asked = <String>[];
      });

      LibraryCtlImporter asking(DuplicateChoice choice) => LibraryCtlImporter(
        db: db,
        galgameRepo: GalgameRepository(db),
        isKindEnabled: (LibraryCtlKind _) => true,
        keepDuplicates: false,
        askOnDuplicate: (String title) async {
          asked.add(title);
          return choice;
        },
      );

      test('选「打开已有」→ skipped 并带回已在库那本的 key', () async {
        final LibraryCtlImportResult first = (await importer().importAll(
          <String>[book.path],
        )).single;
        final LibraryCtlImportResult again = (await asking(
          DuplicateChoice.cancel,
        ).importAll(<String>[book.path])).single;
        expect(asked, <String>['01']);
        expect(again.status, LibraryCtlImportStatus.skipped);
        expect(again.keys, first.keys);
        expect((await db.getEpubBookMetas()).length, 1);
      });

      test('选「作为新书导入」→ 落一本带序号后缀的新书，key 与旧的不同', () async {
        final LibraryCtlImportResult first = (await importer().importAll(
          <String>[book.path],
        )).single;
        final LibraryCtlImportResult again = (await asking(
          DuplicateChoice.suffix,
        ).importAll(<String>[book.path])).single;
        expect(
          again.status,
          LibraryCtlImportStatus.imported,
          reason: again.message,
        );
        expect(again.keys, isNot(first.keys));
        expect((await db.getEpubBookMetas()).length, 2);
      });

      test('库里没有同名书时不打扰用户', () async {
        await asking(DuplicateChoice.cancel).importAll(<String>[book.path]);
        expect(asked, isEmpty);
      });
    });

    test('existingBookKeyForTitle：库里没有同名书 → null', () async {
      expect(await existingBookKeyForTitle(db, '存在しない'), isNull);
    });
  });

  group('显式 --kind book 的图片型 EPUB 按书导入', () {
    late FushiDatabase db;
    late Directory tmp;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tmp = Directory.systemTemp.createTempSync('fushi_ctl_force_book_');
      EpubStorage.debugBaseDirectoryOverride = p.join(tmp.path, 'app');
    });

    tearDown(() async {
      await db.close();
      EpubStorage.debugBaseDirectoryOverride = null;
      tmp.deleteSync(recursive: true);
    });

    test('漫画判据命中也落成一本书，不被静默改成漫画', () async {
      final File epub = File(p.join(tmp.path, 'picture_book.epub'))
        ..writeAsBytesSync(_imageOnlyEpubBytes());
      expect(
        MangaModule.isImageArchive(epub.path),
        isTrue,
        reason: '前提：这份 EPUB 确实会被判成漫画，否则本用例是空壳',
      );

      final LibraryCtlImportResult result = (await LibraryCtlImporter(
        db: db,
        galgameRepo: GalgameRepository(db),
        isKindEnabled: (LibraryCtlKind _) => true,
        keepDuplicates: false,
      ).importAll(<String>[epub.path], kind: LibraryCtlKind.book)).single;

      expect(
        result.status,
        LibraryCtlImportStatus.imported,
        reason: result.message,
      );
      expect(result.kind, LibraryCtlKind.book);
      expect((await db.getEpubBookMetas()).length, 1);
    });
  });
}

/// 一份只有插图、没有正文的合法 EPUB（漫画判据会命中它）。
List<int> _imageOnlyEpubBytes() {
  final Archive archive = Archive();
  void addText(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0"
    xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
        media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  addText('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
    unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">ctl-force-book</dc:identifier>
    <dc:title>Picture Book</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml"
        media-type="application/xhtml+xml"/>
    <item id="page" href="page.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  addText('OEBPS/chapter.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><img src="page.png" alt=""/></body>
</html>
''');
  final List<int> png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  archive.addFile(ArchiveFile('OEBPS/page.png', png.length, png));
  return ZipEncoder().encode(archive)!;
}
