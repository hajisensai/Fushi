/// 在线源条目跨设备同步的 app 侧：读出本机清单、把别的设备的清单并进本机库
/// （拍板台 mY5VWg1nD-；清单与通道见 `fushi_engine/lib/sync/online_library_sync.dart`）。
///
/// 范围（所有者 2026-11-23：「不只是书库，媒体都弄上」）：
/// - 在线漫画书架条目（Mihon / 网页漫画 / Kavita；Aidoku 已移除、互联漫画指向的就是
///   对端自己的库，二者不同步）；
/// - 在线小说占位书（LNReader）；
/// - 网络视频行：在线视频源（`anime-source://`）、媒体服务器（`media-server://`）、
///   流媒体书（`video/stream/` 身份族的 http 地址）；
/// - 远程音乐曲目（YouTube / 插件 / 服务器，`music_remote_tracks`）。
///
/// 只同步条目，不传内容：漫画章表、小说正文、封面都由收到的设备按需从来源取。
/// 在线漫画的章表不进清单（上千话的作品一份描述符就几百 KB），收到的设备打开作品页
/// 时照常刷新章表（空章表的首次刷新不算「新章」，不会触发提醒与自动下载）。
///
/// 并入规则：
/// - 书 / 视频**只增不删**。本机账本记着「见过的条目 → 见过的最大 addedAt」：本机
///   没有、账本也没有 = 对端新加的，建；本机没有、账本有且对端的 addedAt 没变大 =
///   本机删掉的（「仅本机删除」不写墓碑），不建回；对端删了又重新加（addedAt 变大）
///   照常建。本机「从所有设备删除」留下的墓碑同样挡住删除之前就有的那条。跨设备删除
///   仍由既有的删除墓碑通道负责，这里不传播删除。
/// - 音乐曲目按 `updatedAt` 整行 LWW（表就是为备份合并按 LWW 设计的，「移出音乐库」
///   = 清 `libraryAddedAt`，照样随 LWW 传播）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart'
    show DuplicatePolicy;
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/stream_video_sync.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show downloadVideoCoverToPath, videoCoverFileName;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/sync/online_library_sync.dart';
import 'package:fushi_engine/sync/online_novel_book.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_row.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart'
    show lnReaderBookIdentifier, lnReaderSafeFileName, stripLnReaderHtml;
import 'package:fushi/src/media/novel/online/lnreader_models.dart'
    show LnReaderChapter;
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/models/preference_keys.dart'
    show kOnlineLibraryLedgerPrefKey;
import 'package:fushi/src/media/video/online/anime_source_library.dart'
    show AnimeSourceBookSpec;
import 'package:fushi/src/storage/download_layout.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 同步的在线漫画运行时（见库注释）。
bool isSyncableOnlineMangaRuntime(OnlineMangaRuntimeKind runtime) =>
    switch (runtime) {
      OnlineMangaRuntimeKind.mihon ||
      OnlineMangaRuntimeKind.web ||
      OnlineMangaRuntimeKind.kavita => true,
      OnlineMangaRuntimeKind.aidoku ||
      OnlineMangaRuntimeKind.interconnect => false,
    };

/// 这条视频行是否是同步的网络视频行（见库注释）。
bool isSyncableOnlineVideo({
  required String bookUid,
  required String videoPath,
}) =>
    isAnimeSourceVideoPath(videoPath) ||
    isMediaServerVideoPath(videoPath) ||
    isSyncableStreamVideo(bookUid: bookUid, videoPath: videoPath);

/// 在线小说的跨设备身份（bookKey 由书名派生、同名会加后缀，不能当身份）。
String onlineNovelItemKey(String pluginId, String novelPath) =>
    '$pluginId\u001f$novelPath';

