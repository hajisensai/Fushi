import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('manga_can_import_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('true when .mokuro present with sibling images/ dir holding images', () {
    final String mokuro = p.join(tempDir.path, 'vol1.mokuro');
    File(mokuro).writeAsStringSync('{}');
    final Directory images = Directory(p.join(tempDir.path, 'images'))
      ..createSync();
    File(p.join(images.path, 'p001.jpg')).writeAsStringSync('x');

    expect(mangaImportCanImport(<String>[mokuro]), isTrue);
  });

  test('true when .mokuro present with a <volume>/ subdir of images', () {
    final String mokuro = p.join(tempDir.path, 'vol1.mokuro');
    File(mokuro).writeAsStringSync('{}');
    final Directory vol = Directory(p.join(tempDir.path, 'vol1'))..createSync();
    File(p.join(vol.path, 'p001.jpg')).writeAsStringSync('x');

    expect(mangaImportCanImport(<String>[mokuro]), isTrue);
  });

  test('false when sibling images/ dir is empty (no actual images)', () {
    final String mokuro = p.join(tempDir.path, 'vol1.mokuro');
    File(mokuro).writeAsStringSync('{}');
    Directory(p.join(tempDir.path, 'images')).createSync();

    expect(mangaImportCanImport(<String>[mokuro]), isFalse);
  });

  test('true when .mokuro present with sibling image file', () {
    final String mokuro = p.join(tempDir.path, 'vol1.mokuro');
    File(mokuro).writeAsStringSync('{}');
    File(p.join(tempDir.path, 'p001.jpg')).writeAsStringSync('x');

    expect(mangaImportCanImport(<String>[mokuro]), isTrue);
  });

  test('false when .mokuro present but no sibling images', () {
    final String mokuro = p.join(tempDir.path, 'vol1.mokuro');
    File(mokuro).writeAsStringSync('{}');

    expect(mangaImportCanImport(<String>[mokuro]), isFalse);
  });

  test('false when no .mokuro among paths', () {
    final String img = p.join(tempDir.path, 'p001.jpg');
    File(img).writeAsStringSync('x');

    expect(mangaImportCanImport(<String>[img]), isFalse);
  });

  test('false on empty paths', () {
    expect(mangaImportCanImport(const <String>[]), isFalse);
  });
}
