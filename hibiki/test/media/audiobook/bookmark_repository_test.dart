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
      bookKey: 'Book',
      bookTitle: 'Book',
    );
    final second = Bookmark(
      sectionIndex: 2,
      normCharOffset: 2000,
      label: 'second',
      createdAt: DateTime.utc(2026, 5, 15, 2),
      bookKey: 'Book',
      bookTitle: 'Book',
    );

    final int firstId = await repo.addBookmark('Book', first);
    final int secondId = await repo.addBookmark('Book', second);

    await repo.removeBookmarkById(secondId);
    final bookmarks = await repo.getBookmarks('Book');

    expect(bookmarks, hasLength(1));
    expect(bookmarks.single.id, firstId);
    expect(bookmarks.single.label, 'first');
  });

  test('per-book legacy JSON preference drains into rows and is removed',
      () async {
    // The instance-level drainer (_migrateLegacyBookmarks) keys on
    // `bookmarks_<bookKey>` and runs on first getBookmarks(bookKey).
    final legacy = [
      Bookmark(
        sectionIndex: 3,
        normCharOffset: 3000,
        label: 'legacy',
        createdAt: DateTime.utc(2026, 5, 15, 3),
        bookKey: 'Legacy Book',
        bookTitle: 'Legacy Book',
      ).toJson(),
    ];
    await db.setPref('bookmarks_Legacy Book', jsonEncode(legacy));

    final bookmarks = await repo.getBookmarks('Legacy Book');

    expect(bookmarks, hasLength(1));
    expect(bookmarks.single.id, isNotNull);
    expect(bookmarks.single.label, 'legacy');
    expect(await db.getPref('bookmarks_Legacy Book'), isNull);
  });

  test('cleans up legacy key even when bookmarks already exist', () async {
    final legacy = [
      Bookmark(
        sectionIndex: 3,
        normCharOffset: 3000,
        label: 'legacy',
        createdAt: DateTime.utc(2026, 5, 15, 3),
        bookKey: 'Legacy Book',
        bookTitle: 'Legacy Book',
      ).toJson(),
    ];
    await repo.addBookmark(
      'Legacy Book',
      Bookmark(
        sectionIndex: 3,
        normCharOffset: 3000,
        label: 'already migrated',
        createdAt: DateTime.utc(2026, 5, 15, 3),
      ),
    );
    await db.setPref('bookmarks_Legacy Book', jsonEncode(legacy));

    final bookmarks = await repo.getBookmarks('Legacy Book');

    expect(await db.getPref('bookmarks_Legacy Book'), isNull);
    expect(bookmarks, hasLength(1));
    expect(bookmarks.single.label, 'already migrated');
  });
}
