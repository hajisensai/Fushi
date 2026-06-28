import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:path/path.dart' as p;

/// 视频媒体在磁盘上的「app 拥有」副本目录管理 + 删除回收（BUG-276 / TODO-365）。
///
/// 布局（均在 `<appDocDir>/` 下）：
///   - `video_covers/<sanitized uid>.jpg` —— 导入时抽帧/自带封面，或用户手动设置
///     的封面。文件名由 bookUid 派生（见 [video_import_dialog] `videoCoverFileName`），
///     与 DB `coverPath` **1:1 对应**。app 拥有，删除视频后回收。
///   - `video_subtitles/<basename>` —— 用户手动导入 / 拖入 / Jimaku 下载的外挂字幕
///     （见 [video_hibiki_page] `_importExternalSubtitleInner` / `_openJimakuDialog`）。
///     **扁平副本池**：单视频/播放列表换集每选一集字幕就拷一份进来，但 DB 只在
///     `VideoBooks.subtitleSource` **单列**记最后选中那一集的路径——播放列表其余各集
///     的副本路径 **DB 完全不知道**（playlistJson 只存 `[{title,path}]`，不含字幕）。
///
/// **绝不**触碰 `VideoBooks.videoPath` / 播放列表里的视频本体路径：那是用户的原始
/// 文件（导入时只存绝对路径、从不复制），删除视频不应删用户的电影源文件。
///
/// ## 回收策略：删除时按被删 book **精确**删它自己的资产，**不**全库 sweep
///
/// 上一轮（commit 4b2b37937）用的是「任意删除后无条件对整个 `video_subtitles/`
/// 全库 mark-and-sweep」：以全库 `subtitleSource` 引用集为保留集，删掉引用集外的所有
/// 文件。这在多集播放列表下会**永久丢失用户活数据**——一个 N 集播放列表的引用集里
/// 只有 1 个字幕路径（最后选中那集），其余各集的导入副本不在引用集，删任意一个无关
/// 视频都会把它们当孤儿清掉（复核 thread aad8f701 实证）。违反 Never break userspace。
///
/// 因此改为：删 book A 时，**只删 A 自己在 DB 里能确定的资产**（A 的 `coverPath` /
/// `subtitleSource`），并在删每个文件前用「全库其余 book 的引用集」做护栏——若该文件
/// 仍被别的 book 引用（同名复用/共享 sidecar），则保留不删。A 那些 DB 不知道的播放
/// 列表别集副本：正因为不知道、就**绝不去碰**（保守留存，宁可漏清也不误删活文件）。
///
/// correctness（零跨视频数据丢失）> 历史清理完整性。字幕目录的历史孤儿（已删视频的
/// 遗留副本）在当前模型下与「活着的播放列表别集副本」不可区分（两者都不在引用集），
/// 无法在不丢数据的前提下用全库 sweep 清，故显式延后（见 BUG-276 文件），不在这里做。
/// 封面目录因文件名与 bookUid 1:1 绑定、引用集对封面完整，单独提供安全的历史 GC
/// [gcOrphanCovers]。
class VideoStorage {
  const VideoStorage._();

  static const String coversDirName = 'video_covers';
  static const String subtitlesDirName = 'video_subtitles';

  /// 封面目录绝对路径（不创建）。TODO-935 E0：经唯一入口 [AppPaths] 派生。
  static Future<Directory> coversDir() => AppPaths.videoCoversDirectory();

  /// 导入字幕目录绝对路径（不创建）。TODO-935 E0：经唯一入口 [AppPaths] 派生。
  static Future<Directory> subtitlesDir() => AppPaths.videoSubtitlesDirectory();

  /// 删除一本视频后回收**它自己**的 app 拥有副本：把 [deletedCoverPath] /
  /// [deletedSubtitlePath]（被删 book 删前的 `coverPath` / `subtitleSource`）里、
  /// **不再被任何其他 book 引用**且**确实落在对应 app 拥有目录内**的文件删掉。
  ///
  /// - [stillReferencedCoverPaths] / [stillReferencedSubtitlePaths]：删除后**全库
  ///   其余 book** 仍引用的封面/字幕路径集（护栏：命中则保留，避免删掉同名复用/共享
  ///   sidecar 的活文件）。
  /// - [coversDirectory] / [subtitlesDirectory]：缺省取生产路径；测试注入临时目录。
  ///   只删落在这两个目录里的文件——目录外的用户原始视频/外部 sidecar 绝不删。
  ///
  /// **不**枚举目录、**不**全库 sweep：只针对被删 book 自己那两个明确路径。这样删除
  /// 任意视频都不可能波及其他播放列表的字幕副本（即便它们在同一扁平池里）。
  ///
  /// 返回实际删除的文件数（便于诊断 / 测试断言）。
  static Future<int> deleteBookAssets({
    required String? deletedCoverPath,
    required String? deletedSubtitlePath,
    required Iterable<String> stillReferencedCoverPaths,
    required Iterable<String> stillReferencedSubtitlePaths,
    Directory? coversDirectory,
    Directory? subtitlesDirectory,
  }) async {
    final Directory covers = coversDirectory ?? await coversDir();
    final Directory subtitles = subtitlesDirectory ?? await subtitlesDir();
    int removed = 0;
    if (await _deleteOwnedAsset(
      candidate: deletedCoverPath,
      ownedDir: covers,
      stillReferenced: stillReferencedCoverPaths,
    )) {
      removed++;
    }
    if (await _deleteOwnedAsset(
      candidate: deletedSubtitlePath,
      ownedDir: subtitles,
      stillReferenced: stillReferencedSubtitlePaths,
    )) {
      removed++;
    }
    return removed;
  }

