import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/epub/book_css_repository.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('book_css_repo_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('discoverCssFiles (TODO-1234: OPF-manifest discovery, no tree walk)',
      () {
    test('returns empty list when extractDir does not exist', () {
      final repo = BookCssRepository(p.join(tmpDir.path, 'nonexistent'));
      expect(repo.discoverCssFiles(), isEmpty);
    });

    test('discovers CSS files declared in the OPF manifest', () {
      _seedEpub(
        tmpDir,
        {
          'OEBPS/Styles/style.css': 'body{}',
          'OEBPS/Styles/fonts.css': '@font-face{}',
        },
        otherFiles: ['OEBPS/Text/chapter1.xhtml'],
      );

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 2);
      expect(
        files.map((f) => f.relativePath).toList(),
        ['OEBPS/Styles/fonts.css', 'OEBPS/Styles/style.css'],
      );
    });

    test('TODO-1234: ignores undeclared CSS files on disk (no full-tree walk)',
        () {
      // A manga-shaped extract: one declared stylesheet, an undeclared orphan
      // stylesheet, and a heavy pile of images that the old recursive walk had
      // to enumerate. Manifest-driven discovery must return only the declared
      // CSS and never touch the rest of the tree.
      _seedEpub(
        tmpDir,
        {'OEBPS/Styles/book.css': 'body{}'},
        otherFiles: ['OEBPS/Text/ch1.xhtml'],
      );
      _createFile(tmpDir, 'OEBPS/Styles/orphan.css', '.orphan{}');
      for (int i = 0; i < 40; i++) {
        _createFile(tmpDir, 'OEBPS/Images/img$i.jpg', 'binary');
      }

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(
          files.map((f) => f.relativePath).toList(), ['OEBPS/Styles/book.css']);
      expect(files.any((f) => f.relativePath.contains('orphan')), isFalse);
    });

    test('TODO-1234: returns empty (no crash) when OPF/container is missing',
        () {
      // Files on disk but no META-INF/container.xml: an unopenable package
      // degrades to "no CSS files" instead of walking the tree or throwing.
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'body{}');
      final repo = BookCssRepository(tmpDir.path);
      expect(repo.discoverCssFiles(), isEmpty);
    });

    test('TODO-1234: skips manifest CSS items that are absent on disk', () {
      _seedEpub(
        tmpDir,
        {'OEBPS/Styles/present.css': 'body{}'},
      );
      // Declare a second CSS item in the manifest but never write the file.
      _declareExtraManifestItem(tmpDir, 'OEBPS/Styles/ghost.css', 'text/css');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.map((f) => f.relativePath).toList(),
          ['OEBPS/Styles/present.css']);
    });

    test('excludes undeclared .original backup files', () {
      _seedEpub(tmpDir, {'OEBPS/style.css': 'body{}'});
      _createFile(tmpDir, 'OEBPS/style.css.original', 'old{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 1);
      expect(files.first.relativePath, 'OEBPS/style.css');
    });

    test('includes items keyed by text/css media-type regardless of extension',
        () {
      _seedEpub(tmpDir, {
        'OEBPS/STYLE.CSS': 'body{}',
        'OEBPS/Mixed.Css': 'body{}',
      });

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 2);
    });

    test('relativePaths use forward slashes', () {
      _seedEpub(tmpDir, {'OEBPS/Styles/style.css': 'body{}'});

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.first.relativePath, 'OEBPS/Styles/style.css');
      expect(files.first.relativePath.contains(r'\'), isFalse);
    });

    test('results are sorted by relativePath', () {
      _seedEpub(tmpDir, {
        'z/z.css': 'z',
        'a/a.css': 'a',
        'm/m.css': 'm',
      });

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.map((f) => f.relativePath).toList(),
          ['a/a.css', 'm/m.css', 'z/z.css']);
    });
  });

  group(
      'loadSnapshots (BUG-040 off-UI-thread reads, TODO-1234 manifest discovery)',
      () {
    test('returns one snapshot per CSS file with disk content', () async {
      _seedEpub(
        tmpDir,
        {
          'OEBPS/Styles/style.css': 'body{color:red}',
          'OEBPS/Styles/fonts.css': '@font-face{}',
        },
        otherFiles: ['OEBPS/Text/chapter1.xhtml'],
      );

      final repo = BookCssRepository(tmpDir.path);
      final snapshots = await repo.loadSnapshots();

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
      _seedEpub(tmpDir, {
        'OEBPS/Styles/style.css': 'a',
        'OEBPS/Styles/fonts.css': 'b',
      });

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(
          files.map((f) => f.displayTitle).toSet(), {'fonts.css', 'style.css'});
    });

    test('duplicate basenames get parent prefix', () {
      _seedEpub(tmpDir, {
        'OEBPS/Styles/style.css': 'a',
        'OEBPS/Alt/style.css': 'b',
      });

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      final titles = files.map((f) => f.displayTitle).toSet();
      expect(titles, {'Styles/style.css', 'Alt/style.css'});
    });

    test('triple collision adds enough prefix', () {
      _seedEpub(tmpDir, {
        'a/common/style.css': '1',
        'b/common/style.css': '2',
        'c/other/style.css': '3',
      });

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
      _seedEpub(tmpDir, {'style.css': 'body { color: red; }'});
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(repo.readCssSync(entry), 'body { color: red; }');
    });
  });

  group('saveCss', () {
    test('first save creates .original backup', () {
      _seedEpub(tmpDir, {'style.css': 'original content'});
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'modified content');

      expect(File(entry.originalPath).existsSync(), isTrue);
      expect(File(entry.originalPath).readAsStringSync(), 'original content');
      expect(File(entry.absolutePath).readAsStringSync(), 'modified content');
    });

    test('saving same content as disk is a no-op (no .original created)', () {
      _seedEpub(tmpDir, {'style.css': 'same'});
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'same');

      expect(File(entry.originalPath).existsSync(), isFalse);
    });

    test('saving back to original content deletes .original', () {
      _seedEpub(tmpDir, {'style.css': 'original'});
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
      _seedEpub(tmpDir, {'style.css': 'v1'});
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
      _seedEpub(tmpDir, {'style.css': 'body{}'});
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isFalse);
    });

    test('returns true when content differs from .original', () {
      _seedEpub(tmpDir, {'style.css': 'modified'});
      _createFile(tmpDir, 'style.css.original', 'original');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isTrue);
    });

    test('returns false when content matches .original', () {
      _seedEpub(tmpDir, {'style.css': 'same'});
      _createFile(tmpDir, 'style.css.original', 'same');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isFalse);
    });
  });

  group('resetFile', () {
    test('restores content from .original and deletes backup', () {
      _seedEpub(tmpDir, {'style.css': 'modified'});
      _createFile(tmpDir, 'style.css.original', 'original');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.resetFile(entry);

      expect(File(entry.absolutePath).readAsStringSync(), 'original');
      expect(File(entry.originalPath).existsSync(), isFalse);
    });

    test('no-op when no .original exists', () {
      _seedEpub(tmpDir, {'style.css': 'content'});
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.resetFile(entry); // should not throw

      expect(File(entry.absolutePath).readAsStringSync(), 'content');
    });
  });

  group('resetAll', () {
    test('resets all files that have .original backups', () {
      _seedEpub(tmpDir, {
        'a.css': 'modified-a',
        'b.css': 'untouched-b',
        'c.css': 'modified-c',
      });
      _createFile(tmpDir, 'a.css.original', 'original-a');
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

/// TODO-1234: seed a minimal EPUB (META-INF/container.xml + root content.opf)
/// whose manifest declares [cssFiles] (media-type text/css) and [otherFiles]
/// (application/xhtml+xml). The OPF sits at the extract-dir root, so manifest
/// hrefs equal the extract-dir-relative paths. CSS file bodies come from the
/// map values; other files get a stub body.
void _seedEpub(
  Directory root,
  Map<String, String> cssFiles, {
  List<String> otherFiles = const <String>[],
}) {
  cssFiles.forEach((rel, content) => _createFile(root, rel, content));
  for (final String rel in otherFiles) {
    _createFile(root, rel, '<html/>');
  }

  final StringBuffer items = StringBuffer();
  int i = 0;
  cssFiles.forEach((rel, _) {
    items.writeln('    <item id="css$i" href="$rel" media-type="text/css"/>');
    i++;
  });
  for (final String rel in otherFiles) {
    items.writeln(
        '    <item id="doc$i" href="$rel" media-type="application/xhtml+xml"/>');
    i++;
  }

  _createFile(
    root,
    'META-INF/container.xml',
    '<?xml version="1.0"?>\n'
        '<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
        '  <rootfiles>\n'
        '    <rootfile full-path="content.opf" '
        'media-type="application/oebps-package+xml"/>\n'
        '  </rootfiles>\n'
        '</container>\n',
  );
  _createFile(
    root,
    'content.opf',
    '<?xml version="1.0"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">\n'
        '  <manifest>\n'
        '$items'
        '  </manifest>\n'
        '  <spine/>\n'
        '</package>\n',
  );
}

/// Append one extra manifest item to an already-seeded OPF without writing the
/// file on disk — used to prove absent manifest CSS items are skipped.
void _declareExtraManifestItem(
  Directory root,
  String href,
  String mediaType,
) {
  final File opf = File(p.join(root.path, 'content.opf'));
  final String xml = opf.readAsStringSync();
  final String injected = xml.replaceFirst(
    '  </manifest>',
    '    <item id="extra" href="$href" media-type="$mediaType"/>\n'
        '  </manifest>',
  );
  opf.writeAsStringSync(injected);
}
