import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';

/// v115：`galgames.completed_at`（排行榜「读完时刻」）只由 DB 层一处判据
/// [resolveGalgameCompletedAt] 维护：进入「玩过」写当前时刻、保持不动、离开清空。
void main() {
  group('resolveGalgameCompletedAt（纯函数）', () {
    test('进入玩过写 now，保持玩过原值不动（含 null），离开清空', () {
      expect(
        resolveGalgameCompletedAt(
          previousStatus: 3,
          previousCompletedAt: null,
          nextStatus: 2,
          now: 100,
        ),
        100,
      );
      expect(
        resolveGalgameCompletedAt(
          previousStatus: 2,
          previousCompletedAt: 50,
          nextStatus: 2,
          now: 100,
        ),
        50,
      );
      expect(
        resolveGalgameCompletedAt(
          previousStatus: 2,
          previousCompletedAt: null,
          nextStatus: 2,
          now: 100,
        ),
        isNull,
        reason: '迁移回填不出日期的存量「玩过」保持日期未知',
      );
      expect(
        resolveGalgameCompletedAt(
          previousStatus: 2,
          previousCompletedAt: 50,
          nextStatus: 4,
          now: 100,
        ),
        isNull,
      );
      expect(
        resolveGalgameCompletedAt(
          previousStatus: 1,
          previousCompletedAt: null,
          nextStatus: 3,
          now: 100,
        ),
        isNull,
      );
    });
  });

  group('DB 写入口', () {
    late FushiDatabase db;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G1',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
    });

    tearDown(() => db.close());

    test('setGalgamePlayStatus 维护 completedAt', () async {
      await db.setGalgamePlayStatus('g1', 3, now: 10);
      expect((await db.getGalgame('g1'))!.completedAt, isNull);

      await db.setGalgamePlayStatus('g1', 2, now: 20);
      expect((await db.getGalgame('g1'))!.completedAt, 20);

      await db.setGalgamePlayStatus('g1', 2, now: 30);
      expect(
        (await db.getGalgame('g1'))!.completedAt,
        20,
        reason: '重设同一状态不刷新完成时刻',
      );

      await db.setGalgamePlayStatus('g1', 4, now: 40);
      final GalgameRow row = (await db.getGalgame('g1'))!;
      expect(row.playStatus, 4);
      expect(row.completedAt, isNull);

      expect(await db.setGalgamePlayStatus('nope', 2), 0);
    });

    test('upsertGalgame 按旧行重算，调用方给的 completedAt 不生效', () async {
      final int before = DateTime.now().millisecondsSinceEpoch;
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G1',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
          playStatus: const Value<int>(2),
          completedAt: const Value<int?>(1),
        ),
      );
      final int? first = (await db.getGalgame('g1'))!.completedAt;
      expect(first, isNotNull);
      expect(first!, greaterThanOrEqualTo(before));

      // 整行覆写保持「玩过」：原值不动。
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G1 renamed',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
          playStatus: const Value<int>(2),
        ),
      );
      expect((await db.getGalgame('g1'))!.completedAt, first);

      // 不带 playStatus 的覆写：列不动，调用方的 completedAt 也不落。
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G1 again',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
          completedAt: const Value<int?>(7),
        ),
      );
      expect((await db.getGalgame('g1'))!.completedAt, first);

      // 离开「玩过」清空。
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G1',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
          playStatus: const Value<int>(5),
        ),
      );
      expect((await db.getGalgame('g1'))!.completedAt, isNull);
    });

    test('新行直接以「玩过」写入也记完成时刻', () async {
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g2',
          name: 'G2',
          exePath: '/g/2.exe',
          workdir: '/g',
          addedAt: 0,
          playStatus: const Value<int>(2),
        ),
      );
      expect((await db.getGalgame('g2'))!.completedAt, isNotNull);
    });
  });

  group('GalgameRepository（真实调用路径）', () {
    late FushiDatabase db;
    late GalgameRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = GalgameRepository(db);
      await repo.addAll(<GalgameEntry>[
        GalgameEntry(
          id: 'g1',
          name: 'G1',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: DateTime(2026),
        ),
      ]);
    });

    tearDown(() => db.close());

    test('setPlayStatus / updateEntry 都经同一判据', () async {
      await repo.setPlayStatus('g1', GalgamePlayStatus.played);
      final int? completedAt = (await db.getGalgame('g1'))!.completedAt;
      expect(completedAt, isNotNull);

      // 详情页整行覆写（改名，状态仍是玩过）不刷新完成时刻。
      await repo.updateEntry(repo.byId('g1')!.copyWith(name: 'renamed'));
      expect((await db.getGalgame('g1'))!.completedAt, completedAt);

      // 列表整表覆写把状态改走：清空。
      await repo.setGames(<GalgameEntry>[
        repo.byId('g1')!.copyWith(playStatus: GalgamePlayStatus.onHold),
      ]);
      expect((await db.getGalgame('g1'))!.completedAt, isNull);
    });
  });
}