  /// Deletes the temp cache directory used for extracted embedded subtitles of
  /// [videoPath]. This only touches Hibiki's derived temp cache, never the
  /// original video file.
  static Future<bool> deleteEmbeddedSubtitleCacheForVideoPath(
    String? videoPath,
  ) async {
    if (videoPath == null || videoPath.isEmpty) return false;
    final Directory cacheDir = embeddedSubtitleCacheDir(videoPath);
    if (!await cacheDir.exists()) return false;
    try {
      await cacheDir.delete(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 安全删除单个被删 book 的资产 [candidate]：仅当它非空、落在 [ownedDir] 内、
  /// 且不在 [stillReferenced]（规范化后）集合里时才删。返回是否真的删了。
  ///
  /// 「落在 [ownedDir] 内」用规范化前缀判断，杜绝因 `..` / 符号链接误删目录外文件
  /// （用户原始视频、外部 sidecar 都在别处）。
  static Future<bool> _deleteOwnedAsset({
    required String? candidate,
    required Directory ownedDir,
    required Iterable<String> stillReferenced,
  }) async {
    if (candidate == null || candidate.isEmpty) return false;
    final String canon = p.canonicalize(candidate);
    if (!_isInside(canon, p.canonicalize(ownedDir.path))) return false;
    final Set<String> keep = <String>{
      for (final String path in stillReferenced)
        if (path.isNotEmpty) p.canonicalize(path),
    };
    if (keep.contains(canon)) return false;
    final File file = File(candidate);
    if (!await file.exists()) return false;
    for (int attempt = 0; attempt < 6; attempt++) {
      try {
        await _evictImageCacheForFile(file);
        await file.delete();
        return true;
      } catch (_) {
        if (attempt == 5) {
          // 删除失败（被占用/权限）不应抛断删除流程：跳过，下次再清。
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    return false;
  }

  static Future<void> _evictImageCacheForFile(File file) async {
    try {
      final ImageCache imageCache = PaintingBinding.instance.imageCache;
      imageCache.clearLiveImages();
      imageCache.clear();
      await FileImage(file).evict();
    } catch (_) {
      // Pure storage tests may run without a Flutter painting binding. Cache
      // eviction is only a lock-release hint, so missing binding must not block
      // the actual file delete.
    }
  }

  /// [childCanon] 是否严格位于规范化目录 [dirCanon] 内（含 dir 本身的直接子文件）。
  static bool _isInside(String childCanon, String dirCanon) {
    if (childCanon == dirCanon) return false;
    return p.isWithin(dirCanon, childCanon);
  }

  /// **安全的封面历史 GC**：删 `video_covers/` 里所有不在 [referencedCoverPaths]
  /// （规范化后）集合中的常规文件，返回删除数。
  ///
  /// 仅对封面安全：封面文件名由 bookUid 1:1 派生、且每本视频的封面路径都完整存在
  /// DB `coverPath` 列里，所以「全库 coverPath 引用集」对封面是**完整**的——不在其中
  /// 的封面文件必然是已删视频的遗留孤儿，删之不会丢任何活封面。**绝不**对字幕目录做
  /// 同样的全库 sweep（字幕引用集不完整，见类注释）。
  ///
  /// 只删常规文件，不递归子目录、不删目录本身。目录不存在则跳过。
  static Future<int> gcOrphanCovers({
    required Iterable<String> referencedCoverPaths,
    Directory? coversDirectory,
  }) async {
    final Directory covers = coversDirectory ?? await coversDir();
    if (!await covers.exists()) return 0;
    final Set<String> keepCanon = <String>{
      for (final String path in referencedCoverPaths)
        if (path.isNotEmpty) p.canonicalize(path),
    };
    int removed = 0;
    await for (final FileSystemEntity entity in covers.list()) {
      if (entity is! File) continue;
      if (keepCanon.contains(p.canonicalize(entity.path))) continue;
      try {
        await entity.delete();
        removed++;
      } catch (_) {
        // 单文件删除失败不中断整轮 GC。
      }
    }
    return removed;
  }
}
