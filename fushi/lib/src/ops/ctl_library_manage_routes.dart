import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart'
    show clearCollectionOwnCover;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_removal.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show
        allTagsProvider,
        bookTagMapProvider,
        filteredBookIdsProvider,
        filteredSrtBookUidsProvider;
import 'package:fushi/src/ops/ctl_collection_routes.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/ctl_library_shelf.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/utils/misc/collection_exporter.dart'
    show ExportFormat;

/// library 域「书架管理」路由：合集 / 标签 / 书签 / 收藏句 / 改名 / 封面 / 读完 /
/// 重置进度 / 来源库增删改。CLI 命令见 `packages/fushi_cli/lib/src/commands/
/// library_commands.dart`。纯数据库的部分落到 [LibraryCtlShelf]；需要 AppModel 的
/// （改名覆盖层、封面 override 目录、来源删除连带下载偏好）在这里直接调库页同一方法：
///
/// - 改名：[MediaSource.setOverrideTitleFromMediaItem]（书架卡「重命名」）/
///   [VideoBookRepository.updateTitle]（视频库「重命名」）；
/// - 封面：[MediaCoverService.applyBookCoverOverride] /
///   [MediaCoverService.applyVideoCoverManual] / [MediaCoverService.applyCollectionCover]；
/// - 重置：[resetBookReadingState] / [resetVideoWatchState]（库页「重置阅读状态」）；
/// - 来源：[addLocalFolderAsSource] / [removeSourceLibrary] /
///   [FushiDatabase.updateMediaSourceLabel]。
List<CtlRoute> buildLibraryManageCtlRoutes(OpContext context) {
  final _LibraryManageHandlers h = _LibraryManageHandlers(context);
  const String root = kLibraryCtlManageRoot;
  return <CtlRoute>[
    CtlRoute.get('$root/collections', h.listCollections),
    CtlRoute.post('$root/collections', h.createCollection),
    CtlRoute.get('$root/collections/:id', h.collectionDetail),
    CtlRoute.put('$root/collections/:id', h.renameCollection),
    CtlRoute.delete('$root/collections/:id', h.deleteCollection),
    CtlRoute.post('$root/collections/:id/members', h.addMembers),
    CtlRoute.delete('$root/collections/:id/members', h.removeMembers),
    CtlRoute.put('$root/collections/:id/cover', h.collectionCover),
    CtlRoute.post('$root/collections/:id/tags', h.tagCollection),
    CtlRoute.delete('$root/collections/:id/tags', h.untagCollection),
    // 合集定序（手动 order / 一键 sort 含 AI）：同一前缀、同一 `collection` CLI 组；
    // 实现在 ctl_collection_routes.dart（AI 指派来源要能注入，单独成文件便于测试）。
    ...buildCollectionCtlRoutes(context),
    CtlRoute.get('$root/tags', h.listTags),
    CtlRoute.post('$root/tags', h.createTag),
    CtlRoute.put('$root/tags/:id', h.updateTag),
    CtlRoute.delete('$root/tags/:id', h.deleteTag),
    CtlRoute.get('$root/items/:key/tags', h.itemTags),
    CtlRoute.post('$root/items/:key/tags', h.tagItem),
    CtlRoute.delete('$root/items/:key/tags', h.untagItem),
    CtlRoute.get('$root/items/:key/bookmarks', h.listBookmarks),
    CtlRoute.post('$root/items/:key/bookmarks', h.addBookmark),
    CtlRoute.delete('$root/bookmarks/:id', h.removeBookmark),
    CtlRoute.get('$root/favorites', h.listFavorites),
    CtlRoute.delete('$root/favorites/:id', h.removeFavorite),
    CtlRoute.post('$root/favorites/clear', h.clearFavorites),
    CtlRoute.post('$root/favorites/export', h.exportFavorites),
    CtlRoute.put('$root/items/:key/title', h.renameItem),
    CtlRoute.put('$root/items/:key/cover', h.itemCover),
    CtlRoute.put('$root/items/:key/completed', h.setCompleted),
    CtlRoute.post('$root/items/:key/reset', h.resetProgress),
    CtlRoute.post('$root/sources', h.addSource),
    CtlRoute.put('$root/sources/:id', h.renameSource),
    CtlRoute.delete('$root/sources/:id', h.removeSource),
  ];
}

