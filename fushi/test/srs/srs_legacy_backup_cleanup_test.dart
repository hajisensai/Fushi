// 旧版复习自动备份目录的收尾清理（srs_legacy_backup_cleanup.dart）：宽限期从本机升级到 v2 后第一次看到目录
// 的那一刻起算（持久化成目录里的标记文件），而不是从目录里最新文件的修改时间起算——只剩几个月前手动备份的
// 用户，升级后第一次启动绝不能被整目录删掉。标记满 30 天、且没有比宽限期新的文件才删；目录不存在不报错。
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

  File marker(Directory d) => File(p.join(d.path, kSrsLegacyBackupMarker));

  /// 预置「升级那一刻」的标记。
  void upgradedAt(Directory d, DateTime at) {
    d.createSync(recursive: true);
    marker(d).writeAsStringSync('${at.millisecondsSinceEpoch}');
  }

  Future<int> run(List<Directory> roots, DateTime at) =>
      srsCleanupLegacyBackups(roots: roots, now: at);

  test('首次看到（升级后第一次启动）：只写标记，哪怕全部文件都是一年前的也不删', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    final File old = put(
      d,
      'uid/manual-1.fushisrs',
      now.subtract(const Duration(days: 365)),
    );
    expect(await run(<Directory>[d], now), 0);
    expect(old.existsSync(), isTrue);
    expect(
      int.parse(marker(d).readAsStringSync()),
      now.millisecondsSinceEpoch,
      reason: '升级时刻持久化在标记里',
    );
    // 第二次启动（29 天后）：标记还没满宽限期，照样不删，标记不被改写。
    expect(await run(<Directory>[d], now.add(const Duration(days: 29))), 0);
    expect(old.existsSync(), isTrue);
    expect(int.parse(marker(d).readAsStringSync()), now.millisecondsSinceEpoch);
  });

  test('标记满 30 天、没有新文件：整个目录（含子目录）删掉', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    put(d, 'uid/auto-1.fushisrs', now.subtract(const Duration(days: 400)));
    put(d, 'media/abc', now.subtract(const Duration(days: 400)));
    upgradedAt(d, now.subtract(kSrsLegacyBackupGrace));
    expect(await run(<Directory>[d], now), 1);
    expect(d.existsSync(), isFalse);
  });

  test('标记未满 30 天：不删', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    final File old = put(
      d,
      'uid/auto-1.fushisrs',
      now.subtract(const Duration(days: 400)),
    );
    upgradedAt(
      d,
      now.subtract(kSrsLegacyBackupGrace - const Duration(minutes: 1)),
    );
    expect(await run(<Directory>[d], now), 0);
    expect(old.existsSync(), isTrue);
  });

  test('标记已满，但有一个文件比宽限期新（用户拷回来的）：整个目录都不动', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    final File old = put(
      d,
      'uid/auto-1.fushisrs',
      now.subtract(const Duration(days: 365)),
    );
    final File fresh = put(
      d,
      'uid/nested/manual.fushisrs',
      now.subtract(const Duration(days: 29)),
    );
    upgradedAt(d, now.subtract(const Duration(days: 60)));
    expect(await run(<Directory>[d], now), 0);
    expect(old.existsSync(), isTrue);
    expect(fresh.existsSync(), isTrue);
  });

  test('标记读不出（损坏）：按此刻重写，这一次不删', () async {
    final Directory d = Directory(p.join(tmp.path, 'srs_backups'));
    final File old = put(
      d,
      'uid/auto-1.fushisrs',
      now.subtract(const Duration(days: 365)),
    );
    marker(d).writeAsStringSync('garbage');
    expect(await run(<Directory>[d], now), 0);
    expect(old.existsSync(), isTrue);
    expect(int.parse(marker(d).readAsStringSync()), now.millisecondsSinceEpoch);
  });

  test('目录不存在：不报错、不建目录，返回 0', () async {
    final Directory missing = Directory(p.join(tmp.path, 'nope'));
    expect(await run(<Directory>[missing], now), 0);
    expect(missing.existsSync(), isFalse);
  });

  test('多个根各记各的标记：满期的删、未满的留、不存在的跳过', () async {
    final Directory stale = Directory(p.join(tmp.path, 'documents_srs'));
    final Directory recent = Directory(p.join(tmp.path, 'support_srs'));
    final Directory missing = Directory(p.join(tmp.path, 'missing'));
    put(stale, 'a.fushisrs', now.subtract(const Duration(days: 90)));
    put(recent, 'b.fushisrs', now.subtract(const Duration(days: 90)));
    upgradedAt(stale, now.subtract(const Duration(days: 31)));
    upgradedAt(recent, now.subtract(const Duration(days: 1)));
    expect(await run(<Directory>[stale, recent, missing], now), 1);
    expect(stale.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
  });
}
