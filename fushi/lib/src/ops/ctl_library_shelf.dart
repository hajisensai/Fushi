/// library 域「书架管理」的执行层：合集、标签、书签、收藏句、读完标记。
///
/// 只依赖数据库（与 [GalgameRepository]，游戏身份校验用），不碰 UI 与 AppModel，
/// 路由层（`ctl_library_manage_routes.dart`）把 HTTP 参数解析成调用后交给这里，
/// 测试直接拿内存库驱动。每个写操作都落到库页按钮背后的同一个方法上：
///
/// - 合集：[FushiDatabase.createMediaCollection] / [FushiDatabase.renameMediaCollection]
///   / [deleteMediaCollectionWithAssets]（删行并回收合集自有封面）/ [FushiDatabase.addToCollection] /
///   [FushiDatabase.removeFromCollection]（墓碑语义都在这些方法里）；同库页域判据
///   [FushiDatabase.getMediaCollectionsForEntryDomain]（加入合集弹窗同一份，BUG-2974）；
/// - 标签：[FushiDatabase.createTag] / [FushiDatabase.updateTag] /
///   [FushiDatabase.deleteTag]，打 / 摘标签走标签选择器的 [addTagToHost] /
///   [removeTagFromHost]；
/// - 书签：[BookmarkRepository]（PDF 阅读器加书签同一张表、同一口径）；
/// - 收藏句：[FavoriteSentenceRepository] + 收藏夹导出的 [buildSentenceExport]；
/// - 读完：[FushiDatabase.setEpubBookCompleted] / [setVideosWatched]。
library;

import 'dart:io';

import 'package:drift/native.dart' show SqliteException;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart'
    show deleteMediaCollectionWithAssets;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/media/collections/add_to_collection_dialog.dart'
    show CollectionMemberVisibility, countVisibleCollectionMembers;
import 'package:fushi/src/media/collections/collection_episode_slot.dart'
    show videoCollectionMemberVisibility;
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/video/video_watched_marks.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart'
    show addTagToHost, removeTagFromHost, tagsForMediaRef;
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show isGameCollectionMemberVisible;
import 'package:fushi/src/pages/implementations/tag_management_page.dart'
    show kTagPresetColors;
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/utils/misc/collection_exporter.dart';

/// 新建合集的类型（`MediaCollections.collectionType`）。
const List<String> kLibraryCtlCollectionTypes = <String>[
  'collection',
  'playlist',
];

/// SQLite 唯一约束冲突的扩展错误码（标签重名）。
const int _kSqliteConstraintUnique = 2067;

/// 书签章内进度的满分（与阅读器 `_addBookmarkAtCurrentPosition` 同口径：0–10000）。
const int kLibraryCtlBookmarkFractionScale = 10000;

class LibraryCtlShelf {
  LibraryCtlShelf({
    required FushiDatabase db,
    required GalgameRepository galgameRepo,
  }) : _db = db,
       _games = galgameRepo;

  final FushiDatabase _db;
  final GalgameRepository _games;

  // ── 条目键 → 各域身份 ─────────────────────────────────────────────────

  Future<EpubBookRow> _requireBook(LibraryCtlKey key) async {
    final EpubBookRow? row = await _db.getEpubBook(key.id);
    if (row == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
    return row;
  }

  Future<SrtBook> _requireSrt(LibraryCtlKey key) async {
    final SrtBook? book = await SrtBookRepository(_db).findByUid(key.id);
    if (book == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
    return book;
  }

  Future<VideoBookRow> _requireVideo(LibraryCtlKey key) async {
    final VideoBookRow? row = await VideoBookRepository(
      _db,
    ).getByBookUid(key.id);
    if (row == null) throw CtlFailure.notFound('视频库里没有 ${key.wire}');
    return row;
  }

  Future<GalgameEntry> _requireGame(LibraryCtlKey key) async {
    if (!_games.isLoaded) await _games.load();
    for (final GalgameEntry game in _games.games) {
      if (game.id == key.id) return game;
    }
    throw CtlFailure.notFound('游戏库里没有 ${key.wire}');
  }

  /// 条目在**合集成员表**里的身份：epub 成员行 entryKey 是书行 uid（v83，书架
  /// 「加入合集」同一换算）；srt / video / game 原样。
  Future<MediaRef> collectionRefFor(LibraryCtlKey key) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        final EpubBookRow row = await _requireBook(key);
        return MediaRef(
          kind: MediaKind.epub,
          entryKey: row.uid.isEmpty ? row.bookKey : row.uid,
        );
      case LibraryCtlStore.srt:
        await _requireSrt(key);
        return MediaRef(kind: MediaKind.srt, entryKey: key.id);
      case LibraryCtlStore.video:
        await _requireVideo(key);
        return MediaRef(kind: MediaKind.video, entryKey: key.id);
      case LibraryCtlStore.game:
        await _requireGame(key);
        return MediaRef(kind: MediaKind.game, entryKey: key.id);
    }
  }

