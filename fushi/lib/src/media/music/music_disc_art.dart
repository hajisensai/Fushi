/// 专辑的**真盘面图**（用户 2026-11-11：光盘要有真的光盘封面，没有就别假造）。
///
/// 只认真实存在的盘面扫描，按顺序：
/// 1. 专辑目录（及其下两层，如 `Scans/`、`BK/`）里**文件名明确是盘面**的图：
///    `disc` / `disk` / `cd` / `dvd` / `bd` / `medium` / `label`，可带编号（`Disc.webp`、
///    `CD1.jpg`、`disc_02.png`）；
/// 2. 同一范围里编号命名的扫描（`01.jpg`、`scan_03.jpg`）：逐张交给原生识别器
///    （`ffc_image_disc_scan`：近正方、四角纯色底、中心孔透底、夹持环色差、外缘跳变），
///    取第一张判为盘面的。结果按专辑缓存在 `local_scans.json`，图片清单（路径 / 大小 /
///    修改时间）不变就不再解码；
/// 3. 专辑对上了 MusicBrainz 发行（`mbReleaseId`）时，Cover Art Archive 里类型为
///    `Medium` 的图，下到 `<documents>/music_covers/disc/<发行 MBID>.jpg`；查过没有就记
///    一个 `<发行 MBID>.none`，[kMusicDiscArtNegativeTtl] 内不再问。
///
/// 两样都没有返回 null，调用方保持方形专辑封面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/media/music/metadata/music_auxiliary_providers.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart'
    show normalizeMusicBrainzId;
import 'package:fushi_compute/fushi_compute.dart';
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

/// 识别器能解的扫描图扩展名（含扫图包常见的 TIFF / BMP）。
const Set<String> _scanExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.tif',
  '.tiff',
};

/// 超过这个大小的扫描不读进内存（几百 MB 的无损 TIFF 不会是单张盘面）。
const int kMusicDiscScanMaxBytes = 64 << 20;

/// [name]（文件名，带扩展名）是不是明确的盘面图。
bool isMusicDiscArtFileName(String name) {
  final String ext = p.extension(name).toLowerCase();
  if (!_imageExtensions.contains(ext)) return false;
  return _discArtStem.hasMatch(p.basenameWithoutExtension(name).trim());
}

/// 专辑目录下的图：[named] 是文件名明确为盘面的，[scans] 是其余可交给识别器的扫描图；
/// 都按路径排序（`Disc1` 先于 `Disc2`）。
typedef MusicAlbumImages = ({List<String> named, List<String> scans});

/// 列 [albumDir] 及其下 [maxDepth] 层的图。目录不存在 / 读不了返回空。
Future<MusicAlbumImages> listMusicAlbumImages(
  String albumDir, {
  int maxDepth = 2,
}) async {
  final List<String> named = <String>[];
  final List<String> scans = <String>[];
  Future<void> walk(Directory dir, int depth) async {
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    for (final FileSystemEntity e in entries) {
      if (e is File) {
        final String name = p.basename(e.path);
        if (isMusicDiscArtFileName(name)) {
          named.add(e.path);
        } else if (_scanExtensions.contains(p.extension(name).toLowerCase())) {
          scans.add(e.path);
        }
      } else if (e is Directory && depth < maxDepth) {
        await walk(e, depth + 1);
      }
    }
  }

  final Directory root = Directory(albumDir);
  if (await root.exists()) await walk(root, 0);
  named.sort();
  scans.sort();
  return (named: named, scans: scans);
}

/// 在 [albumDir] 及其下两层找明确命名的盘面图（排序后第一张），没有返回 null。
Future<String?> findLocalMusicDiscArt(String albumDir) async =>
    (await listMusicAlbumImages(albumDir)).named.firstOrNull;

/// 在一组扫描图里找第一张盘面（可换成桩）。
typedef MusicDiscScanDetector = Future<String?> Function(List<String> paths);

/// 缺省识别器：后台 isolate 里逐张读字节交给 `ffc_image_disc_scan`。
Future<String?> detectMusicDiscScanInBackground(List<String> paths) =>
    Isolate.run(() => firstMusicDiscScan(paths));

/// 同步版（在调用方 isolate 里跑）：第一张判为盘面的路径；读不了 / 解不开 / 太大的跳过。
String? firstMusicDiscScan(List<String> paths) {
  for (final String path in paths) {
    final Uint8List bytes;
    try {
      final File f = File(path);
      if (f.lengthSync() > kMusicDiscScanMaxBytes) continue;
      bytes = f.readAsBytesSync();
    } on FileSystemException {
      continue;
    }
    if (FushiComputeImage.instance.discScan(bytes)?.isDisc ?? false) {
      return path;
    }
  }
  return null;
}