/// 读出本机的在线源条目清单。
Future<OnlineLibraryManifest> buildLocalOnlineLibraryManifest(
  FushiDatabase db, {
  required String deviceId,
}) async {
  final List<OnlineLibraryItem> items = <OnlineLibraryItem>[];
  for (final EpubBookRow row in await _onlineBookRows(db)) {
    final OnlineLibraryItem? item = _mangaItemOf(row) ?? _novelItemOf(row);
    if (item != null) items.add(item);
  }
  for (final VideoBookRow row in await _networkVideoRows(db)) {
    if (!isSyncableOnlineVideo(
      bookUid: row.bookUid,
      videoPath: row.videoPath,
    )) {
      continue;
    }
    items.add(
      OnlineLibraryItem(
        kind: OnlineLibraryItemKind.video,
        key: row.bookUid,
        title: row.title,
        addedAt: row.importedAt ?? 0,
        payload: <String, Object?>{
          'videoPath': row.videoPath.trim(),
          if (row.streamSpecJson != null) 'spec': row.streamSpecJson,
        },
      ),
    );
  }
  final List<MusicRemoteTrackRow> tracks =
      await (db.select(db.musicRemoteTracks)..where(
            ($MusicRemoteTracksTable t) =>
                t.libraryAddedAt.isNotNull() |
                t.updatedAt.equalsExp(t.createdAt).not(),
          ))
          .get();
  for (final MusicRemoteTrackRow row in tracks) {
    items.add(
      OnlineLibraryItem(
        kind: OnlineLibraryItemKind.music,
        key: row.trackUid,
        title: row.title,
        addedAt: row.libraryAddedAt ?? 0,
        updatedAt: row.updatedAt,
        payload: row.toJson(),
      ),
    );
  }
  return OnlineLibraryManifest(deviceId: deviceId, items: items);
}

/// 一次并入的结果。
class OnlineLibraryApplyResult {
  const OnlineLibraryApplyResult({
    required this.changed,
    required this.errors,
    required this.followUps,
  });

  /// 本机新建 / 改动的条目数。
  final int changed;

  /// 逐条失败（标题 + 原因），调用方记进同步报告；失败的条目下一轮重来。
  final List<String> errors;

  /// 要联网的收尾（封面）：调用方在**放开同步状态锁之后**跑，尽力而为。
  final List<Future<void> Function()> followUps;
}

/// 把别的设备的清单并进本机库（规则见库注释）。调用方持同步状态锁。
class OnlineLibraryApplier {
  OnlineLibraryApplier(
    this._db, {
    Future<DownloadLayout> Function()? downloadLayout,
    Future<Directory> Function()? videoCoversDir,
    String Function()? novelPendingText,
  }) : _downloadLayout = downloadLayout ?? DownloadRoot.current,
       _videoCoversDir = videoCoversDir ?? VideoStorage.coversDir,
       _novelPendingText =
           novelPendingText ?? (() => t.novel_online_chapter_pending);

  final FushiDatabase _db;
  final Future<DownloadLayout> Function() _downloadLayout;
  final Future<Directory> Function() _videoCoversDir;
  final String Function() _novelPendingText;

