import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-1113「游戏没有标签」：游戏 ↔ 共享 `book_tags` 标签池的映射表（v57）。
///
/// 这套测试钉的是**上层筛选栏 / 标签管理页早已共用、唯独游戏接不进来**的那个缺口：
/// 游戏必须与书 / 字幕书 / 视频走同一个标签池、同一套 AND 语义筛选、同一份计数。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// 真实文件库：`HibikiDatabase(dir)` 才会走 `PRAGMA foreign_keys = ON`，
/// cascade 断言必须用这个（内存 forTesting 不开外键）。
Future<HibikiDatabase> _openRealDb() async {
  final Directory dir =
      await Directory.systemTemp.createTemp('hibiki_galgame_tags_test_');
  addTearDown(() async => dir.delete(recursive: true));
  final HibikiDatabase db = HibikiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<String> _insertGame(HibikiDatabase db, String id) async {
  await db.upsertGalgame(GalgamesCompanion.insert(
    id: id,
    name: id,
    exePath: 'Z:\\vn\\$id.exe',
    workdir: 'Z:\\vn',
    addedAt: 1700000000000,
  ));
  return id;
}

void main() {
  group('游戏标签 CRUD', () {
    test('加标签后可读回，且与书/视频共用同一个标签池', () async {
      final HibikiDatabase db = await _openDb();
      final String game = await _insertGame(db, 'g1');
      final int tagId = await db.createTag('神作', 0xFFEF5350);

      await db.addTagToGame(game, tagId);

      final List<BookTagRow> tags = await db.getTagsForGame(game);
      expect(tags, hasLength(1));
      expect(tags.single.id, tagId, reason: '标签定义来自共享 book_tags，不是游戏私有表');
      expect(tags.single.name, '神作');
      expect(tags.single.colorValue, 0xFFEF5350);
    });

    test('重复 addTagToGame 幂等（撞 {gameId, tagId} UNIQUE 不抛、不重复行）', () async {
      final HibikiDatabase db = await _openDb();
      final String game = await _insertGame(db, 'g1');
      final int tagId = await db.createTag('神作', 0xFF000000);

      await db.addTagToGame(game, tagId);
      await db.addTagToGame(game, tagId);

      expect(await db.getTagsForGame(game), hasLength(1));
      expect(await db.getAllGameTagMappings(), hasLength(1));
    });

    test('removeTagFromGame 只摘这一条，同标签的其它游戏不受影响', () async {
      final HibikiDatabase db = await _openDb();
      final String a = await _insertGame(db, 'g1');
      final String b = await _insertGame(db, 'g2');
      final int tagId = await db.createTag('神作', 0xFF000000);
      await db.addTagToGame(a, tagId);
      await db.addTagToGame(b, tagId);

      await db.removeTagFromGame(a, tagId);

      expect(await db.getTagsForGame(a), isEmpty);
      expect(await db.getTagsForGame(b), hasLength(1));
    });

    test('setTagsForGame 按差集增删（不整表重建，不动其它游戏）', () async {
      final HibikiDatabase db = await _openDb();
      final String game = await _insertGame(db, 'g1');
      final String other = await _insertGame(db, 'g2');
      final int keep = await db.createTag('保留', 0xFF000000);
      final int drop = await db.createTag('移除', 0xFF000001);
      final int add = await db.createTag('新增', 0xFF000002);
      await db.addTagToGame(game, keep);
      await db.addTagToGame(game, drop);
      await db.addTagToGame(other, drop);

      await db.setTagsForGame(game, <int>{keep, add});

      expect(
        (await db.getTagsForGame(game)).map((BookTagRow t) => t.id).toSet(),
        <int>{keep, add},
      );
      expect((await db.getTagsForGame(other)).single.id, drop,
          reason: '差集更新只作用于目标游戏');
    });

    test('setTagsForGame 传空集 = 清空该游戏全部标签', () async {
      final HibikiDatabase db = await _openDb();
      final String game = await _insertGame(db, 'g1');
      await db.addTagToGame(game, await db.createTag('a', 0xFF000000));
      await db.addTagToGame(game, await db.createTag('b', 0xFF000001));

      await db.setTagsForGame(game, <int>{});

      expect(await db.getTagsForGame(game), isEmpty);
    });
  });

  group('AND 语义筛选（getGameIdsForAllTags）', () {
    test('只返回同时含全部选中标签的游戏', () async {
      final HibikiDatabase db = await _openDb();
      final String both = await _insertGame(db, 'both');
      final String onlyA = await _insertGame(db, 'onlyA');
      await _insertGame(db, 'none');
      final int a = await db.createTag('A', 0xFF000000);
      final int b = await db.createTag('B', 0xFF000001);
      await db.addTagToGame(both, a);
      await db.addTagToGame(both, b);
      await db.addTagToGame(onlyA, a);

      expect(await db.getGameIdsForAllTags(<int>{a}), <String>{both, onlyA});
      expect(await db.getGameIdsForAllTags(<int>{a, b}), <String>{both},
          reason: 'AND 而非 OR：与书架 getBookKeysForAllTags 同语义');
    });

    test('空标签集返回空集（调用方据此判定「不过滤」）', () async {
      final HibikiDatabase db = await _openDb();
      final String game = await _insertGame(db, 'g1');
      await db.addTagToGame(game, await db.createTag('A', 0xFF000000));

      expect(await db.getGameIdsForAllTags(<int>{}), isEmpty);
    });
  });

  group('外键 cascade（真实库，foreign_keys=ON）', () {
    test('删游戏自动清掉它的标签映射，不留孤儿', () async {
      final HibikiDatabase db = await _openRealDb();
      final String game = await _insertGame(db, 'g1');
      final int tagId = await db.createTag('神作', 0xFF000000);
      await db.addTagToGame(game, tagId);

      await db.deleteGalgame(game);

      expect(await db.getAllGameTagMappings(), isEmpty);
      expect((await db.getAllTags()).single.id, tagId,
          reason: '删游戏不该连坐删掉共享标签池里的标签');
    });

    test('删标签自动清掉全部游戏上的该标签映射', () async {
      final HibikiDatabase db = await _openRealDb();
      final String a = await _insertGame(db, 'g1');
      final String b = await _insertGame(db, 'g2');
      final int tagId = await db.createTag('神作', 0xFF000000);
      await db.addTagToGame(a, tagId);
      await db.addTagToGame(b, tagId);

      await db.deleteTag(tagId);

      expect(await db.getAllGameTagMappings(), isEmpty);
      expect(await db.getGalgame(a), isNotNull, reason: '删标签不该连坐删游戏');
      expect(await db.getGalgame(b), isNotNull);
    });
  });

  group('标签管理页统计（countBooksForTag）', () {
    test('游戏计入总数，与 EPUB / 视频相加不重不漏', () async {
      final HibikiDatabase db = await _openDb();
      final int tagId = await db.createTag('神作', 0xFF000000);

      expect(await db.countBooksForTag(tagId), 0);

      await db.addTagToGame(await _insertGame(db, 'g1'), tagId);
      expect(await db.countBooksForTag(tagId), 1,
          reason: 'BUG-1113：只给游戏打的标签在管理页不能恒显示 0');

      await db.addTagToGame(await _insertGame(db, 'g2'), tagId);
      expect(await db.countBooksForTag(tagId), 2);

      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'book-1',
        title: 'book-1',
        epubPath: '/tmp/book-1.epub',
        extractDir: '/tmp/book-1',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1700000000000,
      ));
      await db.addTagToBook('book-1', tagId);
      expect(await db.countBooksForTag(tagId), 3, reason: '四种媒体互不重叠，直接相加');
    });
  });
}
