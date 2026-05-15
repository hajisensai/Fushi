import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/epub/book_css_repository.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('book_css_repo_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('discoverCssFiles', () {
    test('returns empty list when extractDir does not exist', () {
      final repo = BookCssRepository(p.join(tmpDir.path, 'nonexistent'));
      expect(repo.discoverCssFiles(), isEmpty);
    });

    test('discovers CSS files recursively', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'body{}');
      _createFile(tmpDir, 'OEBPS/Styles/fonts.css', '@font-face{}');
      _createFile(tmpDir, 'OEBPS/Text/chapter1.xhtml', '<html/>');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 2);
      expect(
        files.map((f) => f.relativePath).toList(),
        ['OEBPS/Styles/fonts.css', 'OEBPS/Styles/style.css'],
      );
    });

    test('excludes .original backup files', () {
      _createFile(tmpDir, 'OEBPS/style.css', 'body{}');
      _createFile(tmpDir, 'OEBPS/style.css.original', 'old{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 1);
      expect(files.first.relativePath, 'OEBPS/style.css');
    });

    test('matches CSS extension case-insensitively', () {
      _createFile(tmpDir, 'OEBPS/STYLE.CSS', 'body{}');
      _createFile(tmpDir, 'OEBPS/Mixed.Css', 'body{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 2);
    });

    test('relativePaths use forward slashes', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'body{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.first.relativePath, 'OEBPS/Styles/style.css');
      expect(files.first.relativePath.contains(r'\'), isFalse);
    });

    test('results are sorted by relativePath', () {
      _createFile(tmpDir, 'z/z.css', 'z');
      _createFile(tmpDir, 'a/a.css', 'a');
      _createFile(tmpDir, 'm/m.css', 'm');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.map((f) => f.relativePath).toList(), ['a/a.css', 'm/m.css', 'z/z.css']);
    });
  });

  group('displayTitle shortest unique suffix', () {
    test('unique basenames use basename only', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'a');
      _createFile(tmpDir, 'OEBPS/Styles/fonts.css', 'b');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.map((f) => f.displayTitle).toSet(), {'fonts.css', 'style.css'});
    });

    test('duplicate basenames get parent prefix', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'a');
      _createFile(tmpDir, 'OEBPS/Alt/style.css', 'b');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      final titles = files.map((f) => f.displayTitle).toSet();
      expect(titles, {'Styles/style.css', 'Alt/style.css'});
    });

    test('triple collision adds enough prefix', () {
      _createFile(tmpDir, 'a/common/style.css', '1');
      _createFile(tmpDir, 'b/common/style.css', '2');
      _createFile(tmpDir, 'c/other/style.css', '3');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      final titles = files.map((f) => f.displayTitle).toSet();
      expect(titles.length, 3);
      for (final t in titles) {
        expect(t.endsWith('style.css'), isTrue);
      }
    });
  });
}

void _createFile(Directory root, String relativePath, String content) {
  final File file = File(p.join(root.path, relativePath.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