/// 与 `ctl_library_routes.dart` 的 `kLibraryCtlRoot` 同一前缀（路由表测试要求全部
/// library 路由在它之下）。
const String kLibraryCtlManageRoot = '/api/admin/library';

/// `library reset --stats` 的值域 → [StudyRecordResetScope]。
StudyRecordResetScope? parseLibraryCtlResetScope(String? raw) =>
    switch ((raw ?? 'keep').trim().toLowerCase()) {
      'keep' => StudyRecordResetScope.keep,
      'last' => StudyRecordResetScope.lastSession,
      'all' => StudyRecordResetScope.all,
      _ => null,
    };

/// 导出格式名 → [ExportFormat]（`md` 也认）。
ExportFormat? parseLibraryCtlExportFormat(String? raw) {
  final String text = (raw ?? 'markdown').trim().toLowerCase();
  if (text == 'md') return ExportFormat.markdown;
  for (final ExportFormat format in ExportFormat.values) {
    if (format.name == text) return format;
  }
  return null;
}

class _LibraryManageHandlers {
  _LibraryManageHandlers(this._context);

  final OpContext _context;

  AppModel get _app => _context.appModel;
  FushiDatabase get _db => _app.database;

  LibraryCtlShelf get _shelf =>
      LibraryCtlShelf(db: _db, galgameRepo: _app.galgameRepo);