  /// [manifests] 里 [ownDeviceId] 的那份（本机自己上次发布的）不并。
  Future<OnlineLibraryApplyResult> apply(
    Iterable<OnlineLibraryManifest> manifests, {
    required String ownDeviceId,
  }) async {
    final Map<String, int> ledger = await _loadLedger();
    final _LocalPresence local = await _LocalPresence.load(_db);
    // 本机现有的条目都算见过（含本机自己加的、已下载成本地视频的在线集）。
    final OnlineLibraryManifest own = await buildLocalOnlineLibraryManifest(
      _db,
      deviceId: ownDeviceId,
    );
    for (final OnlineLibraryItem item in own.items) {
      _remember(ledger, item.ledgerKey, item.addedAt);
    }

    // 同一条出现在多份清单里：书 / 视频取 addedAt 最大的，音乐取 updatedAt 最大的。
    final Map<String, OnlineLibraryItem> incoming =
        <String, OnlineLibraryItem>{};
    for (final OnlineLibraryManifest m in manifests) {
      if (ownDeviceId.isNotEmpty && m.deviceId == ownDeviceId) continue;
      for (final OnlineLibraryItem item in m.items) {
        final OnlineLibraryItem? prev = incoming[item.ledgerKey];
        final bool newer = item.kind == OnlineLibraryItemKind.music
            ? prev == null || item.updatedAt > prev.updatedAt
            : prev == null || item.addedAt > prev.addedAt;
        if (newer) incoming[item.ledgerKey] = item;
      }
    }

    final Map<String, int> bookTombstones = await _db
        .getSyncDeletionDeletedAtByKey(SyncTombstoneKind.book.dbValue);
    final Map<String, int> videoTombstones = await _db
        .getSyncDeletionDeletedAtByKey(SyncTombstoneKind.video.dbValue);

    int changed = 0;
    bool musicChanged = false;
    final List<String> errors = <String>[];
    final List<Future<void> Function()> followUps = <Future<void> Function()>[];
    final List<OnlineLibraryItem> ordered = incoming.values.toList()
      ..sort(
        (OnlineLibraryItem a, OnlineLibraryItem b) =>
            a.ledgerKey.compareTo(b.ledgerKey),
      );
    for (final OnlineLibraryItem item in ordered) {
      try {
        if (item.kind == OnlineLibraryItemKind.music) {
          if (await _applyMusic(item)) {
            changed++;
            musicChanged = true;
          }
          continue;
        }
        if (local.contains(item)) {
          _remember(ledger, item.ledgerKey, item.addedAt);
          continue;
        }
        final int? known = ledger[item.ledgerKey];
        if (known != null && item.addedAt <= known) continue;
        final int? deletedAt = switch (item.kind) {
          OnlineLibraryItemKind.manga => bookTombstones[item.key],
          OnlineLibraryItemKind.video => videoTombstones[item.key],
          _ => null,
        };
        if (deletedAt != null && deletedAt >= item.addedAt) continue;
        final bool created = switch (item.kind) {
          OnlineLibraryItemKind.manga => await _createManga(item),
          OnlineLibraryItemKind.novel => await _createNovel(item),
          OnlineLibraryItemKind.video => await _createVideo(item, followUps),
          OnlineLibraryItemKind.music => false,
        };
        if (!created) continue;
        local.add(item);
        _remember(ledger, item.ledgerKey, item.addedAt);
        changed++;
      } catch (e) {
        errors.add('"${item.title}" (${item.kind.wire}): $e');
      }
    }
    await _saveLedger(ledger);
    // 对端较新的曲目行可能清了入库时刻（那边移出了音乐库）：本机有离线副本（v175，设备
    // 本地的事实，下载 ⊂ 音乐库）的放回曲库，与备份合并导入同一个对账口；它不动
    // `updated_at`，所以不会反过来把「放回」当成新编辑传回对端。
    if (musicChanged) {
      await _db.reconcileMusicServerDownloadsIntoLibrary(
        at: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return OnlineLibraryApplyResult(
      changed: changed,
      errors: errors,
      followUps: followUps,
    );
  }

  static void _remember(Map<String, int> ledger, String key, int addedAt) {
    final int? prev = ledger[key];
    if (prev == null || addedAt > prev) ledger[key] = addedAt;
  }

  Future<Map<String, int>> _loadLedger() async {
    final String? raw = await _db.getPref(kOnlineLibraryLedgerPrefKey);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      return <String, int>{
        for (final MapEntry<Object?, Object?> e in decoded.entries)
          if (e.key is String && e.value is num)
            e.key! as String: (e.value! as num).toInt(),
      };
    } on FormatException {
      // 坏账本当空：最坏是本机删过的条目被对端补回一次，不丢数据。
      return <String, int>{};
    }
  }

  Future<void> _saveLedger(Map<String, int> ledger) => _db.setPref(
    kOnlineLibraryLedgerPrefKey,
    jsonEncode(
      Map<String, int>.fromEntries(
        ledger.entries.toList()..sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              a.key.compareTo(b.key),
        ),
      ),
    ),
  );

