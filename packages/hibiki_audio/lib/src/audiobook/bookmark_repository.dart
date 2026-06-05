import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:hibiki_core/hibiki_core.dart';

class Bookmark {
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as int?,
        sectionIndex: json['sectionIndex'] as int,
        normCharOffset: json['normCharOffset'] as int,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        bookKey: json['bookKey'] as String?,
        bookTitle: json['bookTitle'] as String?,
        pageInChapter: json['pageInChapter'] as int?,
        totalPagesInChapter: json['totalPagesInChapter'] as int?,
      );
  Bookmark({
    required this.sectionIndex,
    required this.normCharOffset,
    required this.label,
    required this.createdAt,
    this.id,
    this.bookKey,
    this.bookTitle,
    this.pageInChapter,
    this.totalPagesInChapter,
  });

  factory Bookmark.fromRow(BookmarkRow row) => Bookmark(
        id: row.id,
        sectionIndex: row.sectionIndex,
        normCharOffset: row.normCharOffset,
        label: row.label,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
        bookKey: row.bookKey,
        bookTitle: row.bookTitle,
        pageInChapter: row.pageInChapter,
        totalPagesInChapter: row.totalPagesInChapter,
      );

  final int? id;
  final int sectionIndex;
  final int normCharOffset;
  final String label;
  final DateTime createdAt;
  final String? bookKey;
  final String? bookTitle;
  final int? pageInChapter;
  final int? totalPagesInChapter;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'sectionIndex': sectionIndex,
        'normCharOffset': normCharOffset,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
        if (bookKey != null) 'bookKey': bookKey,
        if (bookTitle != null) 'bookTitle': bookTitle,
        if (pageInChapter != null) 'pageInChapter': pageInChapter,
        if (totalPagesInChapter != null)
          'totalPagesInChapter': totalPagesInChapter,
      };
}

class BookmarkRepository {
  BookmarkRepository(this._db);

  final HibikiDatabase _db;

  String _key(String bookKey) => 'bookmarks_$bookKey';

  Future<List<Bookmark>> getBookmarks(String bookKey) async {
    await _migrateLegacyBookmarks(bookKey);
    final rows = await (_db.select(_db.bookmarks)
          ..where((tbl) => tbl.bookKey.equals(bookKey))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<int> addBookmark(String bookKey, Bookmark bookmark) async {
    return _db.into(_db.bookmarks).insert(
          BookmarksCompanion.insert(
            bookKey: bookKey,
            sectionIndex: bookmark.sectionIndex,
            normCharOffset: bookmark.normCharOffset,
            label: bookmark.label,
            createdAt: bookmark.createdAt.millisecondsSinceEpoch,
            bookTitle: Value(bookmark.bookTitle),
            pageInChapter: Value(bookmark.pageInChapter),
            totalPagesInChapter: Value(bookmark.totalPagesInChapter),
          ),
        );
  }

  Future<void> removeBookmarkById(int id) async {
    await (_db.delete(_db.bookmarks)..where((tbl) => tbl.id.equals(id))).go();
  }

  Future<void> removeBookmark(String bookKey, int index) async {
    final bookmarks = await getBookmarks(bookKey);
    if (index < 0 || index >= bookmarks.length) return;
    final int? id = bookmarks[index].id;
    if (id == null) return;
    await removeBookmarkById(id);
  }

  Future<void> removeBookmarkMatching(
    String bookKey, {
    required int sectionIndex,
    required int normCharOffset,
    required DateTime createdAt,
  }) async {
    await (_db.delete(_db.bookmarks)
          ..where((tbl) =>
              tbl.bookKey.equals(bookKey) &
              tbl.sectionIndex.equals(sectionIndex) &
              tbl.normCharOffset.equals(normCharOffset) &
              tbl.createdAt.equals(createdAt.millisecondsSinceEpoch)))
        .go();
  }

  Future<void> _migrateLegacyBookmarks(String bookKey) async {
    final raw = await _db.getPref(_key(bookKey));
    if (raw == null || raw.isEmpty) return;
    final existing = await (_db.selectOnly(_db.bookmarks)
          ..where(_db.bookmarks.bookKey.equals(bookKey))
          ..addColumns([_db.bookmarks.id.count()]))
        .map((row) => row.read(_db.bookmarks.id.count()) ?? 0)
        .getSingle();
    if (existing == 0) {
      final List<dynamic> list;
      try {
        list = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        await _db.deletePref(_key(bookKey));
        return;
      }
      for (final dynamic e in list) {
        if (e is! Map<String, dynamic>) continue;
        final bookmark = Bookmark.fromJson(e);
        await addBookmark(
          bookKey,
          Bookmark(
            sectionIndex: bookmark.sectionIndex,
            normCharOffset: bookmark.normCharOffset,
            label: bookmark.label,
            createdAt: bookmark.createdAt,
            bookKey: bookmark.bookKey ?? bookKey,
            pageInChapter: bookmark.pageInChapter,
            totalPagesInChapter: bookmark.totalPagesInChapter,
            bookTitle: bookmark.bookTitle,
          ),
        );
      }
    }
    await _db.deletePref(_key(bookKey));
  }

  Future<List<Bookmark>> getAllBookmarks() async {
    await _db.migrateLegacyBookmarkPreferences();
    final rows = await (_db.select(_db.bookmarks)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<void> importLegacyBookmark(
    String bookKey,
    Bookmark bookmark,
  ) async {
    await addBookmark(bookKey, bookmark);
  }
}
