import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_manager.dart';

/// BUG-081: books are stored extracted (no standalone .epub on disk), so
/// content sync must re-package the extract dir into a valid .epub. Verify the
/// repackage produces an archive whose EPUB structure sits at the zip root
/// (so it re-imports cleanly on the other device), and that it no-ops when
/// there is nothing to package.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('hibiki_repack_test'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory _fakeExtractedBook() {
    final Directory d = Directory('${tmp.path}/extracted')..createSync();
    File('${d.path}/mimetype').writeAsStringSync('application/epub+zip');
    Directory('${d.path}/META-INF').createSync();
    File('${d.path}/META-INF/container.xml').writeAsStringSync(
        '<?xml version="1.0"?><container version="1.0"><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf"/></rootfiles></container>');
    Directory('${d.path}/OEBPS').createSync();
    File('${d.path}/OEBPS/content.opf').writeAsStringSync('<package/>');
    File('${d.path}/OEBPS/chapter.xhtml').writeAsStringSync('<html/>');
    return d;
  }

  test('repackages an extracted book into a root-rooted EPUB archive',
      () async {
    final Directory src = _fakeExtractedBook();
    final String out = '${tmp.path}/book.epub';

    final bool built = await repackageExtractedEpub(src.path, out);
    expect(built, isTrue);
    expect(File(out).existsSync(), isTrue);

    final Archive archive =
        ZipDecoder().decodeBytes(File(out).readAsBytesSync());
    final Set<String> names = archive.files
        .where((ArchiveFile f) => f.isFile)
        .map((f) => f.name)
        .toSet();

    // EPUB structure must be at the archive ROOT (no wrapping dir), so the
    // other device's EpubImporter finds mimetype/container.xml/OPF.
    expect(names, contains('mimetype'));
    expect(names, contains('META-INF/container.xml'));
    expect(names, contains('OEBPS/content.opf'));
    expect(names, contains('OEBPS/chapter.xhtml'));
    expect(names.any((String n) => n.startsWith('extracted/')), isFalse,
        reason: 'entries must not be wrapped in the extract-dir name');

    final ArchiveFile mimetype =
        archive.files.firstWhere((ArchiveFile f) => f.name == 'mimetype');
    expect(String.fromCharCodes(mimetype.content as List<int>),
        'application/epub+zip');
  });

  test('no-ops (false) when the extract dir is empty or missing', () async {
    expect(await repackageExtractedEpub('', '${tmp.path}/x.epub'), isFalse);
    expect(
        await repackageExtractedEpub(
            '${tmp.path}/does_not_exist', '${tmp.path}/y.epub'),
        isFalse);
  });
}
