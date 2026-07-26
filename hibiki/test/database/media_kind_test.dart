import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// P5 MediaKind 枚举地基守卫：合集/书架 mediaType 值域的持久化串永不改变
/// （Never break userspace）。
///
/// - dbValue 集合钉死 {'epub','srt','video','game'}——任何人改枚举/加种类都会
///   在这里被拦下审视持久化影响；
/// - tryParse 对 null / ''（合集墓碑哨兵 [HibikiDatabase.collectionTombstoneSentinel]）
///   / 未知种类（对端未来值、旧值域 'book'/'srtbook'）一律返 null 不抛；
/// - compositeKey 与历史手写 `'<kind>|<entryKey>'` 插值逐字节一致
///   （`MediaCollections.coverSource` 有落库点依赖此格式）；
/// - typed DAO 落库后 DB 里 media_type 列仍是裸字符串（回归证明枚举化零串漂移）。
void main() {
  test('dbValue 集合守卫：恰为 {epub, srt, video, game}', () {
    expect(
      MediaKind.values.map((MediaKind k) => k.dbValue).toSet(),
      <String>{'epub', 'srt', 'video', 'game'},
    );
    // 显式钉每个成员的串（防有人调换赋值）。
    expect(MediaKind.epub.dbValue, 'epub');
    expect(MediaKind.srt.dbValue, 'srt');
    expect(MediaKind.video.dbValue, 'video');
    expect(MediaKind.game.dbValue, 'game');
  });

  test('tryParse 全分支：四个已知值命中，null/哨兵/未知返 null 不抛', () {
    expect(MediaKind.tryParse('epub'), MediaKind.epub);
    expect(MediaKind.tryParse('srt'), MediaKind.srt);
    expect(MediaKind.tryParse('video'), MediaKind.video);
    expect(MediaKind.tryParse('game'), MediaKind.game);
    expect(MediaKind.tryParse(null), isNull);
    expect(
        MediaKind.tryParse(HibikiDatabase.collectionTombstoneSentinel), isNull,
        reason: "'' 哨兵（合集级墓碑占位）不是种类");
    // 其它值域的字符串绝不误命中语义（'book' 是活动事件域、'srtbook' 是
    // Profile 绑定域），也涵盖对端未来新增的未知种类。
    expect(MediaKind.tryParse('book'), isNull);
    expect(MediaKind.tryParse('srtbook'), isNull);
    expect(MediaKind.tryParse('EPUB'), isNull, reason: '大小写敏感');
  });

  test('compositeKey 与历史手写插值逐字节一致', () {
    expect(MediaKind.epub.compositeKey('bookKey'), 'epub|bookKey');
    expect(MediaKind.srt.compositeKey('uid-1'), 'srt|uid-1');
    expect(MediaKind.video.compositeKey('video/ep1'), 'video|video/ep1');
    expect(MediaKind.game.compositeKey('1753400000000001'),
        'game|1753400000000001');
    // entryKey 原样拼接，不做任何转义（含 '|' 的键也照旧——与旧插值同语义）。
    expect(MediaKind.epub.compositeKey('a|b'), 'epub|a|b');
  });

  test('typed DAO 落库串不变：addToCollection(MediaKind.game) → DB 读回 game 串',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.game, 'g1');
    await db.addToCollection(c, MediaKind.epub, 'b1');
    await db.upsertShelfOrder(MediaKind.video, 'v1', 3);

    final List<MediaCollectionItemRow> items = await db.getCollectionItems(c);
    expect(
      items.map((MediaCollectionItemRow m) => m.mediaType).toList(),
      <String>['game', 'epub'],
      reason: 'media_collection_items.media_type 列仍是裸字符串',
    );
    final ShelfEntryRow shelf =
        (await db.getShelfEntry(MediaKind.video, 'v1'))!;
    expect(shelf.mediaType, 'video',
        reason: 'shelf_entries.media_type 列仍是裸字符串');

    // raw 版对未知种类原样透传（合并/转移路径的行为契约）。
    await db.addToCollectionRaw(c, 'book', 'legacy');
    final List<MediaCollectionItemRow> after = await db.getCollectionItems(c);
    expect(
      after.map((MediaCollectionItemRow m) => m.mediaType).toList(),
      <String>['game', 'epub', 'book'],
    );
  });
}
