import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/collection_asset_reclaim.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/source_guard.dart';

/// BUG-1319 守卫：删合集必须回收该合集**自有**的磁盘资产，且**只**回收它自己的。
///
/// 两个方向都要锁死：
/// - 漏删（本 BUG 的症状）：合集封面落在 `video_covers/collections/<id>.jpg`，
///   `VideoStorage.gcOrphanCovers` 故意扫不到那个子目录，DB 行一删路径就永久
///   丢失 —— 删除时不回收 = 确定性空间泄漏。
/// - 误删（修复本身的风险）：这是**删文件**的代码，判据必须精确到「这个文件确实
///   只属于这个被删的合集」。别的合集的封面、目录外的用户图片一律不许碰。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<Directory> _tempCoversDir() async {
  final Directory dir =
      await Directory.systemTemp.createTemp('collection_covers_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

/// 在合集封面目录内建一个占位封面文件，并把路径写进合集行。
Future<File> _giveCover(
  HibikiDatabase db,
  Directory coversDir,
  int collectionId,
) async {
  final File file = File(p.join(coversDir.path, '$collectionId.jpg'));
  await file.writeAsBytes(<int>[0xFF, 0xD8, 0xFF]);
  await db.updateMediaCollectionCoverPath(collectionId, file.path);
  return file;
}

void main() {
  group('deleteMediaCollectionWithAssets', () {
    test('回收被删合集自己的封面文件，同时删掉 DB 行', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      final int id = await db.createMediaCollection('A');
      final File cover = await _giveCover(db, covers, id);
      expect(cover.existsSync(), isTrue);

      final int removed = await deleteMediaCollectionWithAssets(
        db,
        id,
        collectionCoversDirectory: covers,
      );

      expect(removed, 1, reason: '返回值必须透传被删的合集行数，调用方判据零变化');
      expect(await db.getMediaCollectionById(id), isNull);
      expect(cover.existsSync(), isFalse,
          reason: '合集自有封面必须随合集一起回收，否则永久泄漏（BUG-1319）');
    });

    test('别的合集的封面文件一根汗毛都不许动', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      final int victim = await db.createMediaCollection('victim');
      final int bystander = await db.createMediaCollection('bystander');
      final File victimCover = await _giveCover(db, covers, victim);
      final File bystanderCover = await _giveCover(db, covers, bystander);

      await deleteMediaCollectionWithAssets(
        db,
        victim,
        collectionCoversDirectory: covers,
      );

      expect(victimCover.existsSync(), isFalse);
      expect(bystanderCover.existsSync(), isTrue,
          reason: '同目录里其余合集的封面必须原样保留——这是删文件代码的第一红线');
      expect((await db.getMediaCollectionById(bystander))!.coverPath,
          bystanderCover.path);
    });

    test('两个合集共用同一张封面时，另一个还引用着就保留', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      final int victim = await db.createMediaCollection('victim');
      final int sharer = await db.createMediaCollection('sharer');
      final File shared = await _giveCover(db, covers, victim);
      await db.updateMediaCollectionCoverPath(sharer, shared.path);

      await deleteMediaCollectionWithAssets(
        db,
        victim,
        collectionCoversDirectory: covers,
      );

      expect(shared.existsSync(), isTrue, reason: '仍被存活合集引用的文件是活数据，宁可漏删也不能误删');
    });

    test('落在合集封面目录之外的文件绝不删（用户外部图片）', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      final Directory outside =
          await Directory.systemTemp.createTemp('user_pictures_');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final File external = File(p.join(outside.path, 'my_photo.jpg'));
      await external.writeAsBytes(<int>[1, 2, 3]);
      final int id = await db.createMediaCollection('A');
      await db.updateMediaCollectionCoverPath(id, external.path);

      await deleteMediaCollectionWithAssets(
        db,
        id,
        collectionCoversDirectory: covers,
      );

      expect(external.existsSync(), isTrue, reason: '目录外的路径是用户自己的文件，删合集不该动它');
    });

    test('无封面的合集不碰文件系统，且删除照常完成', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      final int id = await db.createMediaCollection('A');

      final int removed = await deleteMediaCollectionWithAssets(
        db,
        id,
        collectionCoversDirectory: covers,
      );

      expect(removed, 1);
      expect(await db.getMediaCollectionById(id), isNull);
      expect(covers.listSync(), isEmpty);
    });

    test('合集不存在时不抛、返回 0', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      expect(
        await deleteMediaCollectionWithAssets(
          db,
          4242,
          collectionCoversDirectory: covers,
        ),
        0,
      );
    });
  });

  group('reclaimDeletedCollectionAssets（事务外回收，同步删除传播用）', () {
    test('批量回收多个已删合集的封面，存活合集的封面不受影响', () async {
      final HibikiDatabase db = await _openDb();
      final Directory covers = await _tempCoversDir();
      final int a = await db.createMediaCollection('A');
      final int b = await db.createMediaCollection('B');
      final int keep = await db.createMediaCollection('keep');
      final File coverA = await _giveCover(db, covers, a);
      final File coverB = await _giveCover(db, covers, b);
      final File coverKeep = await _giveCover(db, covers, keep);

      final MediaCollectionRow rowA = (await db.getMediaCollectionById(a))!;
      final MediaCollectionRow rowB = (await db.getMediaCollectionById(b))!;
      await db.deleteMediaCollectionRaw(a);
      await db.deleteMediaCollectionRaw(b);

      final int reclaimed = await reclaimDeletedCollectionAssets(
        db,
        <MediaCollectionRow>[rowA, rowB],
        collectionCoversDirectory: covers,
      );

      expect(reclaimed, 2);
      expect(coverA.existsSync(), isFalse);
      expect(coverB.existsSync(), isFalse);
      expect(coverKeep.existsSync(), isTrue, reason: '同一轮同步里没被删的合集，封面必须完好');
    });
  });

  group('源码守卫：删合集只有一个入口', () {
    // 根因不是「某个页面忘了删文件」，而是回收挂在某个调用点上、不挂在删除动作上。
    // 只要生产代码里还允许裸调 DAO 的删除方法，下一个新入口就会重演泄漏。
    test('生产代码不得裸调 DAO 删合集方法 —— 一律走带回收的入口', () {
      final Directory lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: '必须在 hibiki/ 包根下跑');
      // 唯一豁免：回收入口自己，它就是那层包装。
      const String allowed =
          'lib/src/media/collections/collection_asset_reclaim.dart';
      // 前置负向后顾定标识符边界：deleteMediaCollectionWithAssets(（新入口）与
      // deleteMediaCollectionRaw(（同步引擎另行处理）都不该被这条判据命中。
      final RegExp bare =
          RegExp('(?<![A-Za-z0-9_\$])deleteMediaCollection' r'\s*\(');
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String rel = entity.path.replaceAll(r'\', '/');
        if (rel.endsWith(allowed)) continue;
        for (final String line in entity.readAsStringSync().split('\n')) {
          final String trimmed = line.trim();
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          if (bare.hasMatch(trimmed)) offenders.add('$rel: $trimmed');
        }
      }
      expect(offenders, isEmpty,
          reason: '这些调用点删了 DB 行却不回收合集自有封面 = 确定性磁盘泄漏'
              '（BUG-1319）。改调 deleteMediaCollectionWithAssets；'
              '事务内删行的调用方用 reclaimDeletedCollectionAssets 在事务外收尾。');
    });

    test('同步删除传播必须在事务外回收被解散合集的资产', () {
      final String src =
          File('lib/src/sync/collection_sync_engine.dart').readAsStringSync();
      final String body = methodBody(
        src,
        'Future<int> applyCollectionLocalChanges(',
      );
      expect(containsCodeLine(body, 'dissolved.add(row)'), isTrue,
          reason: '删行前必须入列行快照——行一删 coverPath 就推导不出来了');
      expect(
          containsCodeLine(
              body, 'reclaimDeletedCollectionAssets(db, dissolved)'),
          isTrue,
          reason: '同步删除传播同样会解散合集，不回收就同样泄漏');
      final int txEnd = body.indexOf('});');
      final int reclaimAt = body.indexOf('reclaimDeletedCollectionAssets(');
      expect(txEnd >= 0 && reclaimAt > txEnd, isTrue,
          reason: '文件 IO 必须落在 db.transaction 之后，不能在事务里做');
    });
  });
}
