import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/manga/manga_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('manga_storage_test');
    EpubStorage.debugBaseDirectoryOverride = tempDir.path;
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('bookDirectory / bookPath (reuse hoshi_books root, PDF 同惯例)', () {
    test('bookDirectory is <base>/hoshi_books/<bookKey> and is created',
        () async {
      final String path = await MangaStorage.bookPath('vol1');
      expect(Directory(path).existsSync(), isFalse,
          reason: 'bookPath must not create the directory');

      final String dir = await MangaStorage.bookDirectory('vol1');
      expect(Directory(dir).existsSync(), isTrue);
      expect(p.basename(dir), 'vol1');
      expect(p.basename(p.dirname(dir)), 'hoshi_books');
      expect(dir, path);
    });

    test('deleteBookDir removes the directory', () async {
      final String dir = await MangaStorage.bookDirectory('vol2');
      File(p.join(dir, 'manga.json')).writeAsStringSync('{}');
      expect(Directory(dir).existsSync(), isTrue);

      await MangaStorage.deleteBookDir(dir);
      expect(Directory(dir).existsSync(), isFalse);
    });
  });

  group('sanitizeRelSegments', () {
    test('preserves sub-directory structure', () {
      expect(MangaStorage.sanitizeRelSegments('vol1/p001.jpg'),
          <String>['vol1', 'p001.jpg']);
    });

    test('strips a single leading images/ segment (avoid images/images)', () {
      expect(MangaStorage.sanitizeRelSegments('images/p001.jpg'),
          <String>['p001.jpg']);
      // Only the FIRST images/ is stripped; nested images/ kept.
      expect(MangaStorage.sanitizeRelSegments('images/images/p001.jpg'),
          <String>['images', 'p001.jpg']);
    });

    test('normalises backslashes and drops "." segments', () {
      expect(MangaStorage.sanitizeRelSegments(r'vol1\.\p001.jpg'),
          <String>['vol1', 'p001.jpg']);
    });

    test('rejects path traversal ("..") with MangaImportException', () {
      expect(() => MangaStorage.sanitizeRelSegments('../secret.jpg'),
          throwsA(isA<MangaImportException>()));
      expect(() => MangaStorage.sanitizeRelSegments('vol1/../../etc/passwd'),
          throwsA(isA<MangaImportException>()));
    });

    test('replaces illegal characters per segment, keeps structure', () {
      expect(MangaStorage.sanitizeRelSegments('vol1/p:00?1.jpg'),
          <String>['vol1', 'p_00_1.jpg']);
    });
  });

  group('uniqueDestRel', () {
    test('non-colliding paths keep their forward-slash images/ path', () {
      final Set<String> used = <String>{};
      expect(MangaStorage.uniqueDestRel(<String>['vol1', 'p001.jpg'], used),
          'images/vol1/p001.jpg');
    });

    test('colliding basenames get numeric suffix, never alias', () {
      final Set<String> used = <String>{};
      final String a = MangaStorage.uniqueDestRel(<String>['a.jpg'], used);
      final String b = MangaStorage.uniqueDestRel(<String>['a.jpg'], used);
      expect(a, 'images/a.jpg');
      expect(b, 'images/a (2).jpg');
      expect(a, isNot(b));
    });

    test('collision suffix only affects the basename, keeps sub-dir', () {
      final Set<String> used = <String>{};
      MangaStorage.uniqueDestRel(<String>['vol1', 'p.jpg'], used);
      final String b =
          MangaStorage.uniqueDestRel(<String>['vol1', 'p.jpg'], used);
      expect(b, 'images/vol1/p (2).jpg');
    });
  });
}
