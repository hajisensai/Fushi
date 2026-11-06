// 合集竖版封面自有层（PR #2606 审查）：原盘竖版盘面图单独登记在 media_images，
// 不写进合集自有封面 coverPath；用户手选优先，刮削海报排在盘面图后面，扫描与
// 刮削谁先谁后终态一致。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart';
import 'package:fushi_engine/media/collections/collection_cover.dart';
import 'package:fushi_engine/media/video/scraper/sidecar_scanner.dart'
    show SidecarGeneratedArtifactChecker;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 只认登记过的路径是「未被改动的刮削生成图」（替身：真实实现按
/// video_sidecar_artifacts 的 sha256 比对）。
class _FakeGenerated implements SidecarGeneratedArtifactChecker {
  _FakeGenerated(this.paths);

  final Set<String> paths;

  @override
  Future<bool> isUnmodifiedGeneratedArtifact(String absolutePath) async =>
      paths.contains(absolutePath);
}

void main() {
  late FushiDatabase db;
  late int id;

  setUp(() async {
    // 与生产连接同一 PRAGMA：删合集靠 FK cascade 带走 media_images 行，回收护栏
    // 才不会把已删行当「仍被引用」。
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    id = await db.createMediaCollection('Disc 1', collectionType: 'playlist');
  });

  tearDown(() => db.close());

  Future<MediaCollectionRow> row() async =>
      (await db.getMediaCollectionById(id))!;

  Future<List<String>> candidates() async =>
      loadCollectionOwnCoverCandidates(db, await row());

  group('collectionOwnCoverCandidates', () {
    test('自有封面在前，盘面竖图在后；横图 disc_art 不进竖卡', () async {
      await db.setCollectionDiscImage(id, MediaImageKind.discArt, 'wide.jpg');
      expect(await candidates(), isEmpty);
      await db.setCollectionDiscImage(id, MediaImageKind.discCover, 'disc.jpg');
      expect(await candidates(), <String>['disc.jpg']);
      await db.updateMediaCollectionCoverPath(id, 'picked.jpg');
      expect(await candidates(), <String>['picked.jpg', 'disc.jpg']);
    });

    test('只允许盘面图种类走 setCollectionDiscImage', () {
      expect(
        () => db.setCollectionDiscImage(id, MediaImageKind.backdrop, 'b.jpg'),
        throwsArgumentError,
      );
    });
  });

  group('刮削海报与盘面竖图', () {
    const String scraped = '/lib/Show/poster.jpg';
    final _FakeGenerated generated = _FakeGenerated(<String>{scraped});

    Future<void> scrape() =>
        applyScrapedCollectionCover(db, id, scraped, generated: generated);

    Future<void> scanDiscCover() async {
      await db.setCollectionDiscImage(id, MediaImageKind.discCover, 'disc.jpg');
      await yieldGeneratedCollectionCoverToDiscCover(
        db,
        id,
        generated: generated,
      );
    }

    test('没有盘面图：刮削海报照旧写进自有层', () async {
      await scrape();
      expect((await row()).coverPath, scraped);
    });

    test('先刮削后扫描 / 先扫描后刮削：终态相同，盘面图在刮削海报之前', () async {
      await scrape();
      await scanDiscCover();
      final List<String> scrapeFirst = await candidates();

      await db.updateMediaCollectionCoverPath(id, null);
      await (db.delete(db.mediaImages)).go();

      await scanDiscCover();
      await scrape();
      final List<String> scanFirst = await candidates();

      expect(scrapeFirst, <String>['disc.jpg']);
      expect(scanFirst, scrapeFirst);
      expect((await row()).coverPath, isNull);
    });

    test('用户手选封面优先：扫描与刮削都不动它', () async {
      await db.updateMediaCollectionCoverPath(id, 'picked.jpg');
      await scanDiscCover();
      await scrape();
      expect((await row()).coverPath, 'picked.jpg');
      expect(await candidates(), <String>['picked.jpg', 'disc.jpg']);
    });
  });

  test('清除合集封面后：盘面图仍在附加图组，重登记也不写回自有层', () async {
    final Directory covers = await Directory.systemTemp.createTemp('cc_');
    addTearDown(() => covers.delete(recursive: true));
    final String picked = p.join(covers.path, '$id.jpg');
    File(picked).writeAsBytesSync(<int>[1]);
    await db.updateMediaCollectionCoverPath(id, picked);
    await db.setCollectionDiscImage(id, MediaImageKind.discCover, 'disc.jpg');

    await clearCollectionOwnCover(db, id, collectionCoversDirectory: covers);
    expect((await row()).coverPath, isNull);
    expect(await candidates(), <String>['disc.jpg']);

    // 下一次扫描：盘面图槽位重登记，自有层仍空。
    await db.setCollectionDiscImage(id, MediaImageKind.discCover, 'disc.jpg');
    await yieldGeneratedCollectionCoverToDiscCover(db, id);
    expect((await row()).coverPath, isNull);
  });

  test('删合集回收盘面图文件（横竖两张）', () async {
    final Directory covers = await Directory.systemTemp.createTemp('cc_');
    addTearDown(() => covers.delete(recursive: true));
    final File tall = File(p.join(covers.path, '${id}_disc_cover.jpg'))
      ..writeAsBytesSync(<int>[1]);
    final File wide = File(p.join(covers.path, '${id}_disc.jpg'))
      ..writeAsBytesSync(<int>[2]);
    await db.setCollectionDiscImage(id, MediaImageKind.discCover, tall.path);
    await db.setCollectionDiscImage(id, MediaImageKind.discArt, wide.path);

    await deleteMediaCollectionWithAssets(
      db,
      id,
      collectionCoversDirectory: covers,
    );
    expect(tall.existsSync(), isFalse);
    expect(wide.existsSync(), isFalse);
  });
}
