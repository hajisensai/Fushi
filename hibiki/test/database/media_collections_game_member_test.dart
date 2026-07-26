import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 游戏进合集：mediaType='game' 走既有合集 DAO 的往返测试。
///
/// 合集成员表对 mediaType 是自由字符串（无 CHECK / 无 FK），本测试钉住 'game'
/// 成员的完整生命周期：加入（含墓碑清理路径）→ 读取 → 主折叠归属映射 → 移出
/// （移空自删）→ 删合集 cascade，全程与 epub/video 成员同一条 DAO 路径。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  test('addToCollection game 成员往返：写入 → 读取 → 归属映射', () async {
    final HibikiDatabase db = await _openDb();
    // 真实 galgames 行（entryKey = galgames.id，微秒时间戳字符串）。
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: '1753400000000001',
        name: 'ATRI',
        exePath: r'D:\games\atri\atri.exe',
        workdir: r'D:\games\atri',
        addedAt: 1753400000000,
        coverPath: const Value<String?>(null),
      ),
    );
    final int c = await db.createMediaCollection('ネコぱら全集');
    await db.addToCollection(c, MediaKind.game, '1753400000000001');
    await db.addToCollection(c, MediaKind.epub, 'book-1'); // 混合合集：书成员共存。

    final List<MediaCollectionItemRow> items = await db.getCollectionItems(c);
    expect(
      items
          .map((MediaCollectionItemRow m) => '${m.mediaType}|${m.entryKey}')
          .toList(),
      <String>['game|1753400000000001', 'epub|book-1'],
    );

    // 主折叠归属映射（游戏库分组用）按 'game|<id>' 键返回。
    final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
    expect(primary['game|1753400000000001'], c);

    // 幂等：重复加入不新增、不改序。
    await db.addToCollection(c, MediaKind.game, '1753400000000001');
    expect((await db.getCollectionItems(c)).length, 2);
  });

  test('removeFromCollection game 成员 → 移空自删 + 重加回不被墓碑吞', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('G');
    await db.addToCollection(c, MediaKind.game, 'g1');

    await db.removeFromCollection(c, MediaKind.game, 'g1');
    // 唯一成员移出 → 合集自删（与书/视频同语义）。
    expect(await db.getMediaCollectionById(c), isNull);

    // 重建同名合集再加回：addToCollection 自带墓碑清理，成员不被同步复活逻辑吞。
    final int c2 = await db.createMediaCollection('G');
    await db.addToCollection(c2, MediaKind.game, 'g1');
    expect((await db.getCollectionItems(c2)).single.mediaType, 'game');
  });

  test('deleteMediaCollection cascade 清 game 引用行，不动 galgames 本体', () async {
    final HibikiDatabase db = await _openDb();
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g-keep',
        name: 'keep',
        exePath: r'D:\g\keep.exe',
        workdir: r'D:\g',
        addedAt: 1,
      ),
    );
    final int c = await db.createMediaCollection('X');
    await db.addToCollection(c, MediaKind.game, 'g-keep');
    await db.deleteMediaCollection(c);

    expect(await db.getAllCollectionItems(), isEmpty);
    // 游戏本体行必须原样存活（合集只解链，绝不连带删游戏）。
    expect(
      (await db.getAllGalgames()).map((GalgameRow r) => r.id).toList(),
      <String>['g-keep'],
    );
  });
}
