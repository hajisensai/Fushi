import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/export_directory.dart';
import 'package:path/path.dart' as p;

/// W2-4：导出目录 `hibikiExport` → `fushiExport` 的启动就地改名迁移。
/// 断言覆盖：旧目录（含内容）被整体改名、内容原样保留；新旧并存时不覆盖新目录；
/// 全新安装直接建新目录；幂等（二次调用 no-op）。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_export_mig_test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('legacy hibikiExport is renamed in place with contents preserved', () {
    final Directory legacy = Directory(p.join(root.path, 'hibikiExport'))
      ..createSync(recursive: true);
    File(p.join(legacy.path, 'card.jpg')).writeAsStringSync('jpg-bytes');

    final Directory result = prepareExportDirectoryAt(root.path);

    expect(p.basename(result.path), 'fushiExport');
    expect(result.existsSync(), isTrue);
    expect(Directory(p.join(root.path, 'hibikiExport')).existsSync(), isFalse,
        reason: '旧目录整体改名，不留旧名');
    expect(
        File(p.join(result.path, 'card.jpg')).readAsStringSync(), 'jpg-bytes',
        reason: '内容原样保留');
  });

  test('existing fushiExport wins; legacy left alone for a later attempt', () {
    Directory(p.join(root.path, 'fushiExport')).createSync(recursive: true);
    final Directory legacy = Directory(p.join(root.path, 'hibikiExport'))
      ..createSync(recursive: true);
    File(p.join(legacy.path, 'old.txt')).writeAsStringSync('old');

    final Directory result = prepareExportDirectoryAt(root.path);

    expect(p.basename(result.path), 'fushiExport');
    expect(
        File(p.join(root.path, 'hibikiExport', 'old.txt')).existsSync(), isTrue,
        reason: '新目录已存在时绝不合并/覆盖，旧目录原样保留');
  });

  test('fresh install creates fushiExport; idempotent on second call', () {
    final Directory first = prepareExportDirectoryAt(root.path);
    expect(first.existsSync(), isTrue);
    expect(p.basename(first.path), 'fushiExport');

    final Directory second = prepareExportDirectoryAt(root.path);
    expect(second.path, first.path);
    expect(Directory(p.join(root.path, 'hibikiExport')).existsSync(), isFalse);
  });
}