  void _requireWritable() {
    if (_app.isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  void _requireConfirm(CtlCall call) {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest(
        '这一步不可撤销，需要 confirm: true（CLI 用 --yes）',
      );
    }
  }

  LibraryCtlKey _parseKeyText(String raw) {
    final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
    if (key == null) {
      throw CtlFailure.badRequest(
        '条目键「$raw」格式不对，应为 book:/srt:/video:/game: 前缀加 id（见 library ls）',
      );
    }
    return key;
  }

  LibraryCtlKey _key(CtlCall call) => _parseKeyText(call.params['key'] ?? '');

  List<LibraryCtlKey> _keys(CtlCall call) {
    final List<String> raw = call.stringList('keys');
    if (raw.isEmpty) throw const CtlFailure.badRequest('keys 缺失');
    return <LibraryCtlKey>[for (final String k in raw) _parseKeyText(k)];
  }

  int _intParam(CtlCall call, String name) {
    final int? value = int.tryParse(call.params[name] ?? '');
    if (value == null) throw CtlFailure.badRequest('$name 必须是整数');
    return value;
  }

  /// 刷新书架 / 标签筛选的响应式源（与库页改动后同一组失效）。
  void _refreshShelf({bool tags = false}) {
    _context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    _context.ref.invalidate(srtBooksProvider);
    if (tags) {
      _context.ref.invalidate(allTagsProvider);
      _context.ref.invalidate(bookTagMapProvider);
      _context.ref.invalidate(filteredBookIdsProvider);
      _context.ref.invalidate(filteredSrtBookUidsProvider);
    }
  }

  // ── 合集 ─────────────────────────────────────────────────────────────

  Future<Object?> listCollections(CtlCall call) async {
    final String? containing = call.optString('key');
    return <String, Object?>{
      'collections': await _shelf.listCollections(
        containing: containing == null ? null : _parseKeyText(containing),
      ),
    };
  }

  Future<Object?> collectionDetail(CtlCall call) =>
      _shelf.collectionDetail(_intParam(call, 'id'));

  Future<Object?> createCollection(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> created = await _shelf.createCollection(
      call.requireString('name'),
      type: call.optString('type') ?? 'collection',
    );
    _refreshShelf();
    return created;
  }

  Future<Object?> renameCollection(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> renamed = await _shelf.renameCollection(
      _intParam(call, 'id'),
      call.requireString('name'),
    );
    _refreshShelf();
    return renamed;
  }

  Future<Object?> deleteCollection(CtlCall call) async {
    _requireConfirm(call);
    _requireWritable();
    final Map<String, Object?> deleted = await _shelf.deleteCollection(
      _intParam(call, 'id'),
    );
    _refreshShelf();
    return deleted;
  }

  Future<Object?> addMembers(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> result = await _shelf.addMembers(
      _intParam(call, 'id'),
      _keys(call),
    );
    _refreshShelf();
    return result;
  }

  Future<Object?> removeMembers(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> result = await _shelf.removeMembers(
      _intParam(call, 'id'),
      _keys(call),
    );
    _refreshShelf();
    return result;
  }

  /// 合集自有封面（合集详情页「设置封面」）：本地图片路径或 http(s) URL；`reset`
  /// 清掉自有封面、回落成员借用链。
  Future<Object?> collectionCover(CtlCall call) async {
    _requireWritable();
    final int id = _intParam(call, 'id');
    final MediaCollectionRow? row = await _db.getMediaCollectionById(id);
    if (row == null) throw CtlFailure.notFound('没有 id=$id 的合集');
    if (call.optBool('reset') == true) {
      await clearCollectionOwnCover(_db, id);
      _refreshShelf();
      return <String, Object?>{'id': id, 'cover': null};
    }
    final String destPath = await _withCoverSource(call, (File image) async {
      try {
        return await MediaCoverService.applyCollectionCover(
          database: _db,
          collectionId: id,
          pickedPath: image.path,
        );
      } on StateError catch (e) {
        throw CtlFailure.conflict('${e.message}，稍后再试');
      }
    });
    _refreshShelf();
    return <String, Object?>{'id': id, 'cover': destPath};
  }

  Future<Object?> tagCollection(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> result = await _shelf.addTags(
      _tagNames(call),
      collectionId: _intParam(call, 'id'),
      create: call.optBool('create') == true,
    );
    _refreshShelf(tags: true);
    return result;
  }

  Future<Object?> untagCollection(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> result = await _shelf.removeTags(
      _tagNames(call),
      collectionId: _intParam(call, 'id'),
    );
    _refreshShelf(tags: true);
    return result;
  }

  // ── 标签 ─────────────────────────────────────────────────────────────

  List<String> _tagNames(CtlCall call) {
    final List<String> tags = call.stringList('tags');
    if (tags.isEmpty) throw const CtlFailure.badRequest('tags 缺失');
    return tags;
  }

  int? _color(CtlCall call) {
    final String? raw = call.optString('color');
    if (raw == null) return null;
    final int? color = parseLibraryCtlColor(raw);
    if (color == null) {
      throw CtlFailure.badRequest('颜色要写成 #RRGGBB，收到「$raw」');
    }
    return color;
  }

  Future<Object?> listTags(CtlCall call) async => <String, Object?>{
    'tags': await _shelf.listTags(),
  };

  Future<Object?> createTag(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> created = await _shelf.createTag(
      call.requireString('name'),
      color: _color(call),
    );
    _refreshShelf(tags: true);
    return created;
  }

  Future<Object?> updateTag(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> updated = await _shelf.updateTag(
      _intParam(call, 'id'),
      name: call.optString('name'),
      color: _color(call),
    );
    _refreshShelf(tags: true);
    return updated;
  }

  Future<Object?> deleteTag(CtlCall call) async {
    _requireConfirm(call);
    _requireWritable();
    final Map<String, Object?> deleted = await _shelf.deleteTag(
      _intParam(call, 'id'),
    );
    _refreshShelf(tags: true);
    return deleted;
  }

  Future<Object?> itemTags(CtlCall call) => _shelf.itemTags(_key(call));

  Future<Object?> tagItem(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> result = await _shelf.addTags(
      _tagNames(call),
      key: _key(call),
      create: call.optBool('create') == true,
    );
    _refreshShelf(tags: true);
    return result;
  }

  Future<Object?> untagItem(CtlCall call) async {
    _requireWritable();
    final Map<String, Object?> result = await _shelf.removeTags(
      _tagNames(call),
      key: _key(call),
    );
    _refreshShelf(tags: true);
    return result;
  }

  // ── 书签 ─────────────────────────────────────────────────────────────

  Future<Object?> listBookmarks(CtlCall call) =>
      _shelf.listBookmarks(_key(call));

  Future<Object?> addBookmark(CtlCall call) async {
    _requireWritable();
    final Object? rawProgress = call.body['progress'] ?? call.query['progress'];
    final double? progress = rawProgress == null
        ? null
        : rawProgress is num
        ? rawProgress.toDouble()
        : double.tryParse('$rawProgress');
    if (rawProgress != null && progress == null) {
      throw const CtlFailure.badRequest('progress 必须是数字（章内百分比）');
    }
    return _shelf.addBookmark(
      _key(call),
      chapter: call.optInt('chapter'),
      page: call.optInt('page'),
      progressPercent: progress,
      label: call.optString('label'),
    );
  }

  Future<Object?> removeBookmark(CtlCall call) async {
    _requireWritable();
    return _shelf.removeBookmark(_intParam(call, 'id'));
  }

  // ── 收藏句 ───────────────────────────────────────────────────────────

  LibraryCtlKey? _optKey(CtlCall call) {
    final String? raw = call.optString('key');
    return raw == null ? null : _parseKeyText(raw);
  }

  Future<Object?> listFavorites(CtlCall call) =>
      _shelf.listFavorites(key: _optKey(call), limit: call.optInt('limit'));

  Future<Object?> removeFavorite(CtlCall call) async {
    _requireWritable();
    return _shelf.removeFavorite(call.params['id'] ?? '');
  }

  Future<Object?> clearFavorites(CtlCall call) async {
    _requireConfirm(call);
    _requireWritable();
    return _shelf.clearFavorites();
  }

  Future<Object?> exportFavorites(CtlCall call) async {
    final String path = call.requireString('path');
    if (!File(path).isAbsolute) {
      throw CtlFailure.badRequest('导出路径必须是绝对路径：$path');
    }
    final ExportFormat? format = parseLibraryCtlExportFormat(
      call.optString('format'),
    );
    if (format == null) {
      throw const CtlFailure.badRequest(
        'format 只能是 markdown / txt / csv / json',
      );
    }
    return _shelf.exportFavorites(
      outPath: path,
      format: format,
      key: _optKey(call),
      dedupe: call.optBool('dedupe') == true,
    );
  }

  // ── 改名 / 封面 / 读完 / 重置 ────────────────────────────────────────

  /// 书类条目的 [MediaItem]（改名覆盖层与封面 override 都按它的 mediaIdentifier
  /// 记账）：配对有声书走 EPUB 身份、纯字幕书走 `srtbook/<uid>` 身份——与书架
  /// `_srtBookMediaItem` 同一分派。
  Future<(MediaItem, String)> _bookItem(LibraryCtlKey key) async {
    switch (key.store) {
      case LibraryCtlStore.book:
        final MediaItem? item = await ReaderFushiSource.instance
            .mediaItemForBookKey(key.id);
        if (item == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        return (item, item.title);
      case LibraryCtlStore.srt:
        final SrtBook? srt = await SrtBookRepository(_db).findByUid(key.id);
        if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        if (srt.bookKey.isNotEmpty) {
          final MediaItem? item = await ReaderFushiSource.instance
              .mediaItemForBookKey(srt.bookKey);
          if (item != null) return (item, srt.title);
        }
        return (
          MediaItem(
            mediaIdentifier: ReaderFushiSource.mediaIdentifierForSrtUid(
              srt.uid,
            ),
            title: srt.title,
            author: srt.author,
            mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
            mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
            position: 0,
            duration: 1,
            canDelete: false,
            canEdit: true,
          ),
          srt.title,
        );
      case LibraryCtlStore.video:
      case LibraryCtlStore.game:
        throw StateError('not a book key: ${key.wire}');
    }
  }

  Future<Object?> renameItem(CtlCall call) async {
    _requireWritable();
    final LibraryCtlKey key = _key(call);
    final bool reset = call.optBool('reset') == true;
    final String? title = call.optString('title');
    if (!reset && title == null) {
      throw const CtlFailure.badRequest('title 缺失（或 reset: true 清除改名）');
    }
    switch (key.store) {
      case LibraryCtlStore.book:
      case LibraryCtlStore.srt:
        final (MediaItem item, String rawTitle) = await _bookItem(key);
        final MediaSource source = item.getMediaSource(appModel: _app);
        // 空标题 = 清除覆盖（setOverrideTitleFromMediaItem 的既有语义）。
        await source.setOverrideTitleFromMediaItem(
          item: item,
          title: reset ? null : title,
        );
        _refreshShelf();
        return <String, Object?>{
          'key': key.wire,
          'title': displayTitleForBook(item: item, rawTitle: rawTitle),
          'rawTitle': rawTitle,
        };
      case LibraryCtlStore.video:
        if (reset) {
          throw const CtlFailure.rejected('视频改名直接改标题，没有「恢复原名」');
        }
        final VideoBookRepository repo = VideoBookRepository(_db);
        if (await repo.getByBookUid(key.id) == null) {
          throw CtlFailure.notFound('视频库里没有 ${key.wire}');
        }
        await repo.updateTitle(key.id, title!.trim());
        return <String, Object?>{'key': key.wire, 'title': title.trim()};
      case LibraryCtlStore.game:
        throw const CtlFailure.rejected('游戏改名请用 game 命令');
    }
  }

  /// 把 body 的 `path`（本地图片）或 `url`（http/https，经全应用代理装配的客户端
  /// 下载到临时文件）交给 [apply]。
  Future<T> _withCoverSource<T>(
    CtlCall call,
    Future<T> Function(File image) apply,
  ) async {
    final String? path = call.optString('path');
    final String? url = call.optString('url');
    if ((path == null) == (url == null)) {
      throw const CtlFailure.badRequest('path（本地图片）与 url 二选一');
    }
    if (path != null) {
      if (!File(path).isAbsolute) {
        throw CtlFailure.badRequest('路径必须是绝对路径：$path');
      }
      final File file = File(path);
      if (!file.existsSync()) throw CtlFailure.notFound('图片不存在：$path');
      return apply(file);
    }
    final Uri? uri = Uri.tryParse(url!);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw CtlFailure.badRequest('url 只支持 http / https：$url');
    }
    final Directory tmp = await Directory.systemTemp.createTemp('fushi_cover_');
    try {
      final File downloaded = File(
        p.join(tmp.path, 'cover${p.extension(uri.path)}'),
      );
      final HttpClient client = createAppHttpClient();
      try {
        final HttpClientRequest request = await client.getUrl(uri);
        final HttpClientResponse response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw CtlFailure.conflict('下载封面失败：HTTP ${response.statusCode}');
        }
        await response.pipe(downloaded.openWrite());
      } on SocketException catch (e) {
        throw CtlFailure.conflict('下载封面失败：${e.message}');
      } finally {
        client.close(force: true);
      }
      return await apply(downloaded);
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  Future<Object?> itemCover(CtlCall call) async {
    _requireWritable();
    final LibraryCtlKey key = _key(call);
    final bool reset = call.optBool('reset') == true;
    switch (key.store) {
      case LibraryCtlStore.book:
      case LibraryCtlStore.srt:
        final (MediaItem item, String _) = await _bookItem(key);
        final MediaSource source = item.getMediaSource(appModel: _app);
        if (reset) {
          await MediaCoverService.applyBookCoverOverride(
            appModel: _app,
            mediaSource: source,
            item: item,
            file: null,
            clearOverrideImage: true,
          );
        } else {
          await _withCoverSource(call, (File image) async {
            await MediaCoverService.applyBookCoverOverride(
              appModel: _app,
              mediaSource: source,
              item: item,
              file: image,
              clearOverrideImage: false,
            );
          });
          // 校验不过的图片（不是完整可解码图片）会被静默拒写：按结果报，不谎报成功。
          if (source.resolveOverrideThumbnailFile(appModel: _app, item: item) ==
              null) {
            throw const CtlFailure.rejected('图片无法解码，封面没有更换');
          }
        }
        _refreshShelf();
        return <String, Object?>{'key': key.wire, 'reset': reset};
      case LibraryCtlStore.video:
        if (reset) {
          throw const CtlFailure.rejected('视频封面不支持清除，请换一张图');
        }
        final VideoBookRepository repo = VideoBookRepository(_db);
        if (await repo.getByBookUid(key.id) == null) {
          throw CtlFailure.notFound('视频库里没有 ${key.wire}');
        }
        final String dest = await _withCoverSource(call, (File image) async {
          try {
            return await MediaCoverService.applyVideoCoverManual(
              repo: repo,
              bookUid: key.id,
              pickedPath: image.path,
            );
          } on StateError catch (e) {
            throw CtlFailure.conflict('${e.message}，稍后再试');
          }
        });
        return <String, Object?>{'key': key.wire, 'cover': dest};
      case LibraryCtlStore.game:
        throw const CtlFailure.rejected('游戏封面请用 game 命令');
    }
  }

  Future<Object?> setCompleted(CtlCall call) async {
    _requireWritable();
    final bool? completed = call.optBool('completed');
    if (completed == null) throw const CtlFailure.badRequest('completed 缺失');
    final Map<String, Object?> result = await _shelf.setCompleted(
      _key(call),
      completed: completed,
      restoreCompletedAt: call.optInt('completedAt'),
      restorePositionMs: call.optInt('positionMs'),
    );
    _refreshShelf();
    return result;
  }

  /// 库页「重置阅读状态 / 清除观看进度」：位置归零 + 取消读完，`stats` 决定学习
  /// 记录（keep 不动 / last 撤最近一次会话 / all 全部清除）。
  Future<Object?> resetProgress(CtlCall call) async {
    _requireConfirm(call);
    _requireWritable();
    final LibraryCtlKey key = _key(call);
    final StudyRecordResetScope? records = parseLibraryCtlResetScope(
      call.optString('stats'),
    );
    if (records == null) {
      throw const CtlFailure.badRequest('stats 只能是 keep / last / all');
    }
    switch (key.store) {
      case LibraryCtlStore.book:
        final EpubBookRow? row = await _db.getEpubBook(key.id);
        if (row == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        final SrtBook? srt = await SrtBookRepository(_db).findByBookKey(key.id);
        await resetBookReadingState(
          db: _db,
          bookKey: key.id,
          title: row.title,
          extraStatKeys: <String>{if (srt != null) srt.uid},
          records: records,
        );
      case LibraryCtlStore.srt:
        final SrtBook? srt = await SrtBookRepository(_db).findByUid(key.id);
        if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
        if (srt.bookKey.isEmpty) {
          throw const CtlFailure.rejected('纯字幕书没有阅读进度可重置');
        }
        await resetBookReadingState(
          db: _db,
          bookKey: srt.bookKey,
          title: srt.title,
          extraStatKeys: <String>{srt.uid},
          records: records,
        );
      case LibraryCtlStore.video:
        final VideoBookRepository repo = VideoBookRepository(_db);
        final VideoBookRow? row = await repo.getByBookUid(key.id);
        if (row == null) throw CtlFailure.notFound('视频库里没有 ${key.wire}');
        await resetVideoWatchState(
          db: _db,
          repo: repo,
          bookUid: key.id,
          title: row.title,
          records: records,
        );
      case LibraryCtlStore.game:
        throw const CtlFailure.rejected('游戏没有阅读进度可重置');
    }
    _refreshShelf();
    return <String, Object?>{
      'key': key.wire,
      'reset': true,
      'stats': call.optString('stats') ?? 'keep',
    };
  }

  // ── 来源库 ───────────────────────────────────────────────────────────

  /// 来源页「添加本地文件夹」同一函数（登记后立即扫描）。
  Future<Object?> addSource(CtlCall call) async {
    _requireWritable();
    final String path = call.requireString('path');
    if (!File(path).isAbsolute) {
      throw CtlFailure.badRequest('路径必须是绝对路径：$path');
    }
    if (!Directory(path).existsSync()) {
      throw CtlFailure.notFound('目录不存在：$path');
    }
    final String kindRaw = call.requireString('kind');
    final SourceLibraryKind? kind = SourceLibraryKind.tryParse(kindRaw);
    if (kind == null) {
      throw CtlFailure.badRequest('来源种类只能是 book / video / manga，收到「$kindRaw」');
    }
    final LibraryCtlKind ctlKind = switch (kind) {
      SourceLibraryKind.book => LibraryCtlKind.book,
      SourceLibraryKind.video => LibraryCtlKind.video,
      SourceLibraryKind.manga => LibraryCtlKind.manga,
      // 命令行控制通道还没有音乐库命令（列条目 / 打开 / 删除都不认 music），只开
      // 「加来源」会造出一个 ctl 自己管不了的库，如实拒绝。
      SourceLibraryKind.music => throw CtlFailure.badRequest(
        '命令行暂不支持音乐来源，请在 app 的音乐库里添加',
      ),
    };
    if (!_app.moduleVisibility.isEnabled(ctlKind.module)) {
      throw CtlFailure.rejected('「${ctlKind.wireName}」所属模块已在设置里关闭');
    }
    final AddLocalFolderResult result = await addLocalFolderAsSource(
      db: _db,
      mediaKind: kind.dbValue,
      path: path,
    );
    _refreshShelf();
    return <String, Object?>{
      'added': result.outcome == AddLocalFolderOutcome.added,
      if (result.sourceId != null) 'id': result.sourceId,
      'path': result.rootPath,
      'kind': kind.dbValue,
    };
  }

  Future<MediaSourceRow> _requireSource(int id) async {
    final MediaSourceRow? row = await _db.getMediaSourceById(id);
    if (row == null) throw CtlFailure.notFound('没有 id=$id 的来源');
    return row;
  }

  Future<Object?> renameSource(CtlCall call) async {
    _requireWritable();
    final int id = _intParam(call, 'id');
    await _requireSource(id);
    final String label = call.requireString('label');
    await _db.updateMediaSourceLabel(id, label);
    return <String, Object?>{'id': id, 'label': label};
  }

  /// 来源页「移除来源」同一函数：条目保留（source_id 归空）；视频下载订阅 / 未整理
  /// 任务迁到 `migrateTo` 指定的视频来源，没给就停用（与移除对话框不选迁移一致）。
  Future<Object?> removeSource(CtlCall call) async {
    _requireConfirm(call);
    _requireWritable();
    final int id = _intParam(call, 'id');
    final MediaSourceRow row = await _requireSource(id);
    final int? migrateTo = call.optInt('migrateTo');
    try {
      await removeSourceLibrary(
        database: _db,
        prefs: _app.prefsRepo,
        sourceId: id,
        migrateVideoDownloadsTo: migrateTo,
        disableVideoDownloadSubscriptions: migrateTo == null,
        videoDownloadPipeline: _app.videoDownloadPipelineService,
      );
    } on ArgumentError {
      throw CtlFailure.badRequest('migrateTo=$migrateTo 不是另一个视频来源');
    }
    _refreshShelf();
    return <String, Object?>{
      'deleted': true,
      'id': id,
      'label': row.label,
      if (migrateTo != null) 'migratedTo': migrateTo,
    };
  }
}
