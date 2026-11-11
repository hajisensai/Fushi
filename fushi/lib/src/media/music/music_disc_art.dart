/// 专辑的**真盘面图**（用户 2026-11-11：光盘要有真的光盘封面，没有就别假造）。
///
/// 只认真实存在的盘面扫描，按顺序：
/// 1. 专辑目录（及其下两层，如 `Scans/`、`BK/`）里**文件名明确是盘面**的图：
///    `disc` / `disk` / `cd` / `dvd` / `bd` / `medium` / `label`，可带编号（`Disc.webp`、
///    `CD1.jpg`、`disc_02.png`）；编号命名的扫描（`01.jpg`、`scan_03.jpg`）分不出哪张是
///    盘面，不猜。
/// 2. 专辑对上了 MusicBrainz 发行（`mbReleaseId`）时，Cover Art Archive 里类型为
///    `Medium` 的图，下到 `<documents>/music_covers/disc/<发行 MBID>.jpg`；查过没有就记
///    一个 `<发行 MBID>.none`，[kMusicDiscArtNegativeTtl] 内不再问。
///
/// 两样都没有返回 null，调用方保持方形专辑封面。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/music/metadata/music_auxiliary_providers.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart'
    show normalizeMusicBrainzId;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 「CAA 没有盘面图」的记录多久后重查（有人上传了就能拿到）。
const Duration kMusicDiscArtNegativeTtl = Duration(days: 30);

/// 盘面图的文件名主干（不含扩展名）。
final RegExp _discArtStem = RegExp(
  r'^(disc|disk|cd|dvd|bd|medium|label)[\s_\-.]*\d{0,2}$',
  caseSensitive: false,
);

const Set<String> _imageExtensions = <String>{'.jpg', '.jpeg', '.png', '.webp'};

/// [name]（文件名，带扩展名）是不是明确的盘面图。
bool isMusicDiscArtFileName(String name) {
  final String ext = p.extension(name).toLowerCase();
  if (!_imageExtensions.contains(ext)) return false;
  return _discArtStem.hasMatch(p.basenameWithoutExtension(name).trim());
}

/// 在 [albumDir] 及其下 [maxDepth] 层找明确命名的盘面图；有多张取路径排序后的第一张
/// （`Disc1` 先于 `Disc2`）。目录不存在 / 读不了返回 null。
Future<String?> findLocalMusicDiscArt(
  String albumDir, {
  int maxDepth = 2,
}) async {
  final List<String> hits = <String>[];
  Future<void> walk(Directory dir, int depth) async {
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    for (final FileSystemEntity e in entries) {
      if (e is File && isMusicDiscArtFileName(p.basename(e.path))) {
        hits.add(e.path);
      } else if (e is Directory && depth < maxDepth) {
        await walk(e, depth + 1);
      }
    }
  }

  final Directory root = Directory(albumDir);
  if (!await root.exists()) return null;
  await walk(root, 0);
  if (hits.isEmpty) return null;
  hits.sort();
  return hits.first;
}

/// CAA 的图里挑盘面：类型含 `Medium`，已审核的优先。
MusicCoverImage? pickMusicDiscArtImage(List<MusicCoverImage> images) {
  MusicCoverImage? unapproved;
  for (final MusicCoverImage i in images) {
    if (!i.types.contains('Medium')) continue;
    if (i.approved) return i;
    unapproved ??= i;
  }
  return unapproved;
}

/// 取 CAA 发行图列表（可换成桩）。
typedef MusicDiscArtCoverFetcher =
    Future<List<MusicCoverImage>> Function(String mbReleaseId);

/// 下载图片字节（可换成桩）。
typedef MusicDiscArtDownloader = Future<List<int>> Function(String url);

/// 进程内的盘面图查找：同一专辑只查一次（[resolve] 返回同一个 Future）。
class MusicDiscArtService {
  MusicDiscArtService({
    Future<Directory> Function()? cacheDirectory,
    MusicDiscArtCoverFetcher? fetchCovers,
    MusicDiscArtDownloader? download,
    DateTime Function()? clock,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _fetchCovers = fetchCovers,
       _download = download,
       _clock = clock ?? DateTime.now;

  /// 应用内共享的一份。
  static final MusicDiscArtService instance = MusicDiscArtService();

  static Future<Directory> _defaultCacheDirectory() async =>
      Directory(p.join((await AppPaths.musicCoversDirectory()).path, 'disc'));

  final Future<Directory> Function() _cacheDirectory;
  final MusicDiscArtCoverFetcher? _fetchCovers;
  final MusicDiscArtDownloader? _download;
  final DateTime Function() _clock;
  final Map<String, Future<String?>> _memo = <String, Future<String?>>{};

  /// 专辑的盘面图本地路径，没有返回 null。[albumDir] 是专辑音频所在目录（远程来源
  /// 传 null）。
  Future<String?> resolve({
    required String albumUid,
    String? albumDir,
    String? mbReleaseId,
  }) => _memo.putIfAbsent(
    albumUid,
    () => _resolve(albumDir: albumDir, mbReleaseId: mbReleaseId),
  );

  Future<String?> _resolve({String? albumDir, String? mbReleaseId}) async {
    if (albumDir != null) {
      final String? local = await findLocalMusicDiscArt(albumDir);
      if (local != null) return local;
    }
    final String? id = mbReleaseId == null
        ? null
        : normalizeMusicBrainzId(mbReleaseId);
    if (id == null) return null;
    return _fromCoverArtArchive(id);
  }

  Future<String?> _fromCoverArtArchive(String releaseId) async {
    final Directory dir = await _cacheDirectory();
    final File cached = File(p.join(dir.path, '$releaseId.jpg'));
    if (await cached.exists()) return cached.path;
    final File none = File(p.join(dir.path, '$releaseId.none'));
    if (await none.exists()) {
      final DateTime checked = await none.lastModified();
      if (_clock().difference(checked) < kMusicDiscArtNegativeTtl) return null;
    }
    CoverArtArchiveProvider? owned;
    try {
      final MusicDiscArtCoverFetcher fetch =
          _fetchCovers ??
          (owned = CoverArtArchiveProvider()).fetchReleaseCovers;
      final MusicCoverImage? medium = pickMusicDiscArtImage(
        await fetch(releaseId),
      );
      await dir.create(recursive: true);
      if (medium == null) {
        await none.writeAsString('');
        return null;
      }
      final MusicDiscArtDownloader download =
          _download ?? (owned ??= CoverArtArchiveProvider()).download;
      final List<int> bytes = await download(medium.displayUrl);
      if (bytes.isEmpty) return null;
      // 先写临时文件再改名：半截文件不会被下次当成命中。
      final File tmp = File('${cached.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(cached.path);
      if (await none.exists()) await none.delete();
      return cached.path;
    } on Exception {
      // 断网 / 限流：不记「没有」，下次启动再查。
      return null;
    } finally {
      owned?.close();
    }
  }
}
