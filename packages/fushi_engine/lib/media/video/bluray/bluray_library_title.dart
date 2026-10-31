import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discRootForMemberPath, isDiscMemberPath;
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 2026-10-08 原盘菜单首版给菜单标题起的名字（`盘目录名 · MPLS 号`）。它绕过了盘内
/// 标题，刮削拿它去搜什么都搜不到；遇到这个形状的存量行就改回 [blurayMenuTitleName]。
String _legacyMenuTitleName(String discRootPath, String playlistId) =>
    '${p.basename(p.normalize(discRootPath))} · $playlistId';

/// [videoPath] 是不是盘根为 [normalizedRoot] 的那张原盘上的成员（蓝光 / DVD 同一判据）。
bool _onDisc(String videoPath, String normalizedRoot) {
  final String? root = discRootForMemberPath(videoPath);
  return root != null && normalizeVideoPath(root) == normalizedRoot;
}

/// 盘上的标题 / 特典 [playlistPath] 在库里的那一行；没有就按扫描导入的规则建。
/// 单条入口（原盘菜单进入某条标题时用），批量与规则见
/// [ensureBlurayDiscTitlesInLibrary]。不是盘内 MPLS 路径时返回 null。
Future<VideoBookRow?> ensureBlurayTitleInLibrary(
  FushiDatabase db,
  String playlistPath, {
  int? sourceId,
}) async {
  final String? discRoot = blurayDiscRootForPlaylistPath(playlistPath);
  if (discRoot == null || !isBlurayPlaylistPath(playlistPath)) return null;
  final List<VideoBookRow> rows = await ensureBlurayDiscTitlesInLibrary(
    db,
    discRoot: discRoot,
    playlistPaths: <String>[playlistPath],
    sourceId: sourceId,
  );
  return rows.isEmpty ? null : rows.single;
}

/// 一张盘上的多条标题 / 特典 [playlistPaths] 按扫描导入的规则入库，返回与入参同序
/// 的库行：来源（`sourceId`）取 [sourceId]，没给时继承同盘已入库的标题；名字取盘内
/// 标题。扫描选中的**标题**加入这张盘的合集；**特典**（菜单里的「特典映像」等）只
/// 入库、不进盘合集——它们挂在正片作品下，进合集会把单片盘变成多成员合集。
///
/// 刮削的每一道入口都按来源挑条目，没有来源的行在结构上进不了任何刮削计划——这正
/// 是菜单首版手写建行时「明明是蓝光却刮不出来」的根因。已有的行只补缺（来源为空才
/// 补、标题不在合集才加、首版自动名才改名），幂等，不动用户改过的标题与进度。
///
/// 一张盘只读一次、一个事务、全库只列一次（PR #2058 审查：旧实现按特典逐条调用，
/// 每条都重读整盘 MPLS、在事务里全表 `listAll`、再逐成员查库判合集归属）。调用方
/// 手里已有读好的 [disc]（扫描器）就传进来，省掉这次读盘。
Future<List<VideoBookRow>> ensureBlurayDiscTitlesInLibrary(
  FushiDatabase db, {
  required String discRoot,
  required List<String> playlistPaths,
  BlurayDisc? disc,
  int? sourceId,
}) async {
  final List<String> paths = <String>[
    for (final String path in playlistPaths)
      if (isBlurayPlaylistPath(path)) path,
  ];
  if (paths.isEmpty) return const <VideoBookRow>[];
  // 读盘在事务外：META / MPLS 解析是文件 IO，不该占着写锁。
  final BlurayDisc? read = disc ?? await readBlurayDisc(discRoot);
  final Map<String, BlurayTitle> titleById = <String, BlurayTitle>{
    for (final BlurayTitle t in read?.titles ?? const <BlurayTitle>[])
      t.playlist.id: t,
  };
  final String discName = read?.name ?? await readBlurayDiscName(discRoot);
  final VideoBookRepository repo = VideoBookRepository(db);
  final String root = normalizeVideoPath(discRoot);
  return db.transaction(() async {
    final List<VideoBookRow> books = await repo.listAll();
    final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{};
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{};
    final List<VideoBookRow> onDisc = <VideoBookRow>[];
    for (final VideoBookRow book in books) {
      byUid[book.bookUid] = book;
      if (!_onDisc(book.videoPath, root)) continue;
      onDisc.add(book);
      byPath.putIfAbsent(normalizeVideoPath(book.videoPath), () => book);
    }
    final Set<String> targets = <String>{
      for (final String path in paths) normalizeVideoPath(path),
    };
    final int? owner =
        sourceId ??
        onDisc
            .where(
              (VideoBookRow b) =>
                  !targets.contains(normalizeVideoPath(b.videoPath)),
            )
            .map((VideoBookRow b) => b.sourceId)
            .firstWhere((int? id) => id != null, orElse: () => null);
    final Set<String> taken = byUid.keys.toSet();
    int? collectionId;
    bool collectionResolved = false;

    final List<String> uids = <String>[];
    for (final String path in paths) {
      final String key = normalizeVideoPath(path);
      final String playlistId = p.basenameWithoutExtension(path);
      final BlurayTitle? title = titleById[playlistId];
      final String name =
          title?.name ?? blurayMenuTitleName(discName, playlistId);
      final VideoBookRow? row = byPath[key];
      final String uid;
      if (row == null) {
        uid = coreUniqueVideoBookUid(coreSingleVideoBookUid(path), taken);
        taken.add(uid);
        await repo.saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value(uid),
            title: Value(name),
            videoPath: Value(path),
            importedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
          sourceId: owner,
        );
        // 同一批里同一路径出现两次：第二次复用这行。
        final VideoBookRow created = (await repo.getByBookUid(uid))!;
        byPath[key] = created;
      } else {
        uid = row.bookUid;
        final int? rowOwner = row.sourceId ?? sourceId ?? owner;
        if (row.sourceId == null && rowOwner != null) {
          await repo.assignSourceIfNull(row.bookUid, rowOwner);
        }
        if (row.title == _legacyMenuTitleName(discRoot, playlistId)) {
          await repo.updateTitle(row.bookUid, name);
        }
      }
      uids.add(uid);
      if (title == null) continue;
      if (!collectionResolved) {
        collectionResolved = true;
        collectionId = await _discCollectionId(
          db,
          <String>{for (final VideoBookRow b in onDisc) b.bookUid},
          byUid,
          root,
        );
      }
      if (collectionId != null) {
        await db.addToCollection(
          collectionId,
          MediaKind.video,
          uid,
          userIntent: false,
        );
      }
    }
    return <VideoBookRow>[
      for (final String uid in uids) (await repo.getByBookUid(uid))!,
    ];
  });
}

