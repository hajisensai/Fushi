import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:hibiki/src/database/database.dart';

class Bookmark {
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as int?,
        sectionIndex: json['sectionIndex'] as int,
        normCharOffset: json['normCharOffset'] as int,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        ttuBookId: json['ttuBookId'] as int?,
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
    this.ttuBookId,
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
        ttuBookId: row.ttuBookId,
        bookTitle: row.bookTitle,
        pageInChapter: row.pageInChapter,
        totalPagesInChapter: row.totalPagesInChapter,
      );

  final int? id;
  final int sectionIndex;
  final int normCharOffset;
  final String label;
  final DateTime createdAt;
  final int? ttuBookId;
  final String? bookTitle;
  final int? pageInChapter;
  final int? totalPagesInChapter;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'sectionIndex': sectionIndex,
        'normCharOffset': normCharOffset,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
        if (ttuBookId != null) 'ttuBookId': ttuBookId,
        if (bookTitle != null) 'bookTitle': bookTitle,
        if (pageInChapter != null) 'pageInChapter': pageInChapter,
        if (totalPagesInChapter != null)
          'totalPagesInChapter': totalPagesInChapter,
      };
}

class BookmarkRepository {
  BookmarkRepository(this._db);

  final HibikiDatabase _db;

  String _key(int ttuBookId) => 'bookmarks_$ttuBookId';

  Future<List<Bookmark>> getBookmarks(int ttuBookId) async {
    await _migrateLegacyBookmarks(ttuBookId);
    final rows = await (_db.select(_db.bookmarks)
          ..where((tbl) => tbl.ttuBookId.equals(ttuBookId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<int> addBookmark(int ttuBookId, Bookmark bookmark) async {
    return _db.into(_db.bookmarks).insert(
          BookmarksCompanion.insert(
            ttuBookId: ttuBookId,
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

  Future<void> removeBookmark(int ttuBookId, int index) async {
    final bookmarks = await getBookmarks(ttuBookId);
    if (index < 0 || index >= bookmarks.length) return;
    final int? id = bookmarks[index].id;
    if (id == null) return;
    await removeBookmarkById(id);
  }

  Future<void> removeBookmarkMatching(
    int ttuBookId, {
    required int sectionIndex,
    required int normCharOffset,
    required DateTime createdAt,
  }) async {
    await (_db.delete(_db.bookmarks)
          ..where((tbl) =>
              tbl.ttuBookId.equals(ttuBookId) &
              tbl.sectionIndex.equals(sectionIndex) &
              tbl.normCharOffset.equals(normCharOffset) &
              tbl.createdAt.equals(createdAt.millisecondsSinceEpoch)))
        .go();
  }

  Future<void> _migrateLegacyBookmarks(int ttuBookId) async {
    final raw = await _db.getPref(_key(ttuBookId));
    if (raw == null || raw.isEmpty) return;
    final existing = await (_db.selectOnly(_db.bookmarks)
          ..where(_db.bookmarks.ttuBookId.equals(ttuBookId))
          ..addColumns([_db.bookmarks.id.count()]))
        .map((row) => row.read(_db.bookmarks.id.count()) ?? 0)
        .getSingle();
    if (existing > 0) return;
    final List<dynamic> list;
    try {
      list = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return;
    }
    for (final dynamic e in list) {
      if (e is! Map<String, dynamic>) continue;
      final bookmark = Bookmark.fromJson(e);
      await addBookmark(
        ttuBookId,
        Bookmark(
          sectionIndex: bookmark.sectionIndex,
          normCharOffset: bookmark.normCharOffset,
          label: bookmark.label,
          createdAt: bookmark.createdAt,
          ttuBookId: bookmark.ttuBookId ?? ttuBookId,
          pageInChapter: bookmark.pageInChapter,
          totalPagesInChapter: bookmark.totalPagesInChapter,
          bookTitle: bookmark.bookTitle,
        ),
      );
    }
    await _db.deletePref(_key(ttuBookId));
  }

  Future<List<Bookmark>> getAllBookmarks() async {
    await _db.migrateLegacyBookmarkPreferences();
    final rows = await (_db.select(_db.bookmarks)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<void> importLegacyBookmark(
    int ttuBookId,
    Bookmark bookmark,
  ) async {
    await addBookmark(ttuBookId, bookmark);
  }
}
