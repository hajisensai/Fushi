import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// 标签管理「合并到…」：源标签在五种宿主下的映射全部改挂到目标标签，源标签删除；
/// 「排序」落 sortOrder 后 getAllTags 按新序返回。
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('mergeTagInto 把源标签的书 / 字幕书 / 视频 / 游戏 / 合集映射搬到目标并删除源',
      () async {
    final int source = await db.createTag('源', 0xFFEF5350);
    final int target = await db.createTag('目标', 0xFF42A5F5);
    final int cid = await db.createMediaCollection('合集');
    await db.addTagToBook('b1', source);
    await db.addTagToSrtBook('s1', source);
    await db.addTagToVideoBook('v1', source);
    await db.addTagToGame('g1', source);
    await db.addTagToCollection(cid, source);
    // 已挂目标的条目合并后不重复。
    await db.addTagToBook('b2', source);
    await db.addTagToBook('b2', target);

    await mergeTagInto(db, sourceId: source, targetId: target);

    final List<BookTagRow> all = await db.getAllTags();
    expect(all.map((BookTagRow t) => t.id), <int>[target]);
    Future<List<int>> ids(Future<List<BookTagRow>> f) async =>
        (await f).map((BookTagRow t) => t.id).toList();
    expect(await ids(db.getTagsForBook('b1')), <int>[target]);
    expect(await ids(db.getTagsForBook('b2')), <int>[target]);
    expect(await ids(db.getTagsForSrtBook('s1')), <int>[target]);
    expect(await ids(db.getTagsForVideoBook('v1')), <int>[target]);
    expect(await ids(db.getTagsForGame('g1')), <int>[target]);
    expect(await ids(db.getTagsForCollection(cid)), <int>[target]);
  });

  test('reorderTags 落 sortOrder，getAllTags 按新序返回', () async {
    final int a = await db.createTag('A', 0xFFEF5350);
    final int b = await db.createTag('B', 0xFF42A5F5);
    final int c = await db.createTag('C', 0xFF66BB6A);
    await db.reorderTags(<int>[c, a, b]);
    expect((await db.getAllTags()).map((BookTagRow t) => t.id), <int>[c, a, b]);
  });
}
