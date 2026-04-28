import 'dart:convert';

import 'package:hibiki/src/database/database.dart';

class Bookmark {
  Bookmark({
    required this.sectionIndex,
    required this.normCharOffset,
    required this.label,
    required this.createdAt,
  });

  final int sectionIndex;
  final int normCharOffset;
  final String label;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'sectionIndex': sectionIndex,
        'normCharOffset': normCharOffset,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        sectionIndex: json['sectionIndex'] as int,
        normCharOffset: json['normCharOffset'] as int,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
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
}
