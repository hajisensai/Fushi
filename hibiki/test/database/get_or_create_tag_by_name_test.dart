import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1165：getOrCreateTagByName 是跨设备按名重建标签映射的核心原语。
/// 契约：命中同名返回既有 id（幂等，不建重复行）；未命中新建并返回 id。
void main() {
  Future<HibikiDatabase> openDb() async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  group('getOrCreateTagByName', () {
    test('空库首次调用新建标签并返回 id', () async {
      final HibikiDatabase db = await openDb();
      final int id = await db.getOrCreateTagByName('日语');
      expect(id, greaterThan(0));
      final List<BookTagRow> all = await db.getAllTags();
      expect(all, hasLength(1));
      expect(all.single.name, '日语');
      expect(all.single.id, id);
    });

    test('重复同名幂等：不建重复标签、始终返回同一 id', () async {
      final HibikiDatabase db = await openDb();
      final int first = await db.getOrCreateTagByName('N1');
      final int second = await db.getOrCreateTagByName('N1');
      final int third = await db.getOrCreateTagByName('N1');
      expect(second, first);
      expect(third, first);
      expect(await db.getAllTags(), hasLength(1));
    });

    test('命中 createTag 已建的同名标签返回其既有 id', () async {
      final HibikiDatabase db = await openDb();
      final int created = await db.createTag('小说', 0xFF112233);
      final int fetched = await db.getOrCreateTagByName('小说');
      expect(fetched, created);
      final List<BookTagRow> all = await db.getAllTags();
      expect(all, hasLength(1));
      // 命中不改色值（仅取或建，不覆盖既有属性）。
      expect(all.single.colorValue, 0xFF112233);
    });

    test('并发同名 get-or-create 都不抛、返回同一 id、只建一行（竞态守卫）', () async {
      final HibikiDatabase db = await openDb();
      // 逼近两条下载流交错：三个同名调用一并发出（不在中间 await），旧的
      // select-then-insert 实现会 A/B 都 select 到 null、第二个 insert 撞 UNIQUE 抛；
      // 原子 insertOrIgnore 实现下全部成功且归一到同一 id。
      final List<int> ids = await Future.wait<int>(<Future<int>>[
        db.getOrCreateTagByName('并发'),
        db.getOrCreateTagByName('并发'),
        db.getOrCreateTagByName('并发'),
      ]);
      expect(ids.toSet(), hasLength(1));
      final List<BookTagRow> all = await db.getAllTags();
      expect(all, hasLength(1));
      expect(all.single.name, '并发');
      expect(all.single.id, ids.first);
    });

    test('不同名分别新建、各自独立 id', () async {
      final HibikiDatabase db = await openDb();
      final int a = await db.getOrCreateTagByName('A');
      final int b = await db.getOrCreateTagByName('B');
      expect(a, isNot(b));
      final Set<String> names =
          (await db.getAllTags()).map((BookTagRow t) => t.name).toSet();
      expect(names, <String>{'A', 'B'});
    });
  });
}
