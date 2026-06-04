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

      expect(files.map((f) => f.relativePath).toList(),
          ['a/a.css', 'm/m.css', 'z/z.css']);
    });
  });

  group('loadSnapshots (BUG-040: off-UI-thread discover + read)', () {
    test('returns one snapshot per CSS file with disk content', () async {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'body{color:red}');
      _createFile(tmpDir, 'OEBPS/Styles/fonts.css', '@font-face{}');
      _createFile(tmpDir, 'OEBPS/Text/chapter1.xhtml', '<html/>');

      final repo = BookCssRepository(tmpDir.path);
      final snapshots = await repo.loadSnapshots();

      // Same discovery contract as discoverCssFiles (sorted, xhtml excluded),
      // but each entry already carries its on-disk content.
      expect(snapshots.map((s) => s.entry.relativePath).toList(),
          ['OEBPS/Styles/fonts.css', 'OEBPS/Styles/style.css']);
      expect(snapshots[0].content, '@font-face{}');
      expect(snapshots[1].content, 'body{color:red}');
    });

    test('returns empty list when extractDir does not exist', () async {
      final repo = BookCssRepository(p.join(tmpDir.path, 'nonexistent'));
      expect(await repo.loadSnapshots(), isEmpty);
    });
  });

  group('displayTitle shortest unique suffix', () {
    test('unique basenames use basename only', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'a');
      _createFile(tmpDir, 'OEBPS/Styles/fonts.css', 'b');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(
          files.map((f) => f.displayTitle).toSet(), {'fonts.css', 'style.css'});
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

  group('readCss', () {
    test('reads file content as UTF-8', () {
      _createFile(tmpDir, 'style.css', 'body { color: red; }');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(repo.readCssSync(entry), 'body { color: red; }');
    });
  });

  group('saveCss', () {
    test('first save creates .original backup', () {
      _createFile(tmpDir, 'style.css', 'original content');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'modified content');

      expect(File(entry.originalPath).existsSync(), isTrue);
      expect(File(entry.originalPath).readAsStringSync(), 'original content');
      expect(File(entry.absolutePath).readAsStringSync(), 'modified content');
    });

    test('saving same content as disk is a no-op (no .original created)', () {
      _createFile(tmpDir, 'style.css', 'same');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'same');

      expect(File(entry.originalPath).existsSync(), isFalse);
    });

    test('saving back to original content deletes .original', () {
      _createFile(tmpDir, 'style.css', 'original');
      final repo = BookCssRepository(tmpDir.path);
      var entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'changed');
      expect(entry.hasOriginal, isTrue);

      entry = repo.discoverCssFiles().first; // refresh
      repo.saveCss(entry, 'original');
      expect(File(entry.originalPath).existsSync(), isFalse);
      expect(File(entry.absolutePath).readAsStringSync(), 'original');
    });

    test('second save does not overwrite .original', () {
      _createFile(tmpDir, 'style.css', 'v1');
      final repo = BookCssRepository(tmpDir.path);
      var entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'v2');
      entry = repo.discoverCssFiles().first;
      repo.saveCss(entry, 'v3');

      expect(File(entry.originalPath).readAsStringSync(), 'v1');
      expect(File(entry.absolutePath).readAsStringSync(), 'v3');
    });
  });

  group('isDifferentFromOriginal', () {
    test('returns false when no .original exists', () {
      _createFile(tmpDir, 'style.css', 'body{}');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isFalse);
    });

    test('returns true when content differs from .original', () {
      _createFile(tmpDir, 'style.css', 'modified');
      _createFile(tmpDir, 'style.css.original', 'original');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isTrue);
    });

    test('returns false when content matches .original', () {
      _createFile(tmpDir, 'style.css', 'same');
      _createFile(tmpDir, 'style.css.original', 'same');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isFalse);
    });
  });

  group('resetFile', () {
    test('restores content from .original and deletes backup', () {
      _createFile(tmpDir, 'style.css', 'modified');
      _createFile(tmpDir, 'style.css.original', 'original');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.resetFile(entry);

      expect(File(entry.absolutePath).readAsStringSync(), 'original');
      expect(File(entry.originalPath).existsSync(), isFalse);
    });

    test('no-op when no .original exists', () {
      _createFile(tmpDir, 'style.css', 'content');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.resetFile(entry); // should not throw

      expect(File(entry.absolutePath).readAsStringSync(), 'content');
    });
  });

  group('resetAll', () {
    test('resets all files that have .original backups', () {
      _createFile(tmpDir, 'a.css', 'modified-a');
      _createFile(tmpDir, 'a.css.original', 'original-a');
      _createFile(tmpDir, 'b.css', 'untouched-b');
      _createFile(tmpDir, 'c.css', 'modified-c');
      _createFile(tmpDir, 'c.css.original', 'original-c');

      final repo = BookCssRepository(tmpDir.path);
      repo.resetAll();

      expect(
          File(p.join(tmpDir.path, 'a.css')).readAsStringSync(), 'original-a');
      expect(
          File(p.join(tmpDir.path, 'b.css')).readAsStringSync(), 'untouched-b');
      expect(
          File(p.join(tmpDir.path, 'c.css')).readAsStringSync(), 'original-c');
      expect(File(p.join(tmpDir.path, 'a.css.original')).existsSync(), isFalse);
      expect(File(p.join(tmpDir.path, 'c.css.original')).existsSync(), isFalse);
    });
  });
}

void _createFile(Directory root, String relativePath, String content) {
  final File file =
      File(p.join(root.path, relativePath.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
