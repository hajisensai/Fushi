import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1542 DB 层守卫：**真的往库里写多条播放记录**，再按合集成员顺序跑
/// [continueMemberIndex]，断言续播落在「用户最近一次退出的那一集」。
///
/// 为什么守在 DB 层而不是只守纯函数：这个 bug 的根因跨两层——`VideoBooks` 缺时刻
/// 列（数据结构）+ 选条目层只能拿位置当代理（算法）。纯函数单测喂什么就断什么，
/// 证明不了「写进度这个动作真的把时刻落库了」。这里从
/// [FushiDatabase.updateVideoBookPosition] 这个**唯一写入口**进，出来再读行，把
/// 「写—存—选」整条链焊死：谁把 `lastPlayedAt` 从写入路径里摘掉，这里立刻红。
///
/// `NativeDatabase.memory()` 默认**关**外键，而生产连接经 applyPragmas 开着；
/// 合集成员表对 `media_collections` 有 FK cascade，不开就测不到真实约束。
void main() {
  FushiDatabase openDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (dynamic rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  /// 往库里塞一个 [count] 集的合集，返回按 sortIndex 排好的成员 uid。
  Future<List<String>> seedCollection(
    FushiDatabase db, {
    required int count,
  }) async {
    final int collectionId = await db.createMediaCollection('響け！ユーフォニアム');
    final List<String> uids = <String>[];
    for (int i = 0; i < count; i++) {
      final String uid = 'video/ep$i';
      uids.add(uid);
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>('第 ${i + 1} 集'),
        videoPath: Value<String>('/abs/ep$i.mkv'),
      ));
      await db.upsertCollectionItemAt(
        collectionId,
        MediaKind.video.dbValue,
        uid,
        i,
      );
    }
    return uids;
  }

  /// 按合集成员顺序读回行，跑真选择器。
  Future<int> resumeIndex(FushiDatabase db, List<String> uids) async {
    final List<CollectionMemberProgress> members = <CollectionMemberProgress>[];
    for (final String uid in uids) {
      final VideoBookRow? row = await db.getVideoBookByBookUid(uid);
      expect(row, isNotNull, reason: '成员 $uid 应在库里');
      members.add(CollectionMemberProgress(
        positionMs: row!.lastPositionMs,
        completed: row.completedAt != null,
        lastPlayedAt: row.lastPlayedAt,
      ));
    }
    return continueMemberIndex(members);
  }

  test('写进度即写时刻：updateVideoBookPosition 落 lastPlayedAt', () async {
    final FushiDatabase db = openDb();
    final List<String> uids = await seedCollection(db, count: 3);

    expect(
      (await db.getVideoBookByBookUid(uids[0]))!.lastPlayedAt,
      isNull,
      reason: '从未播放的行不该凭空有时刻',
    );

    await db.updateVideoBookPosition(uids[0], 24000, playedAt: 1700000000);
    final VideoBookRow row = (await db.getVideoBookByBookUid(uids[0]))!;
    expect(row.lastPositionMs, 24000);
    expect(row.lastPlayedAt, 1700000000, reason: '位置与时刻必须成对落库，否则选条目层又只剩位置可猜');
  });

  test('用户实报形状：回头看靠前的一集 → 续播落在刚退出那集，不落末集', () async {
    final FushiDatabase db = openDb();
    // 用户库是 234 集；这里用 8 集复现同一形状（末集有陈旧痕迹）。
    final List<String> uids = await seedCollection(db, count: 8);

    // 很久以前：看完第 1~2 集，并在末集留下一点陈旧进度（旧口径的“锚点”）。
    await db.updateVideoBookPosition(uids[0], 1400000, playedAt: 1000);
    await db.markVideoCompleted(uids[0], DateTime(2026, 1, 1));
    await db.updateVideoBookPosition(uids[1], 1400000, playedAt: 2000);
    await db.markVideoCompleted(uids[1], DateTime(2026, 1, 2));
    await db.updateVideoBookPosition(uids[7], 19000, playedAt: 3000);

    // 刚刚：回头点开第 3 集（PV 那种），看到 0:24 就退出。
    await db.updateVideoBookPosition(uids[2], 24000, playedAt: 9000000);

    expect(
      await resumeIndex(db, uids),
      2,
      reason: '续播必须落在最近一次退出的那一集，而不是位置最靠后的陈旧痕迹（末集）',
    );
  });

  test('最近一次刚好把某集看完 → 推进下一集（收尾语义不被削掉）', () async {
    final FushiDatabase db = openDb();
    final List<String> uids = await seedCollection(db, count: 5);

    await db.updateVideoBookPosition(uids[3], 500, playedAt: 1000);
    await db.updateVideoBookPosition(uids[1], 1400000, playedAt: 9000000);
    await db.markVideoCompleted(uids[1], DateTime(2026, 1, 2));

    expect(await resumeIndex(db, uids), 2);
  });

  test('远端进度回灌用对端时刻：不冒充成本机刚看的', () async {
    final FushiDatabase db = openDb();
    final List<String> uids = await seedCollection(db, count: 4);

    // 本机刚看第 1 集。
    await db.updateVideoBookPosition(uids[0], 24000, playedAt: 9000000);
    // 同步把对端三天前的第 4 集进度回灌进来（传的是对端时刻，不是 now）。
    await db.updateVideoBookPosition(uids[3], 600000, playedAt: 8000000);

    expect(
      await resumeIndex(db, uids),
      0,
      reason: '回灌若戳 now，锚点会被拽到用户根本没在看的那一集',
    );
  });

  test('整个合集从没播过 → 从第 0 集开始', () async {
    final FushiDatabase db = openDb();
    final List<String> uids = await seedCollection(db, count: 4);
    expect(await resumeIndex(db, uids), 0);
  });
}