  /// 条目在**标签映射**里的身份：epub 用 bookKey（与 [tagsForMediaRef] 契约一致），
  /// 其余同合集。
  Future<MediaRef> tagRefFor(LibraryCtlKey key) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        await _requireBook(key);
        return MediaRef(kind: MediaKind.epub, entryKey: key.id);
      case LibraryCtlStore.srt:
      case LibraryCtlStore.video:
      case LibraryCtlStore.game:
        return collectionRefFor(key);
    }
  }

  /// 合集成员行 → 条目键（epub 的 uid 反查回 bookKey；反查不上沿用原值）。未知种类
  /// （对端新种类透传行）返回 null。
  Future<LibraryCtlKey?> keyForCollectionMember(MediaCollectionItemRow row) =>
      keyForCollectionMemberRef(row.mediaType, row.entryKey);

  /// [keyForCollectionMember] 的原值版：成员表的 `media_type` / `entry_key` →
  /// 条目键（AI 排序结论只带这两个值）。
  Future<LibraryCtlKey?> keyForCollectionMemberRef(
    String mediaType,
    String entryKey,
  ) async {
    switch (MediaKind.tryParse(mediaType)) {
      case MediaKind.epub:
        final String bookKey =
            await _db.resolveEpubBookKeyByUid(entryKey) ?? entryKey;
        return LibraryCtlKey(LibraryCtlStore.book, bookKey);
      case MediaKind.srt:
        return LibraryCtlKey(LibraryCtlStore.srt, entryKey);
      case MediaKind.video:
        return LibraryCtlKey(LibraryCtlStore.video, entryKey);
      case MediaKind.game:
        return LibraryCtlKey(LibraryCtlStore.game, entryKey);
      case null:
        return null;
    }
  }

  /// 合集成员在库页上是否画得出来——与「加入合集」弹窗 / 合集详情页同一口径
  /// （BUG-3361），成员数只数这些行：
  ///
  /// - video：[videoCollectionMemberVisibility]（视频库同一判据）。控制通道不拉远端
  ///   目录，远端清单按空集传，等同详情页离线 / 关掉「显示远端条目」时的结果；
  /// - game：[isGameCollectionMemberVisible]（游戏库同一判据）；
  /// - srt：本机有这本有声书；
  /// - epub：本机有这本书（成员行 entryKey 认 uid 或透传的 bookKey），且它不是某本
  ///   有声书的伴生 EPUB——书架只画有声书卡、不单独画伴生 EPUB（书架页
  ///   `_resolveCollectionMember` 同一规则）。
  ///
  /// 删掉的条目、未知种类的透传行一律不数。库页的搜索 / 标签 / 阅读状态筛选是界面
  /// 瞬时状态，不进这里。
  Future<CollectionMemberVisibility> collectionMemberVisibility() async {
    final List<SrtBook> srtBooks = await SrtBookRepository(_db).listAll();
    final Set<String> srtUids = <String>{
      for (final SrtBook book in srtBooks) book.uid,
    };
    final Set<String> srtBookKeys = <String>{
      for (final SrtBook book in srtBooks)
        if (book.bookKey.isNotEmpty) book.bookKey,
    };
    final Set<String> epubEntryKeys = <String>{
      for (final EpubBookRow row in await _db.getAllEpubBooks())
        if (!srtBookKeys.contains(row.bookKey)) ...<String>[
          row.uid,
          row.bookKey,
        ],
    };
    final CollectionMemberVisibility video = videoCollectionMemberVisibility(
      localBookUids: <String>{
        for (final VideoBookRow row in await VideoBookRepository(_db).listAll())
          row.bookUid,
      },
      remoteOnlyIds: const <String>{},
    );
    if (!_games.isLoaded) await _games.load();
    final List<GalgameEntry> games = _games.games;
    return (String mediaType, String entryKey) =>
        switch (MediaKind.tryParse(mediaType)) {
          MediaKind.video => video(mediaType, entryKey),
          MediaKind.game => isGameCollectionMemberVisible(
            games: games,
            mediaType: mediaType,
            entryKey: entryKey,
          ),
          MediaKind.srt => srtUids.contains(entryKey),
          MediaKind.epub => epubEntryKeys.contains(entryKey),
          null => false,
        };
  }

  // ── 合集 ─────────────────────────────────────────────────────────────

  Future<MediaCollectionRow> _requireCollection(int id) async {
    final MediaCollectionRow? row = await _db.getMediaCollectionById(id);
    if (row == null) throw CtlFailure.notFound('没有 id=$id 的合集');
    return row;
  }

  /// [members] 是可见成员数（[collectionMemberVisibility]）；`manualOrder` = 成员
  /// 顺序被手动 / 一键 / AI 排过（`orderUpdatedAt` 非零）。
  Map<String, Object?> _collectionJson(MediaCollectionRow row, int members) =>
      <String, Object?>{
        'id': row.id,
        'name': row.name,
        'type': row.collectionType,
        'members': members,
        'manualOrder': row.orderUpdatedAt > 0,
        if (row.coverPath != null) 'coverPath': row.coverPath,
      };

  /// 全部合集（按排序权重）。[containing] 非空时只列含这个条目的合集。
  Future<List<Map<String, Object?>>> listCollections({
    LibraryCtlKey? containing,
  }) async {
    final List<MediaCollectionItemRow> items = await _db
        .getAllCollectionItems();
    final Map<int, int> counts = countVisibleCollectionMembers(
      items,
      await collectionMemberVisibility(),
    );
    Set<int>? only;
    if (containing != null) {
      final MediaRef ref = await collectionRefFor(containing);
      only = <int>{
        for (final MediaCollectionItemRow item in items)
          if (item.mediaType == ref.dbMediaType &&
              item.entryKey == ref.entryKey)
            item.collectionId,
      };
    }
    final List<MediaCollectionRow> rows = await _db.getAllMediaCollections();
    rows.sort(
      (MediaCollectionRow a, MediaCollectionRow b) =>
          a.sortOrder.compareTo(b.sortOrder),
    );
    return <Map<String, Object?>>[
      for (final MediaCollectionRow row in rows)
        if (only == null || only.contains(row.id))
          _collectionJson(row, counts[row.id] ?? 0),
    ];
  }

  /// 合集详情：成员按组内顺序，附条目键与标签。`members` 只数可见成员（与库页
  /// 同口径），`items` 仍列出全部成员行并以 `visible` 标出库页画不出来的那些——
  /// 它们照样能被 `remove` / `order` 点名。
  Future<Map<String, Object?>> collectionDetail(int id) async {
    final MediaCollectionRow row = await _requireCollection(id);
    final List<MediaCollectionItemRow> items = await _db.getCollectionItems(id);
    final CollectionMemberVisibility isVisible =
        await collectionMemberVisibility();
    final List<Map<String, Object?>> members = <Map<String, Object?>>[];
    for (final MediaCollectionItemRow item in items) {
      final LibraryCtlKey? key = await keyForCollectionMember(item);
      members.add(<String, Object?>{
        'key': key?.wire,
        'mediaType': item.mediaType,
        'entryKey': item.entryKey,
        'title': key == null ? null : await _titleOf(key),
        'visible': isVisible(item.mediaType, item.entryKey),
      });
    }
    return <String, Object?>{
      ..._collectionJson(
        row,
        countVisibleCollectionMembers(items, isVisible)[id] ?? 0,
      ),
      'tags': <String>[
        for (final BookTagRow tag in await _db.getTagsForCollection(id))
          tag.name,
      ],
      'items': members,
    };
  }

  /// 条目的展示标题（成员已被删时 null）。
  Future<String?> _titleOf(LibraryCtlKey key) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        final EpubBookRow? row = await _db.getEpubBook(key.id);
        return row == null
            ? null
            : displayTitleForBook(bookKey: row.bookKey, rawTitle: row.title);
      case LibraryCtlStore.srt:
        final SrtBook? book = await SrtBookRepository(_db).findByUid(key.id);
        return book == null
            ? null
            : displayTitleForBook(
                bookKey: book.bookKey,
                srtUid: book.uid,
                rawTitle: book.title,
              );
      case LibraryCtlStore.video:
        final VideoBookRow? row = await VideoBookRepository(
          _db,
        ).getByBookUid(key.id);
        return row == null ? null : displayTitleForVideo(row);
      case LibraryCtlStore.game:
        if (!_games.isLoaded) await _games.load();
        for (final GalgameEntry game in _games.games) {
          if (game.id == key.id) return game.displayName;
        }
        return null;
    }
  }

  /// 新建合集。同名同类型的合集已存在时 [FushiDatabase.createMediaCollection] 复用
  /// 它（自然键唯一），这里如实报 `existed: true`。
  Future<Map<String, Object?>> createCollection(
    String name, {
    String type = 'collection',
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw const CtlFailure.badRequest('合集名不能为空');
    if (!kLibraryCtlCollectionTypes.contains(type)) {
      throw CtlFailure.badRequest(
        '合集类型只能是 ${kLibraryCtlCollectionTypes.join(' / ')}',
      );
    }
    final MediaCollectionRow? existing = await _db
        .getMediaCollectionByNaturalKey(trimmed, type);
    final int id = await _db.createMediaCollection(
      trimmed,
      collectionType: type,
    );
    final MediaCollectionRow row = await _requireCollection(id);
    final int members = (await _db.getCollectionItems(id)).length;
    return <String, Object?>{
      ..._collectionJson(row, members),
      'existed': existing != null,
    };
  }

  Future<Map<String, Object?>> renameCollection(int id, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw const CtlFailure.badRequest('合集名不能为空');
    final MediaCollectionRow row = await _requireCollection(id);
    final MediaCollectionRow? clash = await _db.getMediaCollectionByNaturalKey(
      trimmed,
      row.collectionType,
    );
    if (clash != null && clash.id != id) {
      throw CtlFailure.conflict('已有同名合集（id=${clash.id}）');
    }
    await _db.renameMediaCollection(id, trimmed);
    final MediaCollectionRow renamed = await _requireCollection(id);
    return _collectionJson(renamed, (await _db.getCollectionItems(id)).length);
  }

  /// 删合集：只删合集与成员引用（连同合集自有封面文件），绝不删条目本身（与合集
  /// 详情页「删除合集」默认选项一致）。
  Future<Map<String, Object?>> deleteCollection(int id) async {
    final MediaCollectionRow row = await _requireCollection(id);
    final int deleted = await deleteMediaCollectionWithAssets(_db, id);
    if (deleted == 0) throw CtlFailure.conflict('合集 id=$id 没删掉');
    return <String, Object?>{'deleted': true, 'id': id, 'name': row.name};
  }

  /// 加成员。逐个返回结局：`added` / `already` / 失败原因。合集里已有成员时，新成员
  /// 必须与它们同一库页域（书 / 漫画 / 视频 / 游戏不混装，BUG-2974）。
  Future<Map<String, Object?>> addMembers(
    int id,
    List<LibraryCtlKey> keys,
  ) async {
    await _requireCollection(id);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    for (final LibraryCtlKey key in keys) {
      final MediaRef ref = await collectionRefFor(key);
      final List<MediaCollectionItemRow> items = await _db.getCollectionItems(
        id,
      );
      final bool already = items.any(
        (MediaCollectionItemRow it) =>
            it.mediaType == ref.dbMediaType && it.entryKey == ref.entryKey,
      );
      if (already) {
        results.add(<String, Object?>{'key': key.wire, 'status': 'already'});
        continue;
      }
      if (items.isNotEmpty) {
        final List<MediaCollectionRow> sameDomain = await _db
            .getMediaCollectionsForEntryDomain(ref.kind, ref.entryKey);
        if (!sameDomain.any((MediaCollectionRow c) => c.id == id)) {
          results.add(<String, Object?>{
            'key': key.wire,
            'status': 'rejected',
            'message': '与合集里已有条目不在同一个库页（书 / 漫画 / 视频 / 游戏不能混装）',
          });
          continue;
        }
      }
      await _db.addToCollection(id, ref.kind, ref.entryKey);
      results.add(<String, Object?>{'key': key.wire, 'status': 'added'});
    }
    return <String, Object?>{
      if (results.any((Map<String, Object?> r) => r['status'] == 'rejected'))
        'ok': false,
      'id': id,
      'results': results,
    };
  }

  /// 移出成员（移空后合集自动删除——[FushiDatabase.removeFromCollection] 的既有语义）。
  Future<Map<String, Object?>> removeMembers(
    int id,
    List<LibraryCtlKey> keys,
  ) async {
    await _requireCollection(id);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    for (final LibraryCtlKey key in keys) {
      final MediaRef ref = await collectionRefFor(key);
      final List<MediaCollectionItemRow> items = await _db.getCollectionItems(
        id,
      );
      final bool present = items.any(
        (MediaCollectionItemRow it) =>
            it.mediaType == ref.dbMediaType && it.entryKey == ref.entryKey,
      );
      if (!present) {
        results.add(<String, Object?>{'key': key.wire, 'status': 'absent'});
        continue;
      }
      await _db.removeFromCollection(id, ref.kind, ref.entryKey);
      results.add(<String, Object?>{'key': key.wire, 'status': 'removed'});
    }
    return <String, Object?>{
      'id': id,
      'collectionDeleted': await _db.getMediaCollectionById(id) == null,
      'results': results,
    };
  }

  // ── 标签 ─────────────────────────────────────────────────────────────

  Map<String, Object?> _tagJson(BookTagRow tag, {int? count}) =>
      <String, Object?>{
        'id': tag.id,
        'name': tag.name,
        'color': formatLibraryCtlColor(tag.colorValue),
        if (count != null) 'count': count,
      };

  Future<List<Map<String, Object?>>> listTags() async => <Map<String, Object?>>[
    for (final BookTagRow tag in await _db.getAllTags())
      _tagJson(tag, count: await _db.countBooksForTag(tag.id)),
  ];

  Future<BookTagRow> _requireTag(int id) async {
    for (final BookTagRow tag in await _db.getAllTags()) {
      if (tag.id == id) return tag;
    }
    throw CtlFailure.notFound('没有 id=$id 的标签');
  }

  /// 按名字或 id 找标签（`12` 先当 id，找不到再当名字）。
  Future<BookTagRow?> findTag(String nameOrId) async {
    final List<BookTagRow> all = await _db.getAllTags();
    final int? id = int.tryParse(nameOrId.trim());
    if (id != null) {
      for (final BookTagRow tag in all) {
        if (tag.id == id) return tag;
      }
    }
    for (final BookTagRow tag in all) {
      if (tag.name == nameOrId.trim()) return tag;
    }
    return null;
  }

  /// 新建标签；颜色缺省按标签选择器「新建」同一规则轮换预设色。
  Future<Map<String, Object?>> createTag(String name, {int? color}) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw const CtlFailure.badRequest('标签名不能为空');
    final List<BookTagRow> all = await _db.getAllTags();
    final int colorValue =
        color ?? kTagPresetColors[all.length % kTagPresetColors.length];
    final int id;
    try {
      id = await _db.createTag(trimmed, colorValue);
    } on SqliteException catch (e) {
      if (e.extendedResultCode == _kSqliteConstraintUnique) {
        throw CtlFailure.conflict('已有同名标签「$trimmed」');
      }
      rethrow;
    }
    return _tagJson(await _requireTag(id));
  }

  /// 改名 / 改色（改名的跨端墓碑语义在 [FushiDatabase.updateTag] 里）。
  Future<Map<String, Object?>> updateTag(
    int id, {
    String? name,
    int? color,
  }) async {
    final BookTagRow tag = await _requireTag(id);
    final String? trimmed = name?.trim();
    if (trimmed != null && trimmed.isEmpty) {
      throw const CtlFailure.badRequest('标签名不能为空');
    }
    if (trimmed == null && color == null) {
      throw const CtlFailure.badRequest('至少给出新名字或新颜色');
    }
    if (trimmed != null && trimmed != tag.name) {
      final BookTagRow? clash = await findTag(trimmed);
      if (clash != null && clash.name == trimmed && clash.id != id) {
        throw CtlFailure.conflict('已有同名标签「$trimmed」');
      }
    }
    await _db.updateTag(id, name: trimmed, colorValue: color);
    return _tagJson(await _requireTag(id));
  }

  Future<Map<String, Object?>> deleteTag(int id) async {
    final BookTagRow tag = await _requireTag(id);
    await _db.deleteTag(id);
    return <String, Object?>{'deleted': true, 'id': id, 'name': tag.name};
  }

  /// 条目当前的标签。
  Future<Map<String, Object?>> itemTags(LibraryCtlKey key) async {
    final MediaRef ref = await tagRefFor(key);
    return <String, Object?>{
      'key': key.wire,
      'tags': <Map<String, Object?>>[
        for (final BookTagRow tag in await tagsForMediaRef(_db, ref))
          _tagJson(tag),
      ],
    };
  }

  /// 给条目（[key]）或合集（[collectionId]）打标签。[create] 为真时不存在的标签名
  /// 先新建（标签选择器搜索框「新建“xxx”」同一语义）。
  Future<Map<String, Object?>> addTags(
    List<String> tags, {
    LibraryCtlKey? key,
    int? collectionId,
    bool create = false,
  }) async {
    final MediaRef? ref = key == null ? null : await tagRefFor(key);
    if (collectionId != null) await _requireCollection(collectionId);
    final List<BookTagRow> current = ref != null
        ? await tagsForMediaRef(_db, ref)
        : await _db.getTagsForCollection(collectionId!);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    for (final String name in tags) {
      BookTagRow? tag = await findTag(name);
      if (tag == null) {
        if (!create) {
          results.add(<String, Object?>{
            'tag': name,
            'status': 'missing',
            'message': '没有这个标签（加 --create 自动新建）',
          });
          continue;
        }
        tag = await _requireTag((await createTag(name))['id']! as int);
      }
      if (current.any((BookTagRow t) => t.id == tag!.id)) {
        results.add(<String, Object?>{'tag': tag.name, 'status': 'already'});
        continue;
      }
      await addTagToHost(_db, tag.id, media: ref, collectionId: collectionId);
      results.add(<String, Object?>{'tag': tag.name, 'status': 'added'});
    }
    return <String, Object?>{
      if (results.any((Map<String, Object?> r) => r['status'] == 'missing'))
        'ok': false,
      'target': key?.wire ?? 'collection:$collectionId',
      'results': results,
    };
  }

  /// 摘标签（写移除墓碑的语义在各域方法里）。
  Future<Map<String, Object?>> removeTags(
    List<String> tags, {
    LibraryCtlKey? key,
    int? collectionId,
  }) async {
    final MediaRef? ref = key == null ? null : await tagRefFor(key);
    if (collectionId != null) await _requireCollection(collectionId);
    final List<BookTagRow> current = ref != null
        ? await tagsForMediaRef(_db, ref)
        : await _db.getTagsForCollection(collectionId!);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    for (final String name in tags) {
      final BookTagRow? tag = await findTag(name);
      if (tag == null || !current.any((BookTagRow t) => t.id == tag.id)) {
        results.add(<String, Object?>{'tag': name, 'status': 'absent'});
        continue;
      }
      await removeTagFromHost(
        _db,
        tag.id,
        media: ref,
        collectionId: collectionId,
      );
      results.add(<String, Object?>{'tag': tag.name, 'status': 'removed'});
    }
    return <String, Object?>{
      'target': key?.wire ?? 'collection:$collectionId',
      'results': results,
    };
  }

  // ── 书签 ─────────────────────────────────────────────────────────────

  /// 书签宿主：书行（EPUB / PDF / 漫画）或配对了正文的有声书。返回 (bookUid, 书行)。
  Future<EpubBookRow> _bookmarkHost(LibraryCtlKey key) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        final EpubBookRow row = await _requireBook(key);
        if (row.uid.isEmpty) {
          throw CtlFailure.rejected('${key.wire} 缺稳定 uid，不能挂书签');
        }
        return row;
      case LibraryCtlStore.srt:
        final SrtBook srt = await _requireSrt(key);
        if (srt.bookKey.isEmpty) {
          throw const CtlFailure.rejected('纯字幕书没有正文，不能挂书签');
        }
        return _bookmarkHost(LibraryCtlKey(LibraryCtlStore.book, srt.bookKey));
      case LibraryCtlStore.video:
      case LibraryCtlStore.game:
        throw const CtlFailure.rejected('书签只支持书 / PDF / 漫画 / 有声书');
    }
  }

  Map<String, Object?> _bookmarkJson(
    Bookmark b,
    BookFormat format,
  ) => <String, Object?>{
    'id': b.id,
    'label': b.label,
    if (format == BookFormat.epub) ...<String, Object?>{
      'chapter': b.sectionIndex + 1,
      'progress': (b.normCharOffset * 100 / kLibraryCtlBookmarkFractionScale)
          .round(),
      // v125：阅读器加的书签带页首字符的章内精确偏移（改字号后仍能跳回）；
      // 旧书签 / 本命令加的书签没有（-1，不输出）。
      if (b.charOffset >= 0) 'charOffset': b.charOffset,
    } else
      'page': b.sectionIndex + 1,
    // 在线漫画书签所在章的稳定键（同一本在线漫画各章的书签靠它区分）。
    if (b.chapterKey != null) 'chapterKey': b.chapterKey,
    'createdAt': b.createdAt.millisecondsSinceEpoch,
  };

  Future<Map<String, Object?>> listBookmarks(LibraryCtlKey key) async {
    final EpubBookRow row = await _bookmarkHost(key);
    final BookFormat format = BookFormat.parseOrEpub(row.format);
    final List<Bookmark> marks = await BookmarkRepository(
      _db,
    ).getBookmarks(row.uid, legacyBookKey: row.bookKey);
    return <String, Object?>{
      'key': key.wire,
      'format': format.dbValue,
      'bookmarks': <Map<String, Object?>>[
        for (final Bookmark b in marks) _bookmarkJson(b, format),
      ],
    };
  }

  /// 加书签。EPUB 用 [chapter]（1 起计）+ [progressPercent]（章内 0–100）；PDF /
  /// 漫画用 [page]（1 起计，与 PDF 阅读器「加书签」同口径：sectionIndex = 0 起计页）。
  Future<Map<String, Object?>> addBookmark(
    LibraryCtlKey key, {
    int? chapter,
    int? page,
    double? progressPercent,
    String? label,
  }) async {
    final EpubBookRow row = await _bookmarkHost(key);
    final BookFormat format = BookFormat.parseOrEpub(row.format);
    final int sectionIndex;
    int fraction = 0;
    String defaultLabel;
    if (format == BookFormat.epub) {
      if (page != null) {
        throw const CtlFailure.badRequest('EPUB 书签用 --chapter（可带 --progress）');
      }
      if (chapter == null || chapter < 1) {
        throw const CtlFailure.badRequest('EPUB 书签需要 --chapter（1 起计）');
      }
      if (row.chapterCount > 0 && chapter > row.chapterCount) {
        throw CtlFailure.badRequest('这本书只有 ${row.chapterCount} 章');
      }
      final double percent = progressPercent ?? 0;
      if (percent < 0 || percent > 100) {
        throw const CtlFailure.badRequest('--progress 是章内百分比 0–100');
      }
      sectionIndex = chapter - 1;
      fraction = (percent / 100 * kLibraryCtlBookmarkFractionScale).round();
      defaultLabel = 'Ch.$chapter';
    } else {
      if (chapter != null || progressPercent != null) {
        throw const CtlFailure.badRequest('PDF / 漫画书签用 --page（1 起计）');
      }
      if (page == null || page < 1) {
        throw const CtlFailure.badRequest('PDF / 漫画书签需要 --page（1 起计）');
      }
      // 在线漫画的书签按「章 + 页」记（chapterKey），本命令只收页码、点不了章：
      // 写进去会变成「在当前打开的任意一章跳第 N 页」的错书签，所以直接拒绝。
      if (format == BookFormat.manga &&
          OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) != null) {
        throw const CtlFailure.rejected('在线漫画的书签请在阅读器里加（需要所在章）');
      }
      if (format == BookFormat.pdf &&
          row.chapterCount > 0 &&
          page > row.chapterCount) {
        throw CtlFailure.badRequest('这本 PDF 只有 ${row.chapterCount} 页');
      }
      sectionIndex = page - 1;
      defaultLabel = 'P.$page';
    }
    final String finalLabel = (label ?? '').trim().isEmpty
        ? defaultLabel
        : label!.trim();
    final DateTime now = DateTime.now();
    final int id = await BookmarkRepository(_db).addBookmark(
      row.uid,
      Bookmark(
        sectionIndex: sectionIndex,
        normCharOffset: fraction,
        label: finalLabel,
        createdAt: now,
        bookUid: row.uid,
        bookTitle: row.title,
      ),
    );
    return <String, Object?>{
      'key': key.wire,
      ..._bookmarkJson(
        Bookmark(
          id: id,
          sectionIndex: sectionIndex,
          normCharOffset: fraction,
          label: finalLabel,
          createdAt: now,
        ),
        format,
      ),
    };
  }

  Future<Map<String, Object?>> removeBookmark(int id) async {
    final BookmarkRow? row = await (_db.select(
      _db.bookmarks,
    )..where(($BookmarksTable t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) throw CtlFailure.notFound('没有 id=$id 的书签');
    await BookmarkRepository(_db).removeBookmarkById(id);
    return <String, Object?>{'deleted': true, 'id': id, 'label': row.label};
  }

  // ── 收藏句 ───────────────────────────────────────────────────────────

  /// 条目键 → 收藏句的 `bookKey` 身份（书 = bookKey，有声书 = 配对 bookKey 或 uid，
  /// 视频 = bookUid）。
  Future<Set<String>> _favoriteIdentities(LibraryCtlKey key) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        await _requireBook(key);
        return <String>{key.id};
      case LibraryCtlStore.srt:
        final SrtBook srt = await _requireSrt(key);
        return <String>{srt.uid, if (srt.bookKey.isNotEmpty) srt.bookKey};
      case LibraryCtlStore.video:
        await _requireVideo(key);
        return <String>{key.id};
      case LibraryCtlStore.game:
        await _requireGame(key);
        return <String>{key.id};
    }
  }

  Map<String, Object?> _favoriteJson(FavoriteSentence f) => <String, Object?>{
    'id': f.id,
    'text': f.text,
    'source': f.source,
    'bookTitle': _favoriteDisplayTitle(f),
    if (f.bookKey != null) 'bookKey': f.bookKey,
    if (f.chapterLabel != null) 'chapter': f.chapterLabel,
    if (f.expression != null) 'expression': f.expression,
    'createdAt': f.createdAt.millisecondsSinceEpoch,
  };

  /// 书类收藏的分组名过显示名门面（改名覆盖）；其余用收藏时的快照名。
  String _favoriteDisplayTitle(FavoriteSentence f) {
    final String? bookKey = f.bookKey;
    if (bookKey != null &&
        bookKey.isNotEmpty &&
        f.source == kFavoriteSentenceSourceBook) {
      return displayTitleForBook(bookKey: bookKey, rawTitle: f.bookTitle);
    }
    return f.bookTitle;
  }

  Future<List<FavoriteSentence>> _favorites(LibraryCtlKey? key) async {
    final List<FavoriteSentence> all = await FavoriteSentenceRepository(
      _db,
    ).getAll();
    if (key == null) return all;
    final Set<String> ids = await _favoriteIdentities(key);
    return all
        .where((FavoriteSentence f) => ids.contains(f.bookKey))
        .toList(growable: false);
  }

  Future<Map<String, Object?>> listFavorites({
    LibraryCtlKey? key,
    int? limit,
  }) async {
    final List<FavoriteSentence> rows = await _favorites(key);
    final Iterable<FavoriteSentence> shown = limit == null || limit <= 0
        ? rows
        : rows.take(limit);
    return <String, Object?>{
      'total': rows.length,
      'favorites': <Map<String, Object?>>[
        for (final FavoriteSentence f in shown) _favoriteJson(f),
      ],
    };
  }

  Future<Map<String, Object?>> removeFavorite(String id) async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(_db);
    final FavoriteSentence? hit = (await repo.getAll())
        .where((FavoriteSentence f) => f.id == id)
        .firstOrNull;
    if (hit == null) throw CtlFailure.notFound('没有 id=$id 的收藏句');
    await repo.removeById(id);
    return <String, Object?>{'deleted': true, 'id': id, 'text': hit.text};
  }

  /// 清空收藏句（收藏夹「清空」面板的收藏句范围同一方法，写删除墓碑）。
  Future<Map<String, Object?>> clearFavorites() async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(_db);
    final int count = (await repo.getAll()).length;
    await repo.clear();
    return <String, Object?>{'cleared': count};
  }

  /// 导出收藏句到 [outPath]（收藏夹导出同一个 [buildSentenceExport]）。
  Future<Map<String, Object?>> exportFavorites({
    required String outPath,
    required ExportFormat format,
    LibraryCtlKey? key,
    bool dedupe = false,
  }) async {
    final List<FavoriteSentence> rows = await _favorites(key);
    if (rows.isEmpty) throw const CtlFailure.rejected('没有可导出的收藏句');
    final List<ExportSentence> mapped = <ExportSentence>[
      for (final FavoriteSentence f in rows)
        ExportSentence(
          text: f.text,
          bookTitle: _favoriteDisplayTitle(f),
          chapterLabel: f.chapterLabel,
          source: f.source,
          createdAt: f.createdAt,
          bookKey: f.bookKey,
        ),
    ];
    final List<ExportSentence> picked = dedupe
        ? dedupeSentences(mapped)
        : mapped;
    final String content = buildSentenceExport(picked, format: format);
    final File out = File(outPath);
    await out.parent.create(recursive: true);
    await out.writeAsString(content);
    return <String, Object?>{
      'path': out.path,
      'format': format.name,
      'count': picked.length,
    };
  }

  // ── 读完标记 ─────────────────────────────────────────────────────────

  /// 标记 / 取消读完（书架卡「标记已读完」同一列 `EpubBooks.completedAt`；视频走
  /// [setVideosWatched]——自 BUG-3491 起播放不再自动打勾，这是手动标记视频已看
  /// 的入口之一，与界面菜单同一语义：标记 / 取消都收回续播位置，本地入库的媒体
  /// 服务器条目回写服务器）。
  ///
  /// 视频的撤销：[restorePositionMs] 非空 = 原样恢复「看完标记 + 断点」（
  /// [VideoBookRepository.restoreWatchState]，[restoreCompletedAt] 是要恢复的看完
  /// 时刻），而不是再标一次——取消已看清掉的断点必须能还回去。
  Future<Map<String, Object?>> setCompleted(
    LibraryCtlKey key, {
    required bool completed,
    int? restoreCompletedAt,
    int? restorePositionMs,
  }) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        await _requireBook(key);
        await _db.setEpubBookCompleted(
          key.id,
          completed ? DateTime.now() : null,
        );
      case LibraryCtlStore.srt:
        final SrtBook srt = await _requireSrt(key);
        if (srt.bookKey.isEmpty) {
          throw const CtlFailure.rejected('纯字幕书没有读完标记（没有正文进度）');
        }
        await _db.setEpubBookCompleted(
          srt.bookKey,
          completed ? DateTime.now() : null,
        );
      case LibraryCtlStore.video:
        await _requireVideo(key);
        if (restorePositionMs != null) {
          if (restorePositionMs < 0) {
            throw const CtlFailure.badRequest('positionMs 不能为负');
          }
          await VideoBookRepository(_db).restoreWatchState(
            key.id,
            completedAt: !completed
                ? null
                : restoreCompletedAt == null || restoreCompletedAt <= 0
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(restoreCompletedAt),
            positionMs: restorePositionMs,
          );
          final VideoBookRow? row = await _db.getVideoBookByBookUid(key.id);
          if (row != null) {
            await writeBackMediaServerPlayed(
              db: _db,
              rows: <VideoBookRow>[row],
              played: completed,
            );
          }
        } else {
          // 统计不动，完整重置仍走 library reset。
          await setVideosWatched(
            db: _db,
            watched: completed,
            localUids: <String>[key.id],
          );
        }
        final VideoBookRow? after = await _db.getVideoBookByBookUid(key.id);
        return <String, Object?>{
          'key': key.wire,
          'completed': completed,
          'positionMs': after?.lastPositionMs ?? 0,
        };
      case LibraryCtlStore.game:
        throw const CtlFailure.rejected('游戏的游玩状态请用 game 命令设置');
    }
    return <String, Object?>{'key': key.wire, 'completed': completed};
  }
}

/// `#RRGGBB` / `RRGGBB` / `#AARRGGBB` → ARGB int；非法返回 null。
int? parseLibraryCtlColor(String raw) {
  final String hex = raw.trim().replaceFirst('#', '');
  if (hex.length != 6 && hex.length != 8) return null;
  final int? value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return hex.length == 6 ? 0xFF000000 | value : value;
}

/// ARGB int → `#RRGGBB`（不透明）或 `#AARRGGBB`。
String formatLibraryCtlColor(int argb) {
  final int alpha = (argb >> 24) & 0xFF;
  final String rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  return alpha == 0xFF
      ? '#${rgb.toUpperCase()}'
      : '#${alpha.toRadixString(16).padLeft(2, '0').toUpperCase()}${rgb.toUpperCase()}';
}
