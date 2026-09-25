import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

/// 卡片「跳回原文」按链接找本机书：链接里的 uid 是制卡那台设备导入时生成的机器
/// 局域身份，经 Fushi 同步 / 互联到另一台设备的同一本书会重新导入、拿到新 uid——
/// 只按 uid 查就「跳不回去」。回落到跨设备身份 bookKey 才能找到同步来的副本。
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const String bookKey = '無職転生 ～異世界行ったら本気だす～ 25 (MFブックス)';

  Future<String> insertBook(String key) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/$key.epub',
        extractDir: '/$key',
        chapterCount: 5,
        chaptersJson: '[]',
        importedAt: 1000,
      ),
    );
    return (await db.resolveEpubBookUid(key))!;
  }

  CardSourceLink link({required String uid, String? key}) => CardSourceLink(
    kind: CardSourceKind.book,
    uid: uid,
    bookKey: key,
    sourceId: CardSourceLink.newSourceId(),
    chapterIndex: 1,
    charOffset: 10,
  );

  test('另一台设备制的卡：uid 本机不存在，按 bookKey 找到同步来的书', () async {
    final String localUid = await insertBook(bookKey);
    final EpubBookRow? row = await resolveCardSourceBook(
      db,
      link(uid: 'book_1790000000000000_7', key: bookKey),
    );
    expect(row, isNotNull);
    expect(row!.uid, localUid);
    expect(row.bookKey, bookKey);
  });

  test('本机制的卡优先按 uid：本机改名后 bookKey 变了仍能回跳', () async {
    final String localUid = await insertBook(bookKey);
    final EpubBookRow? row = await resolveCardSourceBook(
      db,
      link(uid: localUid, key: 'renamed elsewhere'),
    );
    expect(row?.uid, localUid);
  });

  test('旧链接没有 bookKey 且 uid 不在本机：返回 null（提示媒体缺失）', () async {
    await insertBook(bookKey);
    expect(
      await resolveCardSourceBook(db, link(uid: 'book_foreign_1')),
      isNull,
    );
  });
}
