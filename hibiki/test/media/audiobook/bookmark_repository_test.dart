import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  late HibikiDatabase db;
  late BookmarkRepository repo;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = BookmarkRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('stores bookmarks as rows and removes by stable id', () async {
    final first = Bookmark(
      sectionIndex: 1,
      normCharOffset: 1000,
      label: 'first',
      createdAt: DateTime.utc(2026, 5, 15, 1),
      ttuBookId: 7,
      bookTitle: 'Book',
    );
    final second = Bookmark(
      sectionIndex: 2,
      normCharOffset: 2000,
      label: 'second',
      createdAt: DateTime.utc(2026, 5, 15, 2),
      ttuBookId: 7,
      bookTitle: 'Book',
    );

    final int firstId = await repo.addBookmark(7, first);
    final int secondId = await repo.addBookmark(7, second);

    await repo.removeBookmarkById(secondId);
    final bookmarks = await repo.getBookmarks(7);

    expect(bookmarks, hasLength(1));
    expect(bookmarks.single.id, firstId);
    expect(bookmarks.single.label, 'first');
  });

  test('migrates legacy JSON preference and deletes source key', () async {
    // bookmarks.ttu_book_id is a FK to epub_books(id); a real legacy bookmark
    // belongs to an imported book, so seed the backing row.
    await db.customStatement(
      'INSERT INTO epub_books '
      '(id, title, epub_path, extract_dir, chapter_count, chapters_json, '
      'imported_at) VALUES (9, ?, ?, ?, 1, ?, 0)',
      ['Legacy Book', '/x.epub', '/x', '[]'],
    );
    final legacy = [
      Bookmark(
        sectionIndex: 3,
        normCharOffset: 3000,
        label: 'legacy',
        createdAt: DateTime.utc(2026, 5, 15, 3),
        ttuBookId: 9,
        bookTitle: 'Legacy Book',
      ).toJson(),
    ];
    await db.setPref('bookmarks_9', jsonEncode(legacy));

    await db.migrateLegacyBookmarkPreferences();
    final bookmarks = await repo.getBookmarks(9);

    expect(bookmarks, hasLength(1));
    expect(bookmarks.single.id, isNotNull);
    expect(bookmarks.single.label, 'legacy');
    expect(await db.getPref('bookmarks_9'), isNull);
  });

  test('cleans up legacy key even when bookmarks already exist', () async {
    final legacy = [
      Bookmark(
        sectionIndex: 3,
        normCharOffset: 3000,
        label: 'legacy',
        createdAt: DateTime.utc(2026, 5, 15, 3),
        ttuBookId: 9,
        bookTitle: 'Legacy Book',
      ).toJson(),
    ];
    await repo.addBookmark(
      9,
      Bookmark(
        sectionIndex: 3,
        normCharOffset: 3000,
        label: 'already migrated',
        createdAt: DateTime.utc(2026, 5, 15, 3),
      ),
    );
    await db.setPref('bookmarks_9', jsonEncode(legacy));

    await db.migrateLegacyBookmarkPreferences();

    expect(await db.getPref('bookmarks_9'), isNull);
    final bookmarks = await repo.getBookmarks(9);
    expect(bookmarks, hasLength(1));
    expect(bookmarks.single.label, 'already migrated');
  });

  test(
      'skips legacy bookmarks whose book is gone without aborting the '
      'migration (HBK-AUDIT-007)', () async {
    // Enforce FK exactly like production (_openDb sets foreign_keys = ON); the
    // shared in-memory db above runs with FK OFF. With FK ON, an INSERT OR
    // IGNORE of a bookmark whose ttu_book_id has no epub_books row hits a FK
    // violation (OR IGNORE does NOT suppress FK) and aborts the transaction.
    // The fix must skip the orphan before inserting so migration completes and
    // the source key is still cleaned.
    final fkDb = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(fkDb.close);
    final fkRepo = BookmarkRepository(fkDb);

    final legacy = [
      Bookmark(
        sectionIndex: 1,
        normCharOffset: 100,
        label: 'orphan',
        createdAt: DateTime.utc(2026, 5, 15, 4),
        ttuBookId: 42,
        bookTitle: 'Deleted Book',
      ).toJson(),
    ];
    await fkDb.setPref('bookmarks_42', jsonEncode(legacy));

    // Must not throw (pre-fix: FK violation aborts the whole migration).
    await fkDb.migrateLegacyBookmarkPreferences();

    expect(await fkRepo.getBookmarks(42), isEmpty);
    expect(await fkDb.getPref('bookmarks_42'), isNull);
  });
}