/// 一组扫描图的指纹（路径 / 大小 / 修改时间）：变了才重新识别。
Future<String> _scanSignature(List<String> paths) async {
  final StringBuffer b = StringBuffer();
  for (final String path in paths) {
    try {
      final FileStat st = await File(path).stat();
      b
        ..write(path)
        ..write('|')
        ..write(st.size)
        ..write('|')
        ..writeln(st.modified.millisecondsSinceEpoch);
    } on FileSystemException {
      continue;
    }
  }
  return b.toString();
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
    MusicDiscScanDetector? detectScan,
    DateTime Function()? clock,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _fetchCovers = fetchCovers,
       _download = download,
       _detectScan = detectScan ?? detectMusicDiscScanInBackground,
       _clock = clock ?? DateTime.now;

  /// 应用内共享的一份。
  static final MusicDiscArtService instance = MusicDiscArtService();

  static Future<Directory> _defaultCacheDirectory() async =>
      Directory(p.join((await AppPaths.musicCoversDirectory()).path, 'disc'));

  final Future<Directory> Function() _cacheDirectory;
  final MusicDiscArtCoverFetcher? _fetchCovers;
  final MusicDiscArtDownloader? _download;
  final MusicDiscScanDetector _detectScan;

  /// 扫描识别串行跑（一次只解一张大图；`local_scans.json` 的读改写也不会交错）。
  Future<void> _scanQueue = Future<void>.value();
  final DateTime Function() _clock;
  final Map<String, Future<String?>> _memo = <String, Future<String?>>{};

  /// 专辑的盘面图本地路径，没有返回 null。[albumDir] 是专辑音频所在目录（远程来源
  /// 传 null）。
  Future<String?> resolve({
    required String albumUid,
    String? albumDir,
    String? mbReleaseId,
    Future<String?> Function()? matchedRelease,
  }) => _memo.putIfAbsent(
    albumUid,
    () => _resolve(
      albumUid: albumUid,
      albumDir: albumDir,
      mbReleaseId: mbReleaseId,
      matchedRelease: matchedRelease,
    ),
  );

  /// 丢掉 [albumUid] 的查找结果（例如刚对上了 MusicBrainz 发行），下次 [resolve] 重查。
  void invalidate(String albumUid) => _memo.remove(albumUid);

  Future<String?> _resolve({
    required String albumUid,
    String? albumDir,
    String? mbReleaseId,
    Future<String?> Function()? matchedRelease,
  }) async {
    if (albumDir != null) {
      final MusicAlbumImages images = await listMusicAlbumImages(albumDir);
      if (images.named.isNotEmpty) return images.named.first;
      if (images.scans.isNotEmpty) {
        final String? scan = await _serialScan(albumUid, images.scans);
        if (scan != null) return scan;
      }
    }
    // 标签里的发行 id 优先，其次后台自动对上的（`MusicAlbumReleaseMatcher`）。
    final String? raw = mbReleaseId ?? await matchedRelease?.call();
    final String? id = raw == null ? null : normalizeMusicBrainzId(raw);
    if (id == null) return null;
    return _fromCoverArtArchive(id);
  }

  Future<String?> _serialScan(String albumUid, List<String> scans) {
    final Completer<String?> done = Completer<String?>();
    _scanQueue = _scanQueue.then((_) async {
      try {
        done.complete(await _scanWithCache(albumUid, scans));
      } on Object catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// 编号扫描里的盘面：图片清单没变就用缓存结论，变了才重新识别。
  Future<String?> _scanWithCache(String albumUid, List<String> scans) async {
    final Directory dir = await _cacheDirectory();
    final File cacheFile = File(p.join(dir.path, 'local_scans.json'));
    Map<String, Object?> cache = <String, Object?>{};
    try {
      if (await cacheFile.exists()) {
        final Object? decoded = jsonDecode(await cacheFile.readAsString());
        if (decoded is Map<String, Object?>) cache = decoded;
      }
    } on FormatException {
      cache = <String, Object?>{};
    }
    final String signature = await _scanSignature(scans);
    final Object? entry = cache[albumUid];
    if (entry is Map<String, Object?> && entry['sig'] == signature) {
      final Object? path = entry['path'];
      return path is String && File(path).existsSync() ? path : null;
    }
    final String? found;
    try {
      found = await _detectScan(scans);
    } on Object {
      // 原生库不可用 / isolate 失败：不写缓存，下次再试。
      return null;
    }
    cache[albumUid] = <String, Object?>{'sig': signature, 'path': found};
    await dir.create(recursive: true);
    final File tmp = File('${cacheFile.path}.part');
    await tmp.writeAsString(jsonEncode(cache), flush: true);
    await tmp.rename(cacheFile.path);
    return found;
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