  Future<bool> _createManga(OnlineLibraryItem item) async {
    final Object? rawEntry = item.payload['entry'];
    final OnlineMangaLibraryEntry? entry = rawEntry is Map
        ? OnlineMangaLibraryEntry.tryParse(jsonEncode(rawEntry))
        : null;
    if (entry == null ||
        !isSyncableOnlineMangaRuntime(entry.runtime) ||
        onlineMangaBookKeyOf(entry) != item.key) {
      throw const FormatException('bad online manga descriptor');
    }
    final Directory directory = Directory(
      (await _downloadLayout()).mangaBookPath(item.key),
    );
    await Directory(p.join(directory.path, 'chapters')).create(recursive: true);
    final File placeholder = File(
      p.join(directory.path, MangaStorage.kMangaJsonFileName),
    );
    // 目录可能是本机「删书保留章节」留下的：已有的 manga.json 不覆盖。
    if (!await placeholder.exists()) {
      await placeholder.writeAsString('{"pages":[]}', flush: true);
    }
    // uid 跟着条目走，合集 / 标签 / 进度的跨端身份才对得上；本机已被别的书占用
    // （不该发生）时退回新生成。
    final Object? uid = item.payload['uid'];
    final bool uidFree =
        uid is String &&
        uid.isNotEmpty &&
        await _db.getEpubBookByUid(uid) == null;
    final Object? author = item.payload['author'];
    await insertOnlineMangaShelfRow(
      _db,
      entry: entry,
      title: item.title.isEmpty ? entry.series.title : item.title,
      author: author is String ? author : entry.series.byline,
      coverPath: null,
      epubPath: MangaStorage.kMangaJsonFileName,
      extractDir: directory.path,
      importedAt: item.addedAt,
      uid: uidFree ? uid : '',
    );
    return true;
  }

  Future<bool> _createNovel(OnlineLibraryItem item) async {
    final Object? rawDescriptor = item.payload['descriptor'];
    final LnReaderOnlineBookDescriptor? descriptor = rawDescriptor is Map
        ? LnReaderOnlineBookDescriptor.tryParse(jsonEncode(rawDescriptor))
        : null;
    if (descriptor == null ||
        descriptor.chapters.isEmpty ||
        onlineNovelItemKey(descriptor.pluginId, descriptor.novelPath) !=
            item.key) {
      throw const FormatException('bad online novel descriptor');
    }
    final Object? language = item.payload['language'];
    final String title = item.title.trim().isEmpty
        ? descriptor.chapters.first.name
        : item.title.trim();
    final String? summary = descriptor.details.summary;
    final Uint8List bytes = await buildLnReaderOnlineEpubInBackground(
      LnReaderOnlineEpubRequest(
        title: title,
        languageTag: language is String && language.isNotEmpty
            ? language
            : 'und',
        identifier: lnReaderBookIdentifier(
          descriptor.pluginId,
          descriptor.novelPath,
        ),
        author: descriptor.details.author,
        description: summary == null ? null : stripLnReaderHtml(summary),
        chapters: <({String name, String path})>[
          for (final LnReaderChapter c in descriptor.chapters)
            (name: c.name, path: c.path),
        ],
        pendingText: _novelPendingText(),
      ),
    );
    final String bookKey = await EpubImporter.import(
      db: _db,
      bytes: bytes,
      fileName: '${lnReaderSafeFileName(title)}.epub',
      // 程序化入库：与同名书并存（加后缀），与在线小说首次入库同口径。
      policy: const DuplicatePolicy.suffix(),
    );
    await (_db.update(
      _db.epubBooks,
    )..where(($EpubBooksTable t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(
        sourceMetadata: Value<String?>(descriptor.encode()),
        importedAt: Value<int>(item.addedAt),
      ),
    );
    return true;
  }

  Future<bool> _createVideo(
    OnlineLibraryItem item,
    List<Future<void> Function()> followUps,
  ) async {
    final Object? path = item.payload['videoPath'];
    final Object? spec = item.payload['spec'];
    if (path is! String ||
        !isSyncableOnlineVideo(bookUid: item.key, videoPath: path) ||
        (spec != null &&
            (spec is! String || spec.length > kStreamVideoSpecMaxChars * 4))) {
      throw const FormatException('bad online video entry');
    }
    await _db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(item.key),
        title: Value<String>(item.title.isEmpty ? item.key : item.title),
        videoPath: Value<String>(path),
        streamSpecJson: Value<String?>(spec as String?),
        importedAt: Value<int?>(item.addedAt),
      ),
    );
    final String uid = item.key;
    followUps.add(() => _backfillVideoCover(uid, path, spec));
    return true;
  }

