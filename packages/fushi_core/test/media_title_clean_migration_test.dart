import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// BUG：media-title-crc-suffix-not-cleaned。视频标题是显示名（身份是 book_uid），
/// 写入单点 [FushiDatabase.upsertVideoBook] 与 v172 迁移都过 [cleanImportedTitle]；
/// epub_books.title 是身份（bookKey / 统计 / 同步键），迁移绝不改写。
const String _dirtyVideo = '[Group] Show - 01 [1080p][ABCD1234].mkv';
const String _cleanVideo = '[Group] Show - 01 [1080p]';
const String _dirtyBook = '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 2 [e0914585]';

Future<void> _insertEpub(FushiDatabase db, String title) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/x.epub',
    extractDir: '/x',
    chapterCount: 0,
    chaptersJson: '[]',
    importedAt: 0,
  ),
);

Future<String> _title(FushiDatabase db, String bookUid) async =>
    (await db.getVideoBookByBookUid(bookUid))!.title;

void main() {
  test('upsertVideoBook 写入时清洗标题（插入与冲突更新两条路）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'v1',
        title: _dirtyVideo,
        videoPath: '/v1.mkv',
      ),
    );
    expect(await _title(db, 'v1'), _cleanVideo);

    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'v1',
        title: 'Movie (2019) (DEADBEEF)',
        videoPath: '/v1.mkv',
      ),
    );
    expect(await _title(db, 'v1'), 'Movie (2019)');
  });

  test('用户改名（updateVideoBookTitle）原样写，不清洗', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(bookUid: 'v1', title: 'A', videoPath: '/a'),
    );
    await db.updateVideoBookTitle('v1', 'My name [12345678]');
    expect(await _title(db, 'v1'), 'My name [12345678]');
  });

  test('v172 迁移清洗存量视频标题、幂等，书名不动', () async {
    final Directory dir = Directory.systemTemp.createTempSync('title_clean');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File file = File('${dir.path}/fushi.db');

    final FushiDatabase seeded = FushiDatabase.forTesting(NativeDatabase(file));
    await seeded.upsertVideoBook(
      VideoBooksCompanion.insert(bookUid: 'v1', title: 'x', videoPath: '/1'),
    );
    await seeded.upsertVideoBook(
      VideoBooksCompanion.insert(bookUid: 'v2', title: 'x', videoPath: '/2'),
    );
    await seeded.upsertVideoBook(
      VideoBooksCompanion.insert(bookUid: 'v3', title: 'x', videoPath: '/3'),
    );
    // 模拟 v172 之前入库的原始文件名标题（绕过写入单点）。
    Future<void> raw(String uid, String title) => seeded.customStatement(
      'UPDATE video_books SET title = ? WHERE book_uid = ?',
      <Object>[title, uid],
    );
    await raw('v1', _dirtyVideo);
    await raw('v2', '[ABCD1234]');
    await raw('v3', '86');
    await _insertEpub(seeded, _dirtyBook);
    await seeded.customStatement(
      'PRAGMA user_version = ${kFushiDbSchemaVersion - 1}',
    );
    await seeded.close();

    final FushiDatabase upgraded = FushiDatabase.forTesting(
      NativeDatabase(file),
    );
    addTearDown(upgraded.close);
    expect(await _title(upgraded, 'v1'), _cleanVideo);
    // 清空了就保留原名。
    expect(await _title(upgraded, 'v2'), '[ABCD1234]');
    expect(await _title(upgraded, 'v3'), '86');
    // 书名是身份：迁移不改。
    final List<QueryRow> books = await upgraded
        .customSelect('SELECT title, book_key FROM epub_books')
        .get();
    expect(books.single.read<String>('title'), _dirtyBook);
    expect(books.single.read<String>('book_key'), _dirtyBook);
    // 幂等：再跑一遍没有可改的行。
    expect(await upgraded.cleanStoredVideoBookTitles(), 0);
  });
}
