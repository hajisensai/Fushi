// 旧版复习自动备份目录的收尾清理（srs_legacy_backup_cleanup.dart）：只有整个目录里最新的文件也满 30 天
// 宽限期才整体删除；任何一个新文件都让整个目录留下；目录不存在不报错。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_legacy_backup_cleanup.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  final DateTime now = DateTime(2026, 10, 25, 12);

  setUp(() => tmp = Directory.systemTemp.createTempSync('srs_legacy_bk_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后：留给系统清理。
    }
  });

  /// 在 [dir] 下写一个文件，修改时间设成 [modified]。
  File put(Directory dir, String rel, DateTime modified) {
    final File f = File(p.join(dir.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x');
    f.setLastModifiedSync(modified);
    return f;
  }

  test('全部文件都过了宽限期：整个目录（含子目录）删掉', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    put(d, 'uid/auto-1.db', now.subtract(const Duration(days: 90)));
    put(
      d,
      'uid/media/a.png',
      now.subtract(kSrsLegacyBackupGrace + const Duration(minutes: 1)),
    );
    expect(await srsCleanupLegacyBackups(roots: <Directory>[d], now: now), 1);
    expect(d.existsSync(), isFalse);
  });

  test('有一个文件还在宽限期内：整个目录都不动', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    final File old = put(
      d,
      'uid/auto-1.db',
      now.subtract(const Duration(days: 365)),
    );
    final File fresh = put(
      d,
      'uid/nested/manual.db',
      now.subtract(const Duration(days: 29)),
    );
    expect(await srsCleanupLegacyBackups(roots: <Directory>[d], now: now), 0);
    expect(old.existsSync(), isTrue);
    expect(fresh.existsSync(), isTrue);
  });

  test('目录不存在：不报错，返回 0', () async {
    final Directory missing = Directory(p.join(tmp.path, 'nope'));
    expect(
      await srsCleanupLegacyBackups(roots: <Directory>[missing], now: now),
      0,
    );
    expect(missing.existsSync(), isFalse);
  });

  test('多个根各自判断：过期的删、新的留、不存在的跳过', () async {
    final Directory stale = Directory(p.join(tmp.path, 'documents_srs'));
    final Directory recent = Directory(p.join(tmp.path, 'support_srs'));
    final Directory missing = Directory(p.join(tmp.path, 'missing'));
    put(stale, 'a.db', now.subtract(const Duration(days: 31)));
    put(recent, 'b.db', now.subtract(const Duration(days: 1)));
    expect(
      await srsCleanupLegacyBackups(
        roots: <Directory>[stale, recent, missing],
        now: now,
      ),
      1,
    );
    expect(stale.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
  });

  test('空目录（没有任何文件）：没有新证据，直接删', () async {
    final Directory empty = Directory(p.join(tmp.path, 'srs_backups'))
      ..createSync();
    Directory(p.join(empty.path, 'sub')).createSync();
    expect(
      await srsCleanupLegacyBackups(roots: <Directory>[empty], now: now),
      1,
    );
    expect(empty.existsSync(), isFalse);
  });
}
