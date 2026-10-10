import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 2026-10-08 原盘菜单首版给菜单标题起的名字（`盘目录名 · MPLS 号`）。它绕过了盘内
/// 标题，刮削拿它去搜什么都搜不到；遇到这个形状的存量行就改回 [blurayMenuTitleName]。
String _legacyMenuTitleName(String discRootPath, String playlistId) =>
    '${p.basename(p.normalize(discRootPath))} · $playlistId';

bool _onDisc(String videoPath, String normalizedRoot) {
  if (!isBlurayPlaylistPath(videoPath)) return false;
  final String? root = blurayDiscRootForPlaylistPath(videoPath);
  return root != null && normalizeVideoPath(root) == normalizedRoot;
}

/// 盘上的标题 / 特典 [playlistPath] 在库里的那一行；没有就按扫描导入的规则建：
/// 来源（`sourceId`）取 [sourceId]，没给时继承同盘已入库的标题；名字取盘内标题。
/// 扫描选中的**标题**加入这张盘的合集；**特典**（菜单里的「特典映像」等）只入库、
/// 不进盘合集——它们挂在正片作品下，进合集会把单片盘变成多成员合集。
///
/// 刮削的每一道入口都按来源挑条目，没有来源的行在结构上进不了任何刮削计划——这正
/// 是菜单首版手写建行时「明明是蓝光却刮不出来」的根因。已有的行只补缺（来源为空才
/// 补、标题不在合集才加、首版自动名才改名），幂等，不动用户改过的标题与进度。不是
/// 盘内 MPLS 路径时返回 null。
Future<VideoBookRow?> ensureBlurayTitleInLibrary(
  FushiDatabase db,
  String playlistPath, {
  int? sourceId,
}) async {
  final String? discRoot = blurayDiscRootForPlaylistPath(playlistPath);
  if (discRoot == null || !isBlurayPlaylistPath(playlistPath)) return null;
  final String playlistId = p.basenameWithoutExtension(playlistPath);
  // 读盘在事务外：META / MPLS 解析是文件 IO，不该占着写锁。
  final BlurayDisc? disc = await readBlurayDisc(discRoot);
  BlurayTitle? title;
  for (final BlurayTitle t in disc?.titles ?? const <BlurayTitle>[]) {
    if (t.playlist.id == playlistId) title = t;
  }
  final String name =
      title?.name ??
      blurayMenuTitleName(
        disc?.name ?? await readBlurayDiscName(discRoot),
        playlistId,
      );
  final VideoBookRepository repo = VideoBookRepository(db);
  final String root = normalizeVideoPath(discRoot);
  final String key = normalizeVideoPath(playlistPath);
  return db.transaction(() async {
    final List<VideoBookRow> books = await repo.listAll();
    VideoBookRow? row;
    final List<VideoBookRow> siblings = <VideoBookRow>[];
    for (final VideoBookRow book in books) {
      if (normalizeVideoPath(book.videoPath) == key) {
        row ??= book;
      } else if (_onDisc(book.videoPath, root)) {
        siblings.add(book);
      }
    }
    final int? owner =
        row?.sourceId ??
        sourceId ??
        siblings
            .map((VideoBookRow b) => b.sourceId)
            .firstWhere((int? id) => id != null, orElse: () => null);

    final String uid;
    if (row == null) {
      uid = coreUniqueVideoBookUid(
        coreSingleVideoBookUid(playlistPath),
        books.map((VideoBookRow b) => b.bookUid).toSet(),
      );
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(name),
          videoPath: Value(playlistPath),
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
        sourceId: owner,
      );
    } else {
      uid = row.bookUid;
      if (row.sourceId == null && owner != null) {
        await repo.assignSourceIfNull(row.bookUid, owner);
      }
      if (row.title == _legacyMenuTitleName(discRoot, playlistId)) {
        await repo.updateTitle(row.bookUid, name);
      }
    }
    if (title == null) return repo.getByBookUid(uid);
    final int? collectionId = await _discCollectionId(
      db,
      siblings.map((VideoBookRow b) => b.bookUid).toSet(),
      root,
    );
    if (collectionId != null) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    return repo.getByBookUid(uid);
  });
}

/// 这张盘的合集：扫描导入建的 `playlist` 合集，以同盘已入库标题的成员身份认出，
/// 且成员全是本盘标题（与扫描器 `_collectionBelongsToDisc` 同一判据——收了本盘
/// mpls 的 m3u8 清单合集不算）。盘还没被扫描导入过时没有合集，返回 null。
Future<int?> _discCollectionId(
  FushiDatabase db,
  Set<String> siblingUids,
  String normalizedRoot,
) async {
  if (siblingUids.isEmpty) return null;
  final List<MediaCollectionItemRow> all = await db.getAllCollectionItems();
  final Set<int> candidates = <int>{
    for (final MediaCollectionItemRow item in all)
      if (item.mediaType == MediaKind.video.dbValue &&
          siblingUids.contains(item.entryKey))
        item.collectionId,
  };
  for (final int id in candidates) {
    final MediaCollectionRow? collection = await db.getMediaCollectionById(id);
    if (collection?.collectionType != 'playlist') continue;
    if (await _allMembersOnDisc(db, all, id, normalizedRoot)) return id;
  }
  return null;
}

Future<bool> _allMembersOnDisc(
  FushiDatabase db,
  List<MediaCollectionItemRow> all,
  int collectionId,
  String normalizedRoot,
) async {
  for (final MediaCollectionItemRow item in all) {
    if (item.collectionId != collectionId) continue;
    final VideoBookRow? row = await db.getVideoBookByBookUid(item.entryKey);
    if (row == null) continue;
    if (!_onDisc(row.videoPath, normalizedRoot)) return false;
  }
  return true;
}