  /// 封面尽力而为：在线视频源取作品缩略图，YouTube 取视频缩略图；媒体服务器的
  /// 图要带凭据现算，留给播放 / 刮削按本机配置补。
  Future<void> _backfillVideoCover(
    String bookUid,
    String path,
    String? spec,
  ) async {
    try {
      final Directory coversDir = await _videoCoversDir();
      if (isAnimeSourceVideoPath(path)) {
        final String? url = AnimeSourceBookSpec.tryParse(spec)?.anime.coverUrl;
        if (url == null || url.isEmpty) return;
        final VideoBookRow? row = await _db.getVideoBookByBookUid(bookUid);
        if (row == null || (row.coverPath?.isNotEmpty ?? false)) return;
        final String? cover = await downloadVideoCoverToPath(
          coverUrl: url,
          outputPath: p.join(coversDir.path, videoCoverFileName(bookUid)),
        );
        if (cover != null) await _db.updateVideoBookCover(bookUid, cover);
        return;
      }
      if (isSyncableStreamVideo(bookUid: bookUid, videoPath: path)) {
        await backfillStreamVideoThumbnailCover(
          _db,
          bookUid: bookUid,
          url: path,
          coversDir: coversDir,
        );
      }
    } catch (e) {
      debugPrint('[OnlineLibraryApplier] cover "$bookUid": $e');
    }
  }

  /// 音乐曲目整行 LWW。本机没有、对端也不在曲库里的行（只被对端歌单引用过）不建。
  Future<bool> _applyMusic(OnlineLibraryItem item) async {
    final MusicRemoteTrackRow remote = MusicRemoteTrackRow.fromJson(
      item.payload,
    );
    if (remote.trackUid != item.key) {
      throw const FormatException('bad music track entry');
    }
    final MusicRemoteTrackRow? local = await _db.getMusicRemoteTrack(item.key);
    if (local == null) {
      if (remote.libraryAddedAt == null) return false;
      await _db.into(_db.musicRemoteTracks).insert(remote);
      return true;
    }
    if (remote.updatedAt <= local.updatedAt) return false;
    await _db
        .into(_db.musicRemoteTracks)
        // toCompanion(false)：显式写 null（移出音乐库 = libraryAddedAt 置空），
        // 数据类直插会把 null 当「不改」。
        .insertOnConflictUpdate(
          remote.copyWith(createdAt: local.createdAt).toCompanion(false),
        );
    return true;
  }
}

/// app 当互联 host 时的本机参与方（装进 `LocalLibraryHostService`）。
class AppOnlineLibraryParticipant implements OnlineLibraryParticipant {
  AppOnlineLibraryParticipant(this._db, {OnlineLibraryApplier? applier})
    : _applier = applier ?? OnlineLibraryApplier(_db);

  final FushiDatabase _db;
  final OnlineLibraryApplier _applier;

  @override
  Future<String> onlineLibraryDeviceId() =>
      SyncRepository(_db).getOrCreateDeviceId();

  @override
  Future<OnlineLibraryManifest> loadLocalOnlineLibraryManifest() async =>
      buildLocalOnlineLibraryManifest(
        _db,
        deviceId: await onlineLibraryDeviceId(),
      );

  @override
  Future<int> applyOnlineLibraryManifests(
    List<OnlineLibraryManifest> manifests,
  ) async {
    final OnlineLibraryApplyResult result = await _applier.apply(
      manifests,
      ownDeviceId: await onlineLibraryDeviceId(),
    );
    for (final String error in result.errors) {
      debugPrint('[OnlineLibrary] host apply: $error');
    }
    // 封面要联网：不占着同步状态锁（host 端调用方持锁），放到后台尽力而为。
    unawaited(runOnlineLibraryFollowUps(result.followUps));
    return result.changed;
  }
}

/// 依次跑 [OnlineLibraryApplyResult.followUps]（各自已吞错）。
Future<void> runOnlineLibraryFollowUps(
  List<Future<void> Function()> followUps,
) async {
  for (final Future<void> Function() job in followUps) {
    await job();
  }
}

Future<List<EpubBookRow>> _onlineBookRows(FushiDatabase db) =>
    (db.select(db.epubBooks)..where(
          ($EpubBooksTable t) =>
              t.sourceMetadata.like('%${OnlineMangaLibraryEntry.marker}%') |
              t.sourceMetadata.like(
                '%${OnlineMangaLibraryEntry.legacyMihonMarker}%',
              ) |
              t.sourceMetadata.like('%$kLnReaderOnlineBookMarker%'),
        ))
        .get();

