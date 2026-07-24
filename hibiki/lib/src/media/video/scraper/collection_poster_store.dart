/// 合集级海报存储 —— 「合集封面改海报、每集保留抽帧」语义的落盘层。
///
/// 用户拍板（2026-07-24 真机反馈）：刮削海报对 DB 合集只改**合集卡封面**，
/// 各集的抽帧封面一律不动。合集封面不落 DB（不改 schema），落文件约定：
///
///   `<video_covers>/collections/collection_<id>.jpg`
///
/// - 文件名由 collectionId 1:1 派生，展示层 `existsSync` 即用；
/// - 来源元数据记进既有 `cover_meta.json`，key 用 [metaKey]（`collection:<id>`，
///   与 bookUid key 空间天然不冲突——bookUid 恒为 `video/...` 形态）；
/// - `video_covers/` 的孤儿封面 GC（[VideoStorage.gcOrphanCovers]）**非递归**且跳过
///   目录项，`collections/` 子目录天然不受其波及；本子目录自己的孤儿（合集已删）
///   由 [gcOrphans] 对照在库合集 id 集合清理。
library;

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:hibiki/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth;
import 'package:path/path.dart' as p;

/// 合集海报文件的读写器（无内存状态，随用随建）。
class CollectionPosterStore {
  /// [coversDirectory] 为封面根目录（生产 `VideoStorage.coversDir()`；测试注入临时目录）。
  CollectionPosterStore(this.coversDirectory);

  /// 封面根目录（`video_covers/`）。
  final Directory coversDirectory;

  /// 合集海报子目录名。
  static const String subdirName = 'collections';

  /// 海报文件名正则（GC 只认这个形态，其他文件不碰）。
  static final RegExp _fileNamePattern = RegExp(r'^collection_(\d+)\.jpg$');

  /// `cover_meta.json` 里合集封面来源元数据的 key（`collection:<id>`）。
  static String metaKey(int collectionId) => 'collection:$collectionId';

  /// 合集海报子目录（`video_covers/collections/`，不创建）。
  Directory get directory =>
      Directory(p.join(coversDirectory.path, subdirName));

  /// 某合集海报的目标文件（可能不存在）。
  File fileFor(int collectionId) =>
      File(p.join(directory.path, 'collection_$collectionId.jpg'));

  /// 某合集是否已有海报文件。
  Future<bool> exists(int collectionId) => fileFor(collectionId).exists();

  /// 原子落盘一张合集海报（`.tmp` + rename），返回绝对路径。覆盖同路径旧图时
  /// 驱逐 Flutter 图片缓存（[FileImage] 按 path 而非内容缓存，展示层用
  /// `resizedFileImage` 的 [ResizeImage] 包装，两种 key 都驱逐）。
  Future<String> savePoster({
    required int collectionId,
    required List<int> bytes,
  }) async {
    await directory.create(recursive: true);
    final File dest = fileFor(collectionId);
    final File tmp = File('${dest.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
    await tmp.writeAsBytes(bytes, flush: true);
    if (await dest.exists()) await dest.delete();
    await tmp.rename(dest.path);
    await _evictImageCache(dest);
    return dest.path;
  }

  /// 删除某合集的海报文件（含残留 `.tmp`；不存在为 no-op，失败不抛）。
  Future<void> remove(int collectionId) async {
    for (final File f in <File>[
      fileFor(collectionId),
      File('${fileFor(collectionId).path}.tmp'),
    ]) {
      try {
        if (await f.exists()) {
          await _evictImageCache(f);
          await f.delete();
        }
      } catch (_) {
        // 被占用/权限失败留给下次 GC 再清，不中断调用链。
      }
    }
  }

  /// 清理孤儿海报：删除 `collections/` 里 id 不在 [liveCollectionIds] 的
  /// `collection_<id>.jpg`，返回被删的合集 id（调用方据此清 `cover_meta.json`
  /// 的 [metaKey] 记录）。只认海报命名形态的常规文件，其余（含 `.tmp`）不碰；
  /// 目录不存在返回空。
  ///
  /// 合集删除入口分散（解散/合并/详情删除/清空自删/同步镜像），不逐点挂钩子；
  /// 库页每次加载合集字典后跑一遍本 GC 即可覆盖全部路径并自愈历史遗留。
  Future<List<int>> gcOrphans({required Set<int> liveCollectionIds}) async {
    if (!await directory.exists()) return const <int>[];
    final List<int> removed = <int>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final Match? m = _fileNamePattern.firstMatch(p.basename(entity.path));
      if (m == null) continue;
      final int id = int.parse(m.group(1)!);
      if (liveCollectionIds.contains(id)) continue;
      try {
        await entity.delete();
        removed.add(id);
      } catch (_) {
        // 单文件删除失败不中断整轮 GC。
      }
    }
    return removed;
  }

  /// 驱逐 Flutter 图片缓存里的同路径旧解码（纯 IO 测试可能无 painting binding，
  /// 驱逐只是提示，失败不阻塞文件操作）。
  static Future<void> _evictImageCache(File file) async {
    try {
      final FileImage raw = FileImage(file);
      await raw.evict();
      await ResizeImage(
        raw,
        width: kLocalCoverDecodePixelWidth,
        allowUpscaling: false,
      ).evict();
    } catch (_) {
      // no-op：缓存驱逐失败不影响落盘正确性。
    }
  }
}
