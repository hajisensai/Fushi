// game.scrape.apply 的撤销快照往返：先前无该源 / 先前有该源 / 先前有封面三种形态，
// 撤销后库与封面文件精确回到执行前；执行后又被改过的报 superseded、不动。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/mining/metadata/galgame_scrape_snapshot.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  late Directory root;
  late Directory covers;
  late Directory backups;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('galgame_scrape_snapshot');
    covers = Directory(p.join(root.path, 'covers'))..createSync();
    backups = Directory(p.join(root.path, 'backups'));
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'game',
        exePath: r'C:\g\game.exe',
        workdir: r'C:\g',
        addedAt: 1,
      ),
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// 照 `applyGalgameScrapeCandidate` 的落库形状：写源行 + 两列，封面先删全部旧图再落新图。
  Future<GalgameScrapeAfter> apply({
    required String source,
    required String externalId,
    String? newCoverExt,
  }) async {
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'g1',
        source: source,
        externalId: Value<String?>(externalId),
        dataJson: '{"id":"$externalId"}',
        fetchedAt: 99,
      ),
    );
    await db.setGalgameScrapeResult(
      'g1',
      primarySource: source,
      releaseDate: '2020-01-01',
    );
    if (newCoverExt != null) {
      for (final FileSystemEntity f in covers.listSync()) {
        if (p.basenameWithoutExtension(f.path) == 'g1') f.deleteSync();
      }
      final String path = p.join(covers.path, 'g1$newCoverExt');
      File(path).writeAsStringSync('new-cover-$externalId');
      await db.setGalgameCoverPath('g1', path);
    }
    final GalgameRow row = (await db.getGalgame('g1'))!;
    return GalgameScrapeAfter(
      primarySource: row.primarySource,
      releaseDate: row.releaseDate,
      coverPath: row.coverPath,
      coverStamp: galgameCoverStamp(row.coverPath),
      externalId: externalId,
    );
  }

  Future<GalgameScrapeSnapshot> roundTrip(GalgameScrapeSnapshot s) async =>
      GalgameScrapeSnapshot.fromJson(s.toJson());

  test('先前没有该源：撤销删掉源行、两列回到原值', () async {
    final GalgameScrapeSnapshot snap = await roundTrip(
      await captureGalgameScrapeSnapshot(
        db,
        gameId: 'g1',
        source: 'vndb',
        backupDirectory: backups,
      ),
    );
    expect(snap.sourceRow, isNull);
    final GalgameScrapeAfter after = await apply(
      source: 'vndb',
      externalId: 'v1',
    );
    final GalgameScrapeRevertResult r = await revertGalgameScrape(
      db,
      snap,
      after: after,
    );
    expect(r.status, GalgameScrapeRevertStatus.restored);
    expect(await db.getGalgameSources('g1'), isEmpty);
    final GalgameRow row = (await db.getGalgame('g1'))!;
    expect(row.primarySource, isNull);
    expect(row.releaseDate, isNull);
    expect(row.coverPath, isNull);
  });

  test('先前有该源：撤销把旧行整行写回', () async {
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'g1',
        source: 'bgm',
        externalId: const Value<String?>('b0'),
        dataJson: '{"old":true}',
        score: const Value<double?>(7.5),
        rank: const Value<int?>(12),
        fetchedAt: 5,
      ),
    );
    await db.setGalgameScrapeResult(
      'g1',
      primarySource: 'bgm',
      releaseDate: '2001-02-03',
    );
    final GalgameScrapeSnapshot snap = await roundTrip(
      await captureGalgameScrapeSnapshot(
        db,
        gameId: 'g1',
        source: 'bgm',
        backupDirectory: backups,
      ),
    );
    final GalgameScrapeAfter after = await apply(
      source: 'bgm',
      externalId: 'b1',
    );
    expect(
      (await revertGalgameScrape(db, snap, after: after)).status,
      GalgameScrapeRevertStatus.restored,
    );
    final GalgameSourceRow back = (await db.getGalgameSources('g1')).single;
    expect(back.externalId, 'b0');
    expect(back.dataJson, '{"old":true}');
    expect(back.score, 7.5);
    expect(back.rank, 12);
    expect(back.fetchedAt, 5);
    final GalgameRow row = (await db.getGalgame('g1'))!;
    expect(row.primarySource, 'bgm');
    expect(row.releaseDate, '2001-02-03');
  });

  test('先前有封面：换了扩展名的新图被删、旧图从备份拷回；备份修改时间是建立时刻', () async {
    final String oldCover = p.join(covers.path, 'g1.png');
    File(oldCover).writeAsStringSync('old-cover');
    // 原图很老：备份不能继承这个修改时间（BUG-4844）。
    await File(oldCover).setLastModified(DateTime(2000));
    await db.setGalgameCoverPath('g1', oldCover);
    final DateTime captured = DateTime.now();
    final GalgameScrapeSnapshot snap = await roundTrip(
      await captureGalgameScrapeSnapshot(
        db,
        gameId: 'g1',
        source: 'vndb',
        backupDirectory: backups,
      ),
    );
    expect(snap.coverBackup, isNotNull);
    final DateTime backupTime = File(snap.coverBackup!).lastModifiedSync();
    expect(
      backupTime.isAfter(captured.subtract(const Duration(minutes: 1))),
      isTrue,
    );
    final GalgameScrapeAfter after = await apply(
      source: 'vndb',
      externalId: 'v1',
      newCoverExt: '.jpg',
    );
    expect(File(oldCover).existsSync(), isFalse);
    expect(
      (await revertGalgameScrape(db, snap, after: after)).status,
      GalgameScrapeRevertStatus.restored,
    );
    expect(File(oldCover).readAsStringSync(), 'old-cover');
    expect(File(p.join(covers.path, 'g1.jpg')).existsSync(), isFalse);
    expect((await db.getGalgame('g1'))!.coverPath, oldCover);
    expect(File(snap.coverBackup!).existsSync(), isFalse);
  });

  test('同路径换图：旧图拷回原路径', () async {
    final String oldCover = p.join(covers.path, 'g1.jpg');
    File(oldCover).writeAsStringSync('old');
    await db.setGalgameCoverPath('g1', oldCover);
    final GalgameScrapeSnapshot snap = await captureGalgameScrapeSnapshot(
      db,
      gameId: 'g1',
      source: 'vndb',
      backupDirectory: backups,
    );
    final GalgameScrapeAfter after = await apply(
      source: 'vndb',
      externalId: 'v1',
      newCoverExt: '.jpg',
    );
    expect(
      (await revertGalgameScrape(db, snap, after: after)).status,
      GalgameScrapeRevertStatus.restored,
    );
    expect(File(oldCover).readAsStringSync(), 'old');
    expect(covers.listSync(), hasLength(1));
  });

  test('先前没有封面、这次下了新图：撤销删掉新图、封面列回到 null', () async {
    final GalgameScrapeSnapshot snap = await captureGalgameScrapeSnapshot(
      db,
      gameId: 'g1',
      source: 'vndb',
      backupDirectory: backups,
    );
    final GalgameScrapeAfter after = await apply(
      source: 'vndb',
      externalId: 'v1',
      newCoverExt: '.jpg',
    );
    await revertGalgameScrape(db, snap, after: after);
    expect(covers.listSync(), isEmpty);
    expect((await db.getGalgame('g1'))!.coverPath, isNull);
  });

  test('执行后又被改过（再刮一次 / 换封面）：superseded，什么都不动', () async {
    final GalgameScrapeSnapshot snap = await captureGalgameScrapeSnapshot(
      db,
      gameId: 'g1',
      source: 'vndb',
      backupDirectory: backups,
    );
    final GalgameScrapeAfter after = await apply(
      source: 'vndb',
      externalId: 'v1',
    );
    await apply(source: 'vndb', externalId: 'v2');
    expect(
      (await revertGalgameScrape(db, snap, after: after)).status,
      GalgameScrapeRevertStatus.superseded,
    );
    expect((await db.getGalgameSources('g1')).single.externalId, 'v2');

    final GalgameScrapeSnapshot snap2 = await captureGalgameScrapeSnapshot(
      db,
      gameId: 'g1',
      source: 'bgm',
      backupDirectory: backups,
    );
    final GalgameScrapeAfter after2 = await apply(
      source: 'bgm',
      externalId: 'b1',
      newCoverExt: '.png',
    );
    // 用户手动换了封面（同路径不同内容）。
    File(after2.coverPath!).writeAsStringSync('user picked a different one');
    await File(
      after2.coverPath!,
    ).setLastModified(DateTime.now().add(const Duration(seconds: 5)));
    expect(
      (await revertGalgameScrape(db, snap2, after: after2)).status,
      GalgameScrapeRevertStatus.superseded,
    );
    expect(
      File(after2.coverPath!).readAsStringSync(),
      'user picked a different one',
    );
  });
}
