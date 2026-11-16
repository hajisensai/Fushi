import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsGenState,
        SrsStoreMigrating,
        SrsStoreNotMigrated,
        SrsStoreOpenBlocked;
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 本机只有协议 3 的复习库、还没迁移成新代（打开新代库抛 [SrsStoreNotMigrated] 等 [SrsStoreOpenBlocked]）时，备份导出
/// 的预览不能整个抛错：复习一类记成「需先升级」（[BackupContentSummary.needsUpgrade]，在 present 里、没有计数），
/// 其余类别照常预览、照常导出——以前预览计数直接抛错，连「取消勾选复习、只备份别的」都做不到（G7-5b，上轮复核 minor）。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bk_srs_upgrade_');
  });
  tearDown(() async {
    if (dir.existsSync()) await cleanupTempDir(dir);
  });

  BackupService serviceWith(
    FushiDatabase db,
    SrsStoreOpenBlocked blocked,
    List<int> calls,
  ) => BackupService(
    db: db,
    dbDirectory: dir.path,
    appVersion: '1.0.0',
    srsStorage: () async {
      calls.add(1);
      throw blocked;
    },
  );

  for (final (String name, SrsStoreOpenBlocked blocked)
      in <(String, SrsStoreOpenBlocked)>[
        (
          'needsMigration',
          const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
        ),
        ('migrating', const SrsStoreMigrating('x')),
      ]) {
    test('复习库打不开（$name）：预览把复习记成需先升级，其余照常', () async {
      final FushiDatabase db = FushiDatabase(dir.path);
      addTearDown(db.close);
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'Game One',
          exePath: p.join(dir.path, 'g.exe'),
          workdir: dir.path,
          addedAt: 1,
        ),
      );
      final List<int> calls = <int>[];
      final BackupContentSummary summary = await serviceWith(
        db,
        blocked,
        calls,
      ).summarizeLiveContent();

      expect(summary.needsUpgrade, <BackupCategory>{BackupCategory.srs});
      expect(summary.has(BackupCategory.srs), isTrue);
      expect(summary.counts.containsKey(BackupCategory.srs), isFalse);
      expect(summary.countFor(BackupCategory.games), 1);
      expect(summary.needsUpgrade.contains(BackupCategory.games), isFalse);
      expect(calls, isNotEmpty);
    });
  }

  test('不勾复习：照常导出，不碰复习库', () async {
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    final List<int> calls = <int>[];
    final BackupService service = serviceWith(
      db,
      const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
      calls,
    );
    final String zip = p.join(dir.path, 'out.zip');
    await service.createBackup(
      zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    expect(File(zip).existsSync(), isTrue);
    expect(calls, isEmpty);
  });

  test('勾了复习：明确失败，不做出不带卡片的备份', () async {
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    final BackupService service = serviceWith(
      db,
      const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
      <int>[],
    );
    final String zip = p.join(dir.path, 'out.zip');
    await expectLater(
      service.createBackup(zip, categories: BackupCategory.values.toSet()),
      throwsA(isA<SrsStoreNotMigrated>()),
    );
    expect(File(zip).existsSync(), isFalse);
  });
}
