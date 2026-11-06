import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';

/// 复习同步 v2 替换了旧同步层与旧定时备份层（docs/specs/2026-10-25-srs-sync-v2-plan.md P7：「无双份实现」）。
/// 旧实现已整体删除：任何生产代码重新引用它们的符号或文件，就是又长出了第二套同步 / 备份。
///
/// 只扫生产源码（各包 `lib/`）；注释里提到旧名字不算（剥掉 `//` 注释再匹配）。
void main() {
  /// 旧同步引擎（fushi_srs/lib/src/sync/）与旧备份库（srs_backup_store / retention / point-in-time）的符号与文件名。
  final RegExp removed = RegExp(
    r'\b(SrsSyncEngine|SrsSyncDirectory|SrsSyncReplica|SrsMemoryReplica|'
    r'SrsSyncLocalState|SrsDirectoryState|SrsSyncOptions|SrsCursorFile|'
    r'SrsBackupStore|SrsBackupController|SrsBackupLimits|SrsBackupArchive|'
    r'SrsBackupManifest|SrsBackupSnapshotReader|srsPointInTimeRestore|'
    r'srsBackupControllerProvider|srsBackupStoreProvider)\b|'
    r'srs_backup_store\.dart|srs_backup_retention\.dart|'
    r'srs_point_in_time_restore\.dart|srs_asset_store_directory\.dart|'
    r"fushi_srs/src/sync/|'src/sync/(sync_engine|sync_files|memory_replica)\.dart'",
  );
  final RegExp lineComment = RegExp(r'//.*$', multiLine: true);

  test('生产源码不再引用旧 SRS 同步引擎 / 旧定时备份', () {
    final List<Directory> roots = <Directory>[
      Directory('lib'),
      for (final String pkg in <String>[
        'fushi_engine',
        'fushi_srs',
        'fushi_core',
        'fushi_server',
      ])
        Directory('../packages/$pkg/lib'),
    ];
    int scanned = 0;
    final List<String> offenders = <String>[];
    for (final Directory root in roots) {
      expect(root.existsSync(), isTrue, reason: '请从 fushi/ 包根跑测试：${root.path}');
      for (final FileSystemEntity e in root.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('.g.dart')) continue;
        scanned++;
        final String code = e.readAsStringSync().replaceAll(lineComment, '');
        for (final RegExpMatch m in removed.allMatches(code)) {
          offenders.add('${e.path.replaceAll('\\', '/')}: ${m.group(0)}');
        }
      }
    }
    expectScanScale(
      scanned,
      what: '各包 lib/ 下的 .dart',
      atLeast: 2000,
      measured: 2729,
    );
    expect(offenders, isEmpty);
  });
}
