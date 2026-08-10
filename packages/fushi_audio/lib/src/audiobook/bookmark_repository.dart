import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

class Bookmark {
  // json 键名 'bookKey' 是遗留偏好的 wire 面貌，冻结不改；v82 起值语义为书
  // 稳定 uid（遗留 json 里的旧 bookKey 值在迁移落库时被调用方传入的 uid 覆盖）。
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as int?,
        sectionIndex: json['sectionIndex'] as int,
        normCharOffset: json['normCharOffset'] as int,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        bookUid: json['bookKey'] as String?,
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
    this.bookUid,
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
        bookUid: row.bookUid,
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

  /// 书稳定身份（v82 起 = EpubBooks.uid；非 epub 域沿用其既有稳定键）。
  final String? bookUid;
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
        if (bookUid != null) 'bookKey': bookUid,
        if (bookTitle != null) 'bookTitle': bookTitle,
        if (pageInChapter != null) 'pageInChapter': pageInChapter,
        if (totalPagesInChapter != null)
          'totalPagesInChapter': totalPagesInChapter,
      };
}

class BookmarkRepository {
  BookmarkRepository(this._db);

  final FushiDatabase _db;

  // 遗留偏好键空间冻结在旧 bookKey（`bookmarks_<bookKey>`），与 DB 键（v82 起
  // uid）解耦：迁移需要调用方显式给 legacyBookKey，其余路径纯 uid。
  String _key(String legacyBookKey) => 'bookmarks_$legacyBookKey';

  Future<List<Bookmark>> getBookmarks(
    String bookUid, {
    String? legacyBookKey,
  }) async {
    if (legacyBookKey != null) {
      await _migrateLegacyBookmarks(bookUid, legacyBookKey);
    }
    final rows = await (_db.select(_db.bookmarks)
          ..where((tbl) => tbl.bookUid.equals(bookUid))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<int> addBookmark(String bookUid, Bookmark bookmark) async {
    return _db.into(_db.bookmarks).insert(
          BookmarksCompanion.insert(
            bookUid: bookUid,
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

  /// 清空全部书签（所有书籍）。收藏夹「清空」面板的书签范围走这里，一次性删表。
  Future<void> clearAllBookmarks() async {
    await _db.delete(_db.bookmarks).go();
  }

  Future<void> removeBookmark(String bookUid, int index) async {
    final bookmarks = await getBookmarks(bookUid);
    if (index < 0 || index >= bookmarks.length) return;
    final int? id = bookmarks[index].id;
    if (id == null) return;
    await removeBookmarkById(id);
  }

  Future<void> removeBookmarkMatching(
    String bookUid, {
    required int sectionIndex,
    required int normCharOffset,
    required DateTime createdAt,
  }) async {
    await (_db.delete(_db.bookmarks)
          ..where((tbl) =>
              tbl.bookUid.equals(bookUid) &
              tbl.sectionIndex.equals(sectionIndex) &
              tbl.normCharOffset.equals(normCharOffset) &
              tbl.createdAt.equals(createdAt.millisecondsSinceEpoch)))
        .go();
  }

  Future<void> _migrateLegacyBookmarks(
    String bookUid,
    String legacyBookKey,
  ) async {
    final raw = await _db.getPref(_key(legacyBookKey));
    if (raw == null || raw.isEmpty) return;
    final existing = await (_db.selectOnly(_db.bookmarks)
          ..where(_db.bookmarks.bookUid.equals(bookUid))
          ..addColumns([_db.bookmarks.id.count()]))
        .map((row) => row.read(_db.bookmarks.id.count()) ?? 0)
        .getSingle();
    if (existing == 0) {
      final List<dynamic> list;
      try {
        list = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        await _db.deletePref(_key(legacyBookKey));
        return;
      }
      for (final dynamic e in list) {
        if (e is! Map<String, dynamic>) continue;
        final bookmark = Bookmark.fromJson(e);
        await addBookmark(
          bookUid,
          Bookmark(
            sectionIndex: bookmark.sectionIndex,
            normCharOffset: bookmark.normCharOffset,
            label: bookmark.label,
            createdAt: bookmark.createdAt,
            // 遗留 json 里的旧 bookKey 值不落库——DB 键统一为传入的 uid。
            bookUid: bookUid,
            pageInChapter: bookmark.pageInChapter,
            totalPagesInChapter: bookmark.totalPagesInChapter,
            bookTitle: bookmark.bookTitle,
          ),
        );
      }
    }
    await _db.deletePref(_key(legacyBookKey));
  }

  Future<List<Bookmark>> getAllBookmarks() async {
    await _db.migrateLegacyBookmarkPreferences();
    final rows = await (_db.select(_db.bookmarks)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<void> importLegacyBookmark(
    String bookUid,
    Bookmark bookmark,
  ) async {
    await addBookmark(bookUid, bookmark);
  }
}
