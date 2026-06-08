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

  test('path.join does not create intermediate directories', () {
    final String path = p.join(tmpDir.path, 'hoshi_books', '42');
    expect(path, endsWith(p.join('hoshi_books', '42')));
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
    // 目标目录非空：POSIX 的 rename(2) 只在目标为空目录时才原子替换并成功（那样不抛，
    // Linux 上断言假阴性）；放一个文件进去，使 Windows 与 POSIX 都因已存在/ENOTEMPTY
    // 抛 FileSystemException，跨平台一致复现这个 bug。
    File(p.join(finalDir, 'occupied')).writeAsStringSync('x');

    expect(
      () => Directory(tempDir).renameSync(finalDir),
      throwsA(isA<FileSystemException>()),
    );
  });
}
