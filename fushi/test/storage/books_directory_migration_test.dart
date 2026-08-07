import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/books_directory.dart';
import 'package:path/path.dart' as p;

/// W2-7：书库目录 `hoshi_books` → `fushi_books` 的启动就地改名迁移。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_books_mig_test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('legacy hoshi_books renamed in place with contents preserved', () {
    final Directory legacy =
        Directory(p.join(root.path, 'hoshi_books', 'BookA'))
          ..createSync(recursive: true);
    File(p.join(legacy.path, 'ch1.html')).writeAsStringSync('html');

    migrateLegacyBooksDirectoryAt(root.path);

    expect(Directory(p.join(root.path, 'hoshi_books')).existsSync(), isFalse);
    expect(
        File(p.join(root.path, 'fushi_books', 'BookA', 'ch1.html'))
            .readAsStringSync(),
        'html');
  });

  test('existing fushi_books wins; legacy left alone; no dir created fresh',
      () {
    Directory(p.join(root.path, 'fushi_books')).createSync(recursive: true);
    Directory(p.join(root.path, 'hoshi_books')).createSync(recursive: true);
    migrateLegacyBooksDirectoryAt(root.path);
    expect(Directory(p.join(root.path, 'hoshi_books')).existsSync(), isTrue,
        reason: '新目录已存在时绝不合并/覆盖');

    // 全新安装：两者皆无 → 不创建任何目录（建目录归消费方）。
    final Directory fresh =
        Directory.systemTemp.createTempSync('fushi_books_mig_fresh');
    addTearDown(() => fresh.deleteSync(recursive: true));
    migrateLegacyBooksDirectoryAt(fresh.path);
    expect(fresh.listSync(), isEmpty);
  });
}