Future<List<VideoBookRow>> _networkVideoRows(FushiDatabase db) => (db.select(
  db.videoBooks,
)..where(($VideoBooksTable t) => t.videoPath.like('%://%'))).get();

OnlineLibraryItem? _mangaItemOf(EpubBookRow row) {
  final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
    row.sourceMetadata,
  );
  if (entry == null || !isSyncableOnlineMangaRuntime(entry.runtime)) {
    return null;
  }
  return OnlineLibraryItem(
    kind: OnlineLibraryItemKind.manga,
    key: onlineMangaBookKeyOf(entry),
    title: row.title,
    addedAt: row.importedAt,
    payload: <String, Object?>{
      'entry': entry
          .copyWith(
            chapters: const <OnlineMangaChapter>[],
            clearCurrentChapter: true,
          )
          .toJson(),
      if (row.uid.isNotEmpty) 'uid': row.uid,
      if (row.author != null) 'author': row.author,
    },
  );
}

OnlineLibraryItem? _novelItemOf(EpubBookRow row) {
  if (!isLnReaderOnlineBookMetadata(row.sourceMetadata)) return null;
  final LnReaderOnlineBookDescriptor? descriptor =
      LnReaderOnlineBookDescriptor.tryParse(row.sourceMetadata);
  if (descriptor == null || descriptor.chapters.isEmpty) return null;
  return OnlineLibraryItem(
    kind: OnlineLibraryItemKind.novel,
    key: onlineNovelItemKey(descriptor.pluginId, descriptor.novelPath),
    title: row.title,
    addedAt: row.importedAt,
    payload: <String, Object?>{
      'descriptor': jsonDecode(descriptor.encode()),
      if (row.language != null) 'language': row.language,
    },
  );
}

/// 本机已有哪些条目（按 DB 判，不按清单：下载成本地视频的在线集、描述符坏了的书
/// 都不在清单里，但同一身份的行在，不能再建一条）。
class _LocalPresence {
  _LocalPresence(this._bookKeys, this._videoUids, this._novelKeys);

  final Set<String> _bookKeys;
  final Set<String> _videoUids;
  final Set<String> _novelKeys;

  static Future<_LocalPresence> load(FushiDatabase db) async {
    final Set<String> bookKeys = <String>{
      for (final TypedResult r in await (db.selectOnly(
        db.epubBooks,
      )..addColumns(<Expression<Object>>[db.epubBooks.bookKey])).get())
        r.read(db.epubBooks.bookKey)!,
    };
    final Set<String> videoUids = <String>{
      for (final TypedResult r in await (db.selectOnly(
        db.videoBooks,
      )..addColumns(<Expression<Object>>[db.videoBooks.bookUid])).get())
        r.read(db.videoBooks.bookUid)!,
    };
    final Set<String> novelKeys = <String>{};
    for (final EpubBookRow row in await _onlineBookRows(db)) {
      final LnReaderOnlineBookDescriptor? d =
          LnReaderOnlineBookDescriptor.tryParse(row.sourceMetadata);
      if (d != null) novelKeys.add(onlineNovelItemKey(d.pluginId, d.novelPath));
    }
    return _LocalPresence(bookKeys, videoUids, novelKeys);
  }

  bool contains(OnlineLibraryItem item) => switch (item.kind) {
    OnlineLibraryItemKind.manga => _bookKeys.contains(item.key),
    OnlineLibraryItemKind.video => _videoUids.contains(item.key),
    OnlineLibraryItemKind.novel => _novelKeys.contains(item.key),
    OnlineLibraryItemKind.music => false,
  };

  void add(OnlineLibraryItem item) {
    switch (item.kind) {
      case OnlineLibraryItemKind.manga:
        _bookKeys.add(item.key);
      case OnlineLibraryItemKind.video:
        _videoUids.add(item.key);
      case OnlineLibraryItemKind.novel:
        _novelKeys.add(item.key);
      case OnlineLibraryItemKind.music:
        break;
    }
  }
}
