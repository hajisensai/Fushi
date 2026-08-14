import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi_core/fushi_core.dart';

import 'temp_dir_cleanup.dart';

/// 互联完整支持批次：收藏词/收藏句**删除跨端传播**。
///
/// 此前取消收藏只在本机防复活（墓碑本地抑制），对端那台设备上永远删不掉。本批
/// 把墓碑作为 additive 家族随聚合快照上行（`favoriteWordTombstones` /
/// `favoriteSentenceTombstones`），合并侧做「删除 vs 重收藏」时间戳仲裁：
/// 墓碑 deletedAt 严格新于收藏 createdAt → 删除传播；否则重收藏复活、墓碑退场。
Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return FushiDatabase(dir.path);
}

FavoriteWordRecord _word(String expr, {required int createdAt}) =>
    FavoriteWordRecord(
      expression: expr,
      reading: 'よみ',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-08-14',
      createdAt: createdAt,
    );

String _key(String expr) =>
    FushiDatabase.favoriteWordItemKey(expr, 'よみ', 'book');

void main() {
  group('mergeSnapshots 收藏删除仲裁（纯函数）', () {
    test('墓碑严格新于收藏 → 收藏出局、墓碑保留（删除传播）', () {
      final AggregateSnapshot merged = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(favoriteWords: <FavoriteWordRecord>[
          _word('言葉', createdAt: 100),
        ]),
        AggregateSnapshot(favoriteWordTombstones: <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: _key('言葉'), deletedAt: 200),
        ]),
      );
      expect(merged.favoriteWords, isEmpty, reason: '对端删除必须能把本端收藏带走');
      expect(merged.favoriteWordTombstones.single.deletedAt, 200,
          reason: '墓碑继续随快照传播给第三台设备');
    });

    test('重收藏（createdAt >= deletedAt）→ 收藏保留、墓碑退场（防删除僵尸）', () {
      final AggregateSnapshot merged = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(favoriteWords: <FavoriteWordRecord>[
          _word('言葉', createdAt: 300),
        ]),
        AggregateSnapshot(favoriteWordTombstones: <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: _key('言葉'), deletedAt: 200),
        ]),
      );
      expect(merged.favoriteWords, hasLength(1), reason: '删除后又重收藏的词必须能复活');
      expect(merged.favoriteWordTombstones, isEmpty,
          reason: '被重收藏压过的墓碑不得继续传播（否则反向把新收藏删掉）');
    });

    test('墓碑家族 json 往返 + 旧端缺键回退空（additive 兼容）', () {
      final AggregateSnapshot s = AggregateSnapshot(
        favoriteWordTombstones: <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: _key('言葉'), deletedAt: 42),
        ],
      );
      expect(s.isEmpty, isFalse, reason: '纯删除也必须上传');
      final AggregateSnapshot back = AggregateSnapshot.fromJson(s.toJson());
      expect(back.favoriteWordTombstones.single.itemKey, _key('言葉'));
      expect(back.favoriteWordTombstones.single.deletedAt, 42);
      expect(
          AggregateSnapshot.fromJson(<String, Object?>{'version': 1})
              .favoriteWordTombstones,
          isEmpty);
    });
  });

  group('端到端删除传播（真 DB fold）', () {
    test('A 取消收藏 → 快照带墓碑 → B fold 后本地行被删且墓碑续传', () async {
      final FushiDatabase dbA = await _freshDb('agg_tomb_a_');
      final FushiDatabase dbB = await _freshDb('agg_tomb_b_');
      addTearDown(dbA.close);
      addTearDown(dbB.close);

      // 两端各自收藏了同一个词（B 的 createdAt 较早）。
      for (final FushiDatabase db in <FushiDatabase>[dbA, dbB]) {
        await db.addFavoriteWord(
          expression: '言葉',
          reading: 'よみ',
          glossary: 'g',
          sourceType: 'book',
          dateKey: '2026-08-14',
        );
      }
      // A 取消收藏（写墓碑，deletedAt = now > B 的 createdAt）。
      await dbA.removeFavoriteWord(
          expression: '言葉', reading: 'よみ', sourceType: 'book');

      final AggregateSnapshot snapA =
          await AggregateSyncService(dbA).materializeLocalSnapshot();
      expect(snapA.favoriteWordTombstones, hasLength(1), reason: '本机墓碑必须随快照上行');

      await AggregateSyncService(dbB).foldIntoLocal(snapA);
      expect(await dbB.getAllFavoriteWords(), isEmpty,
          reason: '对端的取消收藏必须把本机同键收藏删掉（此前永远删不掉）');
      final AggregateSnapshot snapB =
          await AggregateSyncService(dbB).materializeLocalSnapshot();
      expect(snapB.favoriteWordTombstones, hasLength(1),
          reason: 'B 落下墓碑后继续向第三台设备传播');
    });

    test('B 重收藏后 fold A 的旧墓碑：词存活（不被删除僵尸反杀）', () async {
      final FushiDatabase dbA = await _freshDb('agg_tomb_a2_');
      final FushiDatabase dbB = await _freshDb('agg_tomb_b2_');
      addTearDown(dbA.close);
      addTearDown(dbB.close);

      // A：收藏后取消（墓碑 deletedAt = t1）。
      await dbA.addFavoriteWord(
          expression: '言葉',
          reading: 'よみ',
          glossary: 'g',
          sourceType: 'book',
          dateKey: '2026-08-14');
      await dbA.removeFavoriteWord(
          expression: '言葉', reading: 'よみ', sourceType: 'book');
      final AggregateSnapshot snapA =
          await AggregateSyncService(dbA).materializeLocalSnapshot();

      // B：在 A 删除**之后**重新收藏（createdAt = now > t1；同毫秒平局也算收藏胜）。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await dbB.addFavoriteWord(
          expression: '言葉',
          reading: 'よみ',
          glossary: 'g',
          sourceType: 'book',
          dateKey: '2026-08-14');

      await AggregateSyncService(dbB).foldIntoLocal(snapA);
      expect(await dbB.getAllFavoriteWords(), hasLength(1),
          reason: '重收藏（createdAt 新于墓碑）必须存活');
    });
  });
}
