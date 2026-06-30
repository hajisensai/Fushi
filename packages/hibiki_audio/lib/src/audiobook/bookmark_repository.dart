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
    this.charAnchor,
    this.charAnchorLength,
    this.preserveSavedPosition = false,
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

  /// 真实书签（[BookmarkRow]）的 `normCharOffset` 是 `(progress*10000).round()` 的
  /// 0-10000 章内进度分数（见 reader 端 `_addBookmarkAtCurrentPosition`）。这是持久
  /// 化语义，跳转端按分数 `/10000` 还原。**不要**把绝对字符锚塞进此字段——收藏句 /
  /// 制卡历史的绝对字符锚走 [charAnchor]（BUG-459）。
  final int normCharOffset;
  final String label;
  final DateTime createdAt;
  final String? bookKey;
  final String? bookTitle;
  final int? pageInChapter;
  final int? totalPagesInChapter;

  /// BUG-459：临时跳转用的「章节内绝对可匹配字符索引」（`getNormalizedOffset` 口径，
  /// 0..数千），与阅读器 `_initialCharOffset` / `ReaderPosition.charOffset` 同计量。
  /// 收藏句 / 制卡历史跳回原文时由 [_CollectionItem.normCharOffset] 透传；非 null 时
  /// 阅读器走精确字符锚恢复（`scrollToCharOffset`），消除把绝对索引误当 0-10000 分数
  /// `/10000≈0` 而恒跳章首的旧 bug。**仅内存传输用，不持久化**（[fromRow]/[fromJson]
  /// 不读它，真实书签恒为 null → 走 [normCharOffset] 分数路径，向后兼容）。
  final int? charAnchor;

  /// BUG-461：收藏句的「章节内可匹配字符长度」（`getNormalizedOffset` 口径，与
  /// [charAnchor] 同计量），由 [_CollectionItem.normCharLength] 透传。非 null 且 > 0 时，
  /// 连续(滚动)模式横排把跳转目标当作字符区间 `[charAnchor, charAnchor+charAnchorLength]`
  /// 整句对齐进可见区（句尾不被阅读底栏切，消除「五五开切句尾」）。**仅内存传输用，不
  /// 持久化**（[fromRow]/[fromJson] 不读它）；null/0 时退回单点句首锚（旧行为，向后兼容）。
  final int? charAnchorLength;

  /// BUG-459：本次跳转是否为「临时浏览跳转」——true 时阅读器进入后**不覆盖**该书
  /// 已保存的 [ReaderPosition]（用户从收藏 / 制卡历史点进来看某句，不应毁掉真正的
  /// 阅读位置）。真实书签 / 普通打开恒 false（照常持久化阅读进度）。
  final bool preserveSavedPosition;

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
