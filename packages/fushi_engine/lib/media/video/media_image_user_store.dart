import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi_engine/media/video/video_storage.dart';

/// `media_images` 的归属：合集（视频剧集合集 / 书 / 游戏合集）或单个视频（散装电影），
/// 二选一（与表上的 CHECK 同一不变量）。
@immutable
class MediaImageOwner {
  const MediaImageOwner.collection(int this.collectionId) : bookUid = null;
  const MediaImageOwner.book(String this.bookUid) : collectionId = null;

  final int? collectionId;
  final String? bookUid;

  @override
  bool operator ==(Object other) =>
      other is MediaImageOwner &&
      other.collectionId == collectionId &&
      other.bookUid == bookUid;

  @override
  int get hashCode => Object.hash(collectionId, bookUid);

  @override
  String toString() =>
      collectionId != null ? 'collection:$collectionId' : 'video:$bookUid';
}

/// 视频作品 / 合集附加图（`media_images`）的**用户口径**写入口（v184 来源锁）：
/// 「横幅…」面板选的图经这里落盘、登记并上锁，之后的刮削整组重写
/// （[FushiDatabase.replaceMediaImagesForCollection] / `...ForBook`）与全量清理
/// 一律跳过这一种图。判锁不在这里：在那两个 DB 写入口的事务里，任何刮削写回
/// （视频刮削、媒体服务器入库）都逃不掉，这里只负责用户自己的那一份。
///
/// - 文件落在归属自己的目录：合集 → `video_covers/collections/`（与合集封面同目录，
///   删合集时 `collection_asset_reclaim` 一并回收）、视频 → `video_covers/images/`
///   （删视频时 `VideoStorage.deleteBookAssets` 回收）。文件名带 `_user`
///   （[mediaImageUserFileName]），刮削的 sidecar / 缓存文件永远碰不到它；
/// - 换图 / 移除后，被换下且不再被任何行引用、又落在上述目录里的旧文件随即回收
///   （刮削的 sidecar 在目录外，一律不碰）；
/// - 同一归属同一种图的写入在进程内串行（换图与移除不交错）。
class MediaImageUserStore {
  MediaImageUserStore(
    this._db, {
    Directory? collectionsDirectory,
    Directory? videosDirectory,
    Future<File> Function(String url)? downloadImage,
  }) : _collectionsDirectory = collectionsDirectory,
       _videosDirectory = videosDirectory,
       _download = downloadImage ?? downloadImageToTempFile;

  final FushiDatabase _db;
  final Directory? _collectionsDirectory;
  final Directory? _videosDirectory;
  final Future<File> Function(String url) _download;

  Future<Directory> _dirOf(MediaImageOwner owner) async =>
      owner.collectionId != null
      ? _collectionsDirectory ?? await VideoStorage.collectionCoversDir()
      : _videosDirectory ?? await VideoStorage.imagesDir();

  /// [owner] 的 [kind] 图里 position 最小的那行（用户选的在就是它）；没有为 null。
  Future<MediaImageRow?> firstImage(
    MediaImageOwner owner,
    MediaImageKind kind,
  ) async {
    MediaImageRow? best;
    for (final MediaImageRow row in await _rowsOf(owner)) {
      if (row.kind != kind.dbValue) continue;
      if (row.userChosen) return row;
      if (best == null || row.position < best.position) best = row;
    }
    return best;
  }

  /// 用户把本地图片 [source] 设为 [owner] 的 [kind] 图（替换这一种的全部旧行），并
  /// 上锁。返回落盘路径。源不是完整可解码图片时抛 [CoverImageInvalidException]，
  /// 旧图不动。
  Future<String> setUserImageFromFile(
    MediaImageOwner owner,
    MediaImageKind kind,
    File source, {
    String? sourceUrl,
  }) => _locked(owner, kind, () async {
    final Directory dir = await _dirOf(owner);
    await dir.create(recursive: true);
    final String dest = p.join(
      dir.path,
      mediaImageUserFileName(owner, kind, source),
    );
    await copyCoverFileAtomically(source: source, destPath: dest);
    final List<String> dropped = await _db.setUserMediaImage(
      collectionId: owner.collectionId,
      bookUid: owner.bookUid,
      kind: kind,
      path: dest,
      sourceUrl: sourceUrl,
    );
    await _reclaim(dropped, dir);
    return dest;
  });

  /// 下载 [url] 后同 [setUserImageFromFile]（下载失败抛 `ImageDownloadException`）。
  Future<String> setUserImageFromUrl(
    MediaImageOwner owner,
    MediaImageKind kind,
    String url,
  ) async {
    final File tmp = await _download(url);
    try {
      return await setUserImageFromFile(owner, kind, tmp, sourceUrl: url);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件删不掉不影响结果。
      }
    }
  }

  /// 用户移除 [owner] 的 [kind] 图里自己选的那张并解锁（刮削的图归刮削管，不在这里
  /// 删；下一次刮削整组重写）。
  Future<void> clearUserImage(MediaImageOwner owner, MediaImageKind kind) =>
      _locked(owner, kind, () async {
        final List<String> dropped = await _db.clearUserMediaImage(
          collectionId: owner.collectionId,
          bookUid: owner.bookUid,
          kind: kind,
        );
        await _reclaim(dropped, await _dirOf(owner));
      });

  Future<List<MediaImageRow>> _rowsOf(MediaImageOwner owner) =>
      owner.collectionId != null
      ? _db.getMediaImagesForCollection(owner.collectionId!)
      : _db.getMediaImagesForBook(owner.bookUid!);

  /// 回收被换下的文件：只删落在 [dir] 内、不再被任何附加图行或合集封面引用的。
  Future<void> _reclaim(List<String> dropped, Directory dir) async {
    if (dropped.isEmpty) return;
    await VideoStorage.deleteOwnedImageFiles(
      deletedPaths: dropped,
      stillReferencedPaths: <String>[
        for (final MediaImageRow row in await _db.getAllMediaImages()) row.path,
        for (final MediaCollectionRow c in await _db.getAllMediaCollections())
          ?c.coverPath,
      ],
      ownedDir: dir,
    );
  }

  static final Map<String, Future<void>> _locks = <String, Future<void>>{};

  static Future<T> _locked<T>(
    MediaImageOwner owner,
    MediaImageKind kind,
    Future<T> Function() body,
  ) async {
    final String lock = '$owner:${kind.dbValue}';
    final Future<void> previous = _locks[lock] ?? Future<void>.value();
    final Completer<void> release = Completer<void>();
    final Future<void> mine = release.future;
    _locks[lock] = mine;
    try {
      await previous;
      return await body();
    } finally {
      release.complete();
      if (identical(_locks[lock], mine)) _locks.remove(lock);
    }
  }
}

/// 用户选的附加图文件名：合集 `collection_<id>_<kind>_user.<ext>`、视频
/// `video_<bookUid 摘要>_<kind>_user.<ext>`（bookUid 取 sha1 前 16 位）。扩展名跟
/// 源文件（不认得的按 jpg）。与合集封面 `<id>.<ext>`、单视频刮削图的派生名都不会
/// 相撞。
String mediaImageUserFileName(
  MediaImageOwner owner,
  MediaImageKind kind,
  File source,
) {
  String ext = p.extension(source.path).toLowerCase();
  if (!const <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(ext)) {
    ext = '.jpg';
  }
  final String stem = owner.collectionId != null
      ? 'collection_${owner.collectionId}'
      : 'video_${sha1.convert(utf8.encode(owner.bookUid!)).toString().substring(0, 16)}';
  return '${stem}_${kind.dbValue}_user$ext';
}
