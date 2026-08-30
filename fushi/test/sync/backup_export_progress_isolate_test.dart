import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-1929 回归：给导出备份加进度条时，`onProgress` 一传就把导出整个搞失效。
///
/// `_writeBackupZipInIsolate` 曾把 `Isolate.run` 的闭包和 `ReceivePort` /
/// `onBytes` 写在**同一个作用域**里。Dart 按作用域分配 Context，闭包序列化时
/// 整个 Context 一起走 —— 于是 `_ReceivePortImpl` 和一路捕获到 `AppModel` →
/// `FushiDatabase` → `DynamicLibrary` 的 `onBytes` 都被塞进发往子 isolate 的
/// 消息，spawn 当场抛 `Illegal argument in isolate message`。
///
/// **为什么全套测试抓不到**：仓库里 90+ 处 `createBackup(` 调用**没有一处**传
/// `onProgress`；`onBytes == null` 时那段分支根本不进，Context 里是 null（可
/// 发送）。所以这条用例的关键不是"传了 onProgress"，而是**让 onProgress 闭包
/// 真的持有一个不可发送的对象** —— 只传 `(p) {}` 这种空闭包同样抓不到。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bk_progress_');
  });
  tearDown(() async {
    if (root.existsSync()) await cleanupTempDir(root);
  });

  test('onProgress 闭包持有不可发送对象时，导出照样成功（isolate 闭包不得捕获它）',
      () async {
    final String dbDir = p.join(root.path, 'db');
    final String booksRoot = p.join(root.path, 'fushi_books');
    Directory(dbDir).createSync(recursive: true);
    final File book = File(p.join(booksRoot, 'Bk', 'original.epub'));
    book.parent.createSync(recursive: true);
    await book.writeAsString('EPUB-BYTES');

    final FushiDatabase db = FushiDatabase(dbDir);
    final BackupService service = BackupService(
      db: db,
      dbDirectory: dbDir,
      appVersion: '1.0.0',
      booksRootDirectory: booksRoot,
    );

    // 不可发送对象。真实链路是 onProgress → AppModel → FushiDatabase →
    // DynamicLibrary；这里用 ReceivePort 做等价替身（同样是 native 句柄，同样
    // 过不了 isolate 边界），免得把整个 AppModel 拖进单测。
    final ReceivePort unsendable = ReceivePort();
    addTearDown(unsendable.close);

    final List<double> seen = <double>[];
    final String zipPath = p.join(root.path, 'backup.zip');

    // 修复前这里抛 `Invalid argument(s): Illegal argument in isolate message:
    // object is unsendable`，而不是返回 meta。
    final BackupMeta meta = await service.createBackup(
      zipPath,
      onProgress: (double progress) {
        // 闭包体真的用到 unsendable，否则编译器可能不把它捕进 Context。
        if (unsendable.hashCode == -1) return;
        seen.add(progress);
      },
    );
    await db.close();

    expect(meta.appVersion, '1.0.0');
    expect(File(zipPath).existsSync(), isTrue,
        reason: '导出必须真的产出 zip，而不是 spawn 阶段就抛');

    final InputFileStream input = InputFileStream(zipPath);
    final Archive archive = ZipDecoder().decodeBuffer(input);
    expect(archive.findFile('fushi_books/Bk/original.epub'), isNotNull);
    await input.close();

    expect(seen, isNotEmpty, reason: '进度必须真的回传到本 isolate');
    expect(seen.last, lessThanOrEqualTo(1.0));
  });
}