/// 这张盘的合集：扫描导入建的 `playlist` 合集，以同盘已入库标题的成员身份认出，
/// 且成员全是本盘标题（与扫描器 `_collectionBelongsToDisc` 同一判据——收了本盘
/// mpls 的 m3u8 清单合集不算）。盘还没被扫描导入过时没有合集，返回 null。
///
/// [booksByUid] 是调用方已列好的全库行，判成员归属不再逐条查库。
Future<int?> _discCollectionId(
  FushiDatabase db,
  Set<String> discUids,
  Map<String, VideoBookRow> booksByUid,
  String normalizedRoot,
) async {
  if (discUids.isEmpty) return null;
  final List<MediaCollectionItemRow> all = await db.getAllCollectionItems();
  final Map<int, List<MediaCollectionItemRow>> byCollection =
      <int, List<MediaCollectionItemRow>>{};
  for (final MediaCollectionItemRow item in all) {
    byCollection
        .putIfAbsent(item.collectionId, () => <MediaCollectionItemRow>[])
        .add(item);
  }
  final List<int> candidates = <int>{
    for (final MediaCollectionItemRow item in all)
      if (item.mediaType == MediaKind.video.dbValue &&
          discUids.contains(item.entryKey))
        item.collectionId,
  }.toList()..sort();
  for (final int id in candidates) {
    final MediaCollectionRow? collection = await db.getMediaCollectionById(id);
    if (collection?.collectionType != 'playlist') continue;
    final bool allOnDisc = byCollection[id]!.every((MediaCollectionItemRow i) {
      final VideoBookRow? row = booksByUid[i.entryKey];
      return row == null || _onDisc(row.videoPath, normalizedRoot);
    });
    if (allOnDisc) return id;
  }
  return null;
}

/// 盘特典的删除墓碑键：盘合集自然键下的成员墓碑，entryKey 取特典的稳定基身份
/// （[coreSingleVideoBookUid]，与合集重扫对齐 [VideoBookRepository.reconcileSplitPlaylist]
/// 同一身份口径；一张盘内 MPLS 号唯一）。
String blurayExtraTombstoneKey(String playlistPath) =>
    coreSingleVideoBookUid(playlistPath);

/// 一条待写的特典删除墓碑。
typedef BlurayExtraDeletionTombstone = ({
  String bookUid,
  String collectionName,
  String entryKey,
});

