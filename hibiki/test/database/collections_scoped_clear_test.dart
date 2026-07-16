import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 收藏夹「可选范围清空」的底层原语守卫：书签 / 收藏句 / 制卡句 / 收藏词四类各自
/// 有独立的批量清空入口，且**只删自己那类**——按类型勾选清空时互不牵连。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<void> _seedAll(HibikiDatabase db) async {
  // 书签。
  await BookmarkRepository(db).addBookmark(
    'book/边城',
    Bookmark(
      sectionIndex: 0,
      normCharOffset: 100,
      label: '题记',
      createdAt: DateTime(2026, 7, 16, 13, 20),
      bookKey: 'book/边城',
      bookTitle: '边城',
    ),
  );
  // 收藏句。
  await FavoriteSentenceRepository(db).add(
    FavoriteSentence(
      text: '至于文艺爱好者呢',
      bookTitle: '边城',
      createdAt: DateTime(2026, 7, 16, 13, 20),
      bookKey: 'book/边城',
    ),
  );
  // 制卡句。
  await db.addMinedSentence(
    source: 'book',
    dateKey: '2026-07-16',
    expression: '文艺',
    sentence: '至于文艺爱好者呢',
    documentTitle: '边城',
  );
  // 收藏词。
  await db.addFavoriteWord(
    expression: '文艺',
    reading: 'ぶんげい',
    glossary: 'literature and art',
    sourceType: 'book',
    dateKey: '2026-07-16',
  );
}

Future<({int bookmarks, int sentences, int mined, int words})> _counts(
    HibikiDatabase db) async {
  return (
    bookmarks: (await BookmarkRepository(db).getAllBookmarks()).length,
    sentences: (await FavoriteSentenceRepository(db).getAll()).length,
    mined: (await db.getAllMinedSentences()).length,
    words: (await db.getAllFavoriteWords()).length,
  );
}

void main() {
  test('每类清空原语只删自己那类，不牵连其它三类', () async {
    final HibikiDatabase db = await _openDb();

    // 清书签：只书签归零。
    await _seedAll(db);
    await BookmarkRepository(db).clearAllBookmarks();
    var c = await _counts(db);
    expect(c.bookmarks, 0);
    expect(c.sentences, 1);
    expect(c.mined, 1);
    expect(c.words, 1);

    // 清收藏句：只收藏句归零。
    await _seedAll(db); // 复位（书签重新写回，其余各 +1 → 制卡/词幂等或累加见下）。
    await FavoriteSentenceRepository(db).clear();
    expect((await FavoriteSentenceRepository(db).getAll()), isEmpty);
    expect((await BookmarkRepository(db).getAllBookmarks()), isNotEmpty);

    // 清收藏词：只收藏词归零（幂等唯一键，重复 seed 不增行）。
    await db.clearAllFavoriteWords();
    expect((await db.getAllFavoriteWords()), isEmpty);
    expect((await db.getAllMinedSentences()), isNotEmpty);

    // 清制卡句：只制卡句归零。
    await db.clearMinedSentences();
    expect((await db.getAllMinedSentences()), isEmpty);
  });

  test('collections_page 清空按钮走可选范围面板（非制卡专用），覆盖四类型', () {
    final String src =
        File('lib/src/pages/implementations/collections_page.dart')
            .readAsStringSync();
    // 门控改为列表非空即显示，旧的「仅制卡才显示」getter 已移除。
    expect(src, contains('if (!_loading && _items.isNotEmpty)'));
    expect(src.contains('_hasMinedItems'), isFalse,
        reason: '旧的仅制卡门控 getter 应已被可选范围清空取代');
    // 打开可选范围面板 + 面板 widget 存在。
    expect(src, contains('_openClearSheet'));
    expect(src, contains('class _ClearSheet'));
    // 面板走 MD3 外壳。
    expect(src, contains('HibikiModalSheetFrame('));
    // 四类型都能被清空（executor 覆盖四种 _CollectionType）。
    expect(src, contains('_clearScopes('));
    expect(src, contains('clearAllBookmarks()'));
    expect(src, contains('FavoriteSentenceRepository(db).clear()'));
    expect(src, contains('clearMinedSentences()'));
    expect(src, contains('clearAllFavoriteWords()'));
    // 破坏性操作有二次确认。
    expect(src, contains('CollectionDeleteDialog('));
    expect(src, contains('t.collection_clear_confirm'));
  });
}
