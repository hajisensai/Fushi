import 'dart:io';

import 'package:test/test.dart';

/// G11-4 守卫：整包备份 / 还原 / 服务端备份的复习部分只走新代（协议 4）内核。
///
/// - 不打开 `SrsStorage`（它会在旁边留着协议 3 `srs.db` 时报 `LegacyNotMigrated`，备份路径不该替用户触发迁移判断之外的开库）：
///   导出 / 落库都直接拿内核 `SrsCore`（导出流、`import`、`legacy_backup_import`、`snapshotInto`）。
/// - 快照不剥本机专属表（`stripDeviceLocal: true` 是给分享 / 同步用的，备份要原样）。
/// - 清单不写 `magic`：旧二进制看到不认识的 `srs/manifest.json` 会把它当未知条目跳过，而带 magic 的会被误认成 v1 事件清单。
/// - 封存的 `srs.db` 永不删、不换：还原代码里提到它的地方只能是协议 3 暂存文件路径（启动恢复认旧 sidecar 用）。
void main() {
  // 测试 cwd 是 `fushi/`。
  const List<String> backupSources = <String>[
    'lib/src/sync/backup_service.dart',
    'lib/src/sync/backup_service/restore.part.dart',
    'lib/src/sync/backup_service/srs_restore.part.dart',
    'lib/src/sync/backup_merge_engine.dart',
    '../packages/fushi_server/lib/src/backup/server_backup.dart',
    '../packages/fushi_engine/lib/srs/srs_backup_bundle.dart',
    '../packages/fushi_engine/lib/srs/srs_backup_merge.dart',
  ];

  /// 去掉整行 `//` 注释（文档注释里会解释为什么不这么做）。
  List<(int, String)> codeLines(String path) {
    final File f = File(path);
    expect(f.existsSync(), isTrue, reason: 'missing ${f.absolute.path}');
    final List<String> lines = f.readAsLinesSync();
    return <(int, String)>[
      for (int i = 0; i < lines.length; i++)
        if (!lines[i].trimLeft().startsWith('//')) (i + 1, lines[i]),
    ];
  }

  void expectAbsent(RegExp pattern, String why) {
    final List<String> hits = <String>[
      for (final String path in backupSources)
        for (final (int n, String line) in codeLines(path))
          if (pattern.hasMatch(line)) '$path:$n: ${line.trim()}',
    ];
    expect(hits, isEmpty, reason: why);
  }

  test('备份路径不打开 SrsStorage', () {
    expectAbsent(
      RegExp(r'SrsStorage\.open\b'),
      '备份 / 还原只用 SrsCore（导出流 / import / legacy_backup_import / snapshotInto）',
    );
  });

  test('备份快照不剥本机专属表', () {
    expectAbsent(RegExp(r'stripDeviceLocal:\s*true'), '整包 / 服务端备份要原样快照');
  });

  test('清单不写 magic', () {
    expectAbsent(
      RegExp(r'''['"]magic['"]\s*:'''),
      'v2 清单不带 magic（带 magic 的是 v1 事件清单）',
    );
  });

  test('还原代码只在协议 3 暂存文件路径上提到封存的 srs.db', () {
    final List<String> hits = <String>[
      for (final String path in backupSources)
        for (final (int n, String line) in codeLines(path))
          if (line.contains('legacyPathIn(') &&
              !line.contains("legacyPathIn(dbDirectory)}.restore-new'"))
            '$path:$n: ${line.trim()}',
    ];
    expect(hits, isEmpty, reason: '封存的 srs.db 永不删、不换');
  });
}