/// 用户删除 [bookUids] **之前**调用：认出其中的原盘特典（蓝光盘内 `.mpls` / DVD
/// `TITLE_nn.dvdtitle`、不是任何合集成员——标题都在盘合集里），返回它们该记的删除墓碑。
///
/// 特典不进盘合集，删掉它不会留下任何成员墓碑；下一次重扫又按 `disc.extras` 原样
/// 建回来（PR #2058 审查）。墓碑挂在盘合集的自然键下：扫描器导入特典前按它跳过；
/// 整盘合集被删时 [FushiDatabase.deleteMediaCollection] 会清掉这些成员墓碑、改记合集级
/// 墓碑，扫描器同样尊重。删除前算（删后合集成员关系就没了），删成功后再
/// [writeBlurayExtraDeletionTombstones]。
Future<List<BlurayExtraDeletionTombstone>> planBlurayExtraDeletionTombstones(
  FushiDatabase db,
  Iterable<String> bookUids,
) async {
  final List<VideoBookRow> targets = <VideoBookRow>[];
  for (final String uid in bookUids.toSet()) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(uid);
    // 蓝光与 DVD 的特典同一套墓碑（盘合集自然键 + 成员基身份）。
    if (row != null && isDiscMemberPath(row.videoPath)) targets.add(row);
  }
  if (targets.isEmpty) return const <BlurayExtraDeletionTombstone>[];
  final List<MediaCollectionItemRow> items = await db.getAllCollectionItems();
  final Set<String> members = <String>{
    for (final MediaCollectionItemRow item in items)
      if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
  };
  final List<VideoBookRow> extras = <VideoBookRow>[
    for (final VideoBookRow row in targets)
      if (!members.contains(row.bookUid)) row,
  ];
  if (extras.isEmpty) return const <BlurayExtraDeletionTombstone>[];
  final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
    for (final VideoBookRow row in await db.allVideoBooks()) row.bookUid: row,
  };
  final Map<String, String?> collectionNameByRoot = <String, String?>{};
  final List<BlurayExtraDeletionTombstone> result =
      <BlurayExtraDeletionTombstone>[];
  for (final VideoBookRow row in extras) {
    final String? discRoot = discRootForMemberPath(row.videoPath);
    if (discRoot == null) continue;
    final String root = normalizeVideoPath(discRoot);
    if (!collectionNameByRoot.containsKey(root)) {
      final int? id = await _discCollectionId(
        db,
        <String>{
          for (final VideoBookRow b in byUid.values)
            if (_onDisc(b.videoPath, root)) b.bookUid,
        },
        byUid,
        root,
      );
      collectionNameByRoot[root] = id == null
          ? null
          : (await db.getMediaCollectionById(id))?.name;
    }
    final String? name = collectionNameByRoot[root];
    if (name == null) continue;
    result.add((
      bookUid: row.bookUid,
      collectionName: name,
      entryKey: blurayExtraTombstoneKey(row.videoPath),
    ));
  }
  return result;
}

/// 把 [planBlurayExtraDeletionTombstones] 算出的墓碑落库；[deletedUids] 之外的
/// （没删成的行）不记。
Future<void> writeBlurayExtraDeletionTombstones(
  FushiDatabase db,
  List<BlurayExtraDeletionTombstone> tombstones, {
  required Set<String> deletedUids,
}) async {
  final int now = DateTime.now().millisecondsSinceEpoch;
  for (final BlurayExtraDeletionTombstone t in tombstones) {
    if (!deletedUids.contains(t.bookUid)) continue;
    await db.upsertCollectionMemberTombstone(
      collectionName: t.collectionName,
      collectionType: 'playlist',
      mediaType: MediaKind.video.dbValue,
      entryKey: t.entryKey,
      deletedAt: now,
    );
  }
}

/// 各 `playlist` 合集（按合集名）下被用户删掉的特典 / 移出的成员
/// （[blurayExtraTombstoneKey] 口径）。一次查询，扫描器整轮共用。
Future<Map<String, Set<String>>> deletedBlurayExtraKeysByCollection(
  FushiDatabase db,
) async {
  final Map<String, Set<String>> result = <String, Set<String>>{};
  for (final CollectionMemberTombstoneRow row
      in await db.getAllCollectionMemberTombstones()) {
    if (row.collectionType != 'playlist' ||
        row.mediaType != MediaKind.video.dbValue) {
      continue;
    }
    result.putIfAbsent(row.collectionName, () => <String>{}).add(row.entryKey);
  }
  return result;
}
