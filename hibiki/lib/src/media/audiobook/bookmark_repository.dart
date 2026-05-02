import 'dart:convert';

import 'package:hibiki/src/database/database.dart';

class Bookmark {
  Bookmark({
    required this.sectionIndex,
    required this.normCharOffset,
    required this.label,
    required this.createdAt,
    this.ttuBookId,
    this.bookTitle,
    this.pageInChapter,
    this.totalPagesInChapter,
  });

  final int sectionIndex;
  final int normCharOffset;
  final String label;
  final DateTime createdAt;
  final int? ttuBookId;
  final String? bookTitle;
  final int? pageInChapter;
  final int? totalPagesInChapter;

  Map<String, dynamic> toJson() => {
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

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        sectionIndex: json['sectionIndex'] as int,
        normCharOffset: json['normCharOffset'] as int,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        ttuBookId: json['ttuBookId'] as int?,
        bookTitle: json['bookTitle'] as String?,
        pageInChapter: json['pageInChapter'] as int?,
        totalPagesInChapter: json['totalPagesInChapter'] as int?,
      );
}

class BookmarkRepository {
  BookmarkRepository(this._db);

  final HibikiDatabase _db;

  String _key(int ttuBookId) => 'bookmarks_$ttuBookId';

  Future<List<Bookmark>> getBookmarks(int ttuBookId) async {
    final raw = await _db.getPref(_key(ttuBookId));
    if (raw == null || raw.isEmpty) return [];
    final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> addBookmark(int ttuBookId, Bookmark bookmark) async {
    final bookmarks = await getBookmarks(ttuBookId);
    bookmarks.insert(0, bookmark);
    await _db.setPref(
      _key(ttuBookId),
      jsonEncode(bookmarks.map((b) => b.toJson()).toList()),
    );
  }

  Future<void> removeBookmark(int ttuBookId, int index) async {
    final bookmarks = await getBookmarks(ttuBookId);
    if (index < 0 || index >= bookmarks.length) return;
    bookmarks.removeAt(index);
    await _db.setPref(
      _key(ttuBookId),
      jsonEncode(bookmarks.map((b) => b.toJson()).toList()),
    );
  }

  Future<List<Bookmark>> getAllBookmarks() async {
    final allPrefs = await _db.getAllPrefs();
    final List<Bookmark> result = [];
    for (final entry in allPrefs.entries) {
      if (!entry.key.startsWith('bookmarks_')) continue;
      final ttuId = int.tryParse(entry.key.substring('bookmarks_'.length));
      if (ttuId == null) continue;
      final List<dynamic> list = jsonDecode(entry.value) as List<dynamic>;
      for (final e in list) {
        final bm = Bookmark.fromJson(e as Map<String, dynamic>);
        result.add(Bookmark(
          sectionIndex: bm.sectionIndex,
          normCharOffset: bm.normCharOffset,
          label: bm.label,
          createdAt: bm.createdAt,
          ttuBookId: bm.ttuBookId ?? ttuId,
          pageInChapter: bm.pageInChapter,
          totalPagesInChapter: bm.totalPagesInChapter,
          bookTitle: bm.bookTitle,
        ));
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }
}
