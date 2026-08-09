// TODO-1183: 守卫手机备份「导入/恢复」OOM 崩溃根因修复不回退。
//
// 根因：restoreBackup/mergeRestoreBackup 每处把整个解压条目读进一个
// List<int>（`dest.writeAsBytes(archiveFile.content as List<int>)`），6.2GB 的
// local_audio DB → >6GB 单次 Uint8List → 手机 OOM；且跑在 UI isolate，进度条冻结
// 像「卡死」；失败还走 completeBackupImport 显绿✓「成功」误导用户。
//
// 修复：后台 isolate + OutputFileStream 分块流式落盘（走 rawContent，archive 3.6.1 的
// writeContent 对 decodeBuffer 产物仍会 materialize，故不可用），确定进度回报，failed
// 态画红色错误图标。本文件用源码扫描锁住这些接线。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
    return f.readAsStringSync();
  }

  group('TODO-1183 备份导入流式落盘 / failed 态守卫', () {
    test('backup_service：导入/合并路径不再把整个条目 materialize 后 writeAsBytes', () {
      final String src = read('lib/src/sync/backup_service.dart');
      // 旧的整条目 materialize 直写必须消失（meta.content 仍可，因为它极小）。
      expect(src.contains('writeAsBytes(dbFile.content'), isFalse,
          reason: 'DB 覆盖必须流式，不得 writeAsBytes 整个 DB（OOM 根因）');
      expect(src.contains('writeAsBytes(file.content'), isFalse,
          reason: 'local_audio DB（可数 GB）必须流式落盘');
      expect(src.contains('entry.key.content as List<int>'), isFalse,
          reason: '内容树/词典资源必须流式落盘，不得整条目读进堆');
      // 流式 + 后台 isolate 基础设施在场。
      expect(src.contains('_extractEntriesStreaming'), isTrue);
      expect(src.contains('OutputFileStream'), isTrue,
          reason: '必须用 OutputFileStream 分块落盘');
      expect(src.contains('Isolate.spawn('), isTrue,
          reason: '重解压/落盘必须在后台 isolate，避免冻结 UI isolate（进度卡死）');
      expect(src.contains('file.rawContent'), isTrue,
          reason:
              '走 rawContent 分块流式（archive 3.6.1 writeContent 会 materialize）');
    });

    test('backup_service：restoreBackup/mergeRestoreBackup 暴露 onProgress', () {
      final String src = read('lib/src/sync/backup_service.dart');
      expect(src.contains('void Function(double progress)? onProgress'), isTrue,
          reason: '导入必须能把确定进度回报给遮罩');
    });

    test('app_model：BackupImportPhase 具备 failed 态 + 确定进度 notifier', () {
      final String src = read('lib/src/models/app_model.dart');
      // TODO-1151 起 validating 相位加入（读取/预览遮罩）；此处只锁 failed 态仍在。
      expect(
          src.contains(
              'enum BackupImportPhase { validating, running, done, failed }'),
          isTrue,
          reason: '必须有 failed 态，才能把失败画成错误图标而非绿✓');
      expect(src.contains('void failBackupImport('), isTrue);
      expect(src.contains('backupImportProgress'), isTrue,
          reason: '确定进度用 ValueNotifier，只重建进度条');
    });

    test('backup.part：导入失败走 failBackupImport（不再 completeBackupImport 显成功）', () {
      final String src =
          read('lib/src/sync/sync_settings_schema/backup.part.dart');
      final int importIdx = src.indexOf('Future<void> _import()');
      final int nextTop =
          src.indexOf('Future<_BackupImportChoice?>', importIdx);
      expect(importIdx, greaterThan(0));
      expect(nextTop, greaterThan(importIdx));
      final String importBody = src.substring(importIdx, nextTop);
      final int catchIdx = importBody.indexOf('} catch (e) {');
      expect(catchIdx, greaterThan(0));
      // catch 分支（失败）必须切失败态。
      expect(
          importBody.substring(catchIdx).contains('appModel.failBackupImport('),
          isTrue,
          reason: '导入失败必须切 failed 态，根治「失败却显绿✓成功」');
      // 成功路径仍显成功文案。
      expect(
          importBody.contains('completeBackupImport(t.backup_import_success)'),
          isTrue);
    });

    test('overlay：failed 态画 error_outline（cs.error），done 态画 check_circle', () {
      final String src = read('lib/src/sync/backup_import_overlay_view.dart');
      expect(src.contains('Icons.error_outline'), isTrue);
      expect(src.contains('Icons.check_circle'), isTrue);
      expect(src.contains('cs.error'), isTrue, reason: '失败图标用主题 error 色（红）');
    });
  });
}
