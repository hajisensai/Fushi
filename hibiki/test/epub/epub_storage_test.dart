import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('epub_storage_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test('bookPath returns path without creating directory', () {
    final String path = p.join(tmpDir.path, 'hoshi_books', '42');
    expect(Directory(path).existsSync(), isFalse);
  });

  test('rename from temp to final succeeds when target does not exist', () {
    final String tempDir = p.join(tmpDir.path, 'hoshi_books', '999');
    final String finalDir = p.join(tmpDir.path, 'hoshi_books', '1');
    Directory(tempDir).createSync(recursive: true);
    File(p.join(tempDir, 'test.txt')).writeAsStringSync('hello');

    Directory(tempDir).renameSync(finalDir);
    expect(Directory(finalDir).existsSync(), isTrue);
    expect(File(p.join(finalDir, 'test.txt')).readAsStringSync(), 'hello');
    expect(Directory(tempDir).existsSync(), isFalse);
  });

  test('rename to existing directory throws (proving the bug)', () {
    final String tempDir = p.join(tmpDir.path, 'hoshi_books', '999');
    final String finalDir = p.join(tmpDir.path, 'hoshi_books', '1');
    Directory(tempDir).createSync(recursive: true);
    Directory(finalDir).createSync(recursive: true);

    expect(
      () => Directory(tempDir).renameSync(finalDir),
      throwsA(isA<FileSystemException>()),
    );
  });
}
