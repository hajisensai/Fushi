import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';

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
}
