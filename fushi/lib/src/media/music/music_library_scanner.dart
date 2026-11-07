/// 音乐来源库扫描入库（设计 §4.1）：目录遍历 / 标签 / CUE 拆轨全在 Rust
/// （`package:fushi_music`，后台 isolate），这里只把批次换算成 Drift 行落库、软删
/// 消失的文件。
///
/// 远程来源（SFTP / WebDAV / AList，反馈 QAondMh4M5）同一条落库 / 对账路径：列目录与
/// 取字节留在来源访问层（[SourceFileSystem] + [SourceByteReader]），分类 / CUE / 标签 /
/// uid 仍在 Rust（远程游标按区间要字节）。远程文件没有本地路径可供之后再读封面：内嵌
/// 封面与目录封面在扫描时就落进封面缓存，库里写的是缓存里的本地文件。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/disc/music_disc_import.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 音乐来源扫描完一次后的装配点（AppModel 接到后台响度扫描，设计 §7.3）。
void Function()? onMusicSourceScanned;

/// 一次音乐来源扫描的结果。
class MusicScanSummary {
  const MusicScanSummary({
    required this.trackCount,
    required this.parsedTrackCount,
    required this.unchangedFileCount,
    required this.removedTrackCount,
    required this.errors,
  });

  /// 扫描后本来源的在库曲目数。
  final int trackCount;

  /// 本次重新解析了标签的曲目数（新增或文件变了）。
  final int parsedTrackCount;

  /// 没变、跳过解析的文件数。
  final int unchangedFileCount;

  /// 本次软删的曲目数（文件消失）。
  final int removedTrackCount;

  /// 读不了的文件 / 目录（路径 → 原因）。
  final List<MusicScanError> errors;

  /// 给来源行 `lastScanError` 的摘要；全部成功为 null。
  String? get errorSummary => errors.isEmpty
      ? null
      : '${errors.length} file(s) could not be read. First: '
            '${errors.first.path} — ${errors.first.message}';
}

/// 扫描批次 → Drift 行的纯换算（可单测，不碰数据库与原生库）。
///
/// [coverPathOf]：给出专辑封面要写的路径（缺省 = 曲目的目录封面）。远程曲目由调用方
/// 换成封面缓存里的本地文件，并令 [embeddedCoverReadable] 为 false——远程文件之后读不了
/// 内嵌封面（封面已由 [coverPathOf] 落了缓存），不写 `hasEmbeddedCover` / `coverTrackUid`。
MusicScanBatchWrite musicScanBatchWriteOf(
  Iterable<MusicScannedTrack> tracks, {
  required int? sourceId,
  required int now,
  String? Function(MusicScannedTrack track)? coverPathOf,
  bool embeddedCoverReadable = true,
}) {
  final List<MusicTracksCompanion> trackRows = <MusicTracksCompanion>[];
  final Map<String, MusicAlbumsCompanion> albums =
      <String, MusicAlbumsCompanion>{};
  final Map<String, MusicArtistsCompanion> artists =
      <String, MusicArtistsCompanion>{};
  final List<MusicTrackCreditsCompanion> credits =
      <MusicTrackCreditsCompanion>[];
  for (final MusicScannedTrack t in tracks) {
    trackRows.add(
      MusicTracksCompanion.insert(
        trackUid: t.trackUid,
        sourceId: Value<int?>(sourceId),
        path: t.path,
        cueStartMs: Value<int?>(t.cueStartMs),
        cueEndMs: Value<int?>(t.cueEndMs),
        durationMs: Value<int?>(t.durationMs),
        codec: Value<String?>(t.codec),
        sampleRate: Value<int?>(t.sampleRate),
        bitDepth: Value<int?>(t.bitDepth),
        channels: Value<int?>(t.channels),
        bitrate: Value<int?>(t.bitrateKbps),
        isLossless: Value<bool>(t.isLossless),
        title: t.title,
        titleSort: Value<String?>(t.titleSort),
        artistCredit: Value<String?>(t.artistCredit),
        albumUid: Value<String?>(t.albumUid),
        discNo: Value<int?>(t.discNo),
        trackNo: Value<int?>(t.trackNo),
        year: Value<int?>(t.year),
        genre: Value<String?>(t.genre),
        rgTrackGain: Value<double?>(t.rgTrackGain),
        rgTrackPeak: Value<double?>(t.rgTrackPeak),
        rgAlbumGain: Value<double?>(t.rgAlbumGain),
        rgAlbumPeak: Value<double?>(t.rgAlbumPeak),
        // 文件变了 / 新文件：之前的 R128 现扫结果作废（增益列已被新标签覆盖），重扫。
        r128ScannedAt: const Value<int?>(null),
        mbRecordingId: Value<String?>(t.mbRecordingId),
        mbWorkId: Value<String?>(t.mbWorkId),
        fileMtimeAt: t.fileMtimeMs,
        fileSize: t.fileSize,
        hasEmbeddedCover: Value<bool>(
          t.hasEmbeddedCover && embeddedCoverReadable,
        ),
        addedAt: now,
      ),
    );
    final String? albumUid = t.albumUid;
    final String? albumTitle = t.albumTitle;
    if (albumUid != null && albumTitle != null) {
      final MusicAlbumsCompanion? prev = albums[albumUid];
      // 同一批里同一张专辑多首：封面取第一个有的（目录图优先于内嵌图）；没有封面的
      // 曲目不写封面列（absent），不会把别的批次已写的封面冲成 NULL。
      final String? cover = coverPathOf == null
          ? t.folderCoverPath
          : coverPathOf(t);
      final bool hasCover =
          prev != null &&
          prev.coverPath.present &&
          prev.coverPath.value != null;
      albums[albumUid] = MusicAlbumsCompanion.insert(
        albumUid: albumUid,
        title: albumTitle,
        titleSort: Value<String?>(t.albumTitleSort),
        albumArtistCredit: Value<String?>(t.albumArtist),
        releaseDate: Value<String?>(t.releaseDate),
        catalogNo: Value<String?>(t.catalogNo),
        totalDiscs: Value<int?>(t.discTotal),
        mbReleaseId: Value<String?>(t.mbReleaseId),
        mbReleaseGroupId: Value<String?>(t.mbReleaseGroupId),
        coverPath: hasCover
            ? prev.coverPath
            : (cover != null
                  ? Value<String?>(cover)
                  : const Value<String?>.absent()),
        coverTrackUid: prev != null && prev.coverTrackUid.present
            ? prev.coverTrackUid
            : (t.hasEmbeddedCover && embeddedCoverReadable
                  ? Value<String?>(t.trackUid)
                  : const Value<String?>.absent()),
        addedAt: now,
        updatedAt: now,
      );
    }
    int ord = 0;
    for (final MusicScanCredit c in t.credits) {
      artists.putIfAbsent(
        c.artistUid,
        () => MusicArtistsCompanion.insert(
          artistUid: c.artistUid,
          name: c.name,
          addedAt: now,
        ),
      );
      credits.add(
        MusicTrackCreditsCompanion.insert(
          trackUid: t.trackUid,
          artistUid: c.artistUid,
          role: c.role,
          creditName: c.name,
          ord: Value<int>(ord++),
        ),
      );
    }
  }
  return MusicScanBatchWrite(
    tracks: trackRows,
    albums: albums.values.toList(),
    artists: artists.values.toList(),
    credits: credits,
  );
}

/// 扫描结果流的来源（真 app = Rust 后台 isolate；测试注入替身）。
typedef MusicRootScanner =
    Stream<MusicScanBatch> Function(
      String root, {
      bool recursive,
      Map<String, ({int mtimeMs, int size})> known,
    });

Stream<MusicScanBatch> _nativeScanner(
  String root, {
  bool recursive = true,
  Map<String, ({int mtimeMs, int size})> known =
      const <String, ({int mtimeMs, int size})>{},
}) => scanMusicRoot(root, recursive: recursive, known: known);

/// 远程扫描结果流的来源（真 app = Rust 远程游标 [scanMusicListing]；测试注入替身）。
typedef MusicListingScanner =
    Stream<MusicScanBatch> Function({
      required String root,
      required List<MusicListedFile> files,
      required Map<String, Uint8List> cueBytes,
      required MusicRangeFetcher fetch,
      Map<String, ({int mtimeMs, int size})> known,
    });

Stream<MusicScanBatch> _nativeListingScanner({
  required String root,
  required List<MusicListedFile> files,
  required Map<String, Uint8List> cueBytes,
  required MusicRangeFetcher fetch,
  Map<String, ({int mtimeMs, int size})> known =
      const <String, ({int mtimeMs, int size})>{},
}) => scanMusicListing(
  root: root,
  files: files,
  cueBytes: cueBytes,
  fetch: fetch,
  known: known,
);

/// 远程曲目的封面缓存文件名（按远程路径派生，同一张图重扫覆盖同一个文件）。
String musicRemoteCoverFileName(String remotePath, Uint8List bytes) {
  final String digest = sha1.convert(remotePath.codeUnits).toString();
  return 'remote-$digest${_imageExtensionOf(bytes)}';
}

String _imageExtensionOf(Uint8List b) {
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E) {
    return '.png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return '.jpg';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return '.webp';
  }
  return '.img';
}

/// 来源扫描顺带登记目录树里的光盘（演唱会 / MV 合集 DVD·BD，音乐方案 §9.2）：返回登记
/// 失败的盘（路径 → 原因）。
///
/// [recursive] 与来源行一致：不递归的来源只认根本身是不是盘，不下钻子目录（音乐库收视频
/// 来源里的纯音频时登记的单层来源，子目录里常是番剧 BD 原盘，不能被当成音乐专辑）。
typedef MusicDiscRegistrar =
    Future<Map<String, String>> Function(String root, {bool recursive});

class MusicLibraryScanner {
  MusicLibraryScanner(
    this._db, {
    MusicRootScanner? scanner,
    MusicDiscRegistrar? discRegistrar,
    MusicListingScanner? listingScanner,
    Future<Directory> Function()? coverDirectory,
  }) : _scanner = scanner ?? _nativeScanner,
       _discRegistrar =
           discRegistrar ?? MusicDiscImportService(_db).registerDiscsUnder,
       _listingScanner = listingScanner ?? _nativeListingScanner,
       _coverDirectory = coverDirectory ?? AppPaths.musicCoversDirectory;

  final FushiDatabase _db;
  final MusicRootScanner _scanner;
  final MusicDiscRegistrar _discRegistrar;
  final MusicListingScanner _listingScanner;
  final Future<Directory> Function() _coverDirectory;

  /// 扫一个**远程**音乐来源（SFTP / WebDAV / AList）：[entries] 是来源访问层列出的条目
  /// （SFTP 已换进 `sftp://` 命名空间，与视频行、播放期解析同一口径），[bytes] 按区间
  /// 取字节。`.cue` 读原始字节交给 Rust 判编码。取字节失败（断网 / 认证）整次扫描抛错，
  /// 不据此软删任何曲目；单个文件读不到只记一条错误。
  Future<MusicScanSummary> scanRemoteSource({
    required int sourceId,
    required String rootPath,
    required List<SourceFileEntry> entries,
    required SourceByteReader bytes,
  }) async {
    final List<MusicListedFile> files = <MusicListedFile>[
      for (final SourceFileEntry e in entries)
        if (!e.isDirectory)
          (path: e.path, mtimeMs: e.modifiedAt, size: e.sizeBytes),
    ];
    final Map<String, Uint8List> cueBytes = <String, Uint8List>{
      for (final MusicListedFile f in files)
        if (f.path.toLowerCase().endsWith('.cue'))
          f.path: await bytes.readBytes(f.path),
    };
    final Map<String, String> coverCache = <String, String>{};
    Directory? coverDir;
    Future<String> cacheCover(String remotePath, Uint8List data) async {
      coverDir ??= await (await _coverDirectory()).create(recursive: true);
      final File f = File(
        p.join(coverDir!.path, musicRemoteCoverFileName(remotePath, data)),
      );
      await f.writeAsBytes(data, flush: true);
      return coverCache[remotePath] = f.path;
    }

    // 远程目录封面：同一张图（一个目录一张）只下载一次。
    final Map<String, Future<String?>> folderCovers =
        <String, Future<String?>>{};
    Future<String?> folderCover(String remotePath) =>
        folderCovers.putIfAbsent(remotePath, () async {
          final Uint8List data = await bytes.readBytes(remotePath);
          if (data.isEmpty) return null;
          return cacheCover(remotePath, data);
        });

    return _ingest(
      sourceId: sourceId,
      open: (Map<String, ({int mtimeMs, int size})> known) => _listingScanner(
        root: rootPath,
        files: files,
        cueBytes: cueBytes,
        fetch: bytes.readRange,
        known: known,
      ),
      onCover: (MusicScanCover c) => cacheCover(c.path, c.bytes),
      prepareBatch: (List<MusicScannedTrack> tracks) async {
        for (final MusicScannedTrack t in tracks) {
          final String? folder = t.folderCoverPath;
          if (folder != null) await folderCover(folder);
        }
      },
      coverPathOf: (MusicScannedTrack t) {
        final String? folder = t.folderCoverPath;
        if (folder != null && coverCache[folder] != null) {
          return coverCache[folder];
        }
        return coverCache[t.path];
      },
      embeddedCoverReadable: false,
    );
  }

  /// 本地与远程共用的落库 + 对账：[open] 按已知文件开扫描流；新解析的曲目逐批写库，
  /// 没变的文件只记「还在」，扫完软删本来源下没再出现的曲目。
  Future<MusicScanSummary> _ingest({
    required int sourceId,
    required Stream<MusicScanBatch> Function(
      Map<String, ({int mtimeMs, int size})> known,
    )
    open,
    Future<void> Function(MusicScanCover cover)? onCover,
    Future<void> Function(List<MusicScannedTrack> tracks)? prepareBatch,
    String? Function(MusicScannedTrack track)? coverPathOf,
    bool embeddedCoverReadable = true,
  }) async {
    final List<({String path, int mtimeAt, int size, String trackUid})> known =
        await _db.musicTrackFilesOfSource(sourceId);
    final Map<String, ({int mtimeMs, int size})> knownFiles =
        <String, ({int mtimeMs, int size})>{
          for (final ({String path, int mtimeAt, int size, String trackUid}) k
              in known)
            k.path: (mtimeMs: k.mtimeAt, size: k.size),
        };
    // Rust 把「没变」的文件按它的统一拼法报回来，库里存的可能是旧版本的混合分隔符
    // 写法：按路径键（[musicTrackPathKey]）对，不按原文对，否则没变的曲目全被当成消失。
    final Map<String, List<String>> uidsByPath = <String, List<String>>{};
    for (final ({String path, int mtimeAt, int size, String trackUid}) k
        in known) {
      uidsByPath
          .putIfAbsent(musicTrackPathKey(k.path), () => <String>[])
          .add(k.trackUid);
    }

    final Set<String> seen = <String>{};
    final List<MusicScanError> errors = <MusicScanError>[];
    int parsed = 0;
    int unchanged = 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await for (final MusicScanBatch batch in open(knownFiles)) {
      final List<MusicScannedTrack> tracks = <MusicScannedTrack>[];
      for (final MusicScanRecord r in batch.records) {
        switch (r) {
          case MusicScannedTrack():
            tracks.add(r);
          case MusicScanUnchanged(:final String path):
            unchanged++;
            seen.addAll(
              uidsByPath[musicTrackPathKey(path)] ?? const <String>[],
            );
          case MusicScanError():
            errors.add(r);
          case MusicScanCover():
            // 远程曲目的内嵌封面：本地扫描不会产出这种记录（封面之后按路径现读）。
            await onCover?.call(r);
        }
      }
      if (tracks.isNotEmpty) {
        parsed += tracks.length;
        await prepareBatch?.call(tracks);
        // 库里已有同一个文件的沿用旧 uid（见 writeMusicScanBatch）：记实际落库的 uid。
        final Map<String, String> remapped = await _db.writeMusicScanBatch(
          musicScanBatchWriteOf(
            tracks,
            sourceId: sourceId,
            now: now,
            coverPathOf: coverPathOf,
            embeddedCoverReadable: embeddedCoverReadable,
          ),
        );
        for (final MusicScannedTrack t in tracks) {
          seen.add(remapped[t.trackUid] ?? t.trackUid);
        }
      }
    }
    final int removed = await _db.softDeleteMissingMusicTracks(
      sourceId: sourceId,
      seenTrackUids: seen,
      deletedAt: DateTime.now().millisecondsSinceEpoch,
    );
    return MusicScanSummary(
      trackCount: seen.length,
      parsedTrackCount: parsed,
      unchangedFileCount: unchanged,
      removedTrackCount: removed,
      errors: errors,
    );
  }

  /// 扫一个音乐来源（本地目录）。原生库缺失（[FushiMusicUnavailableError]）与根不可读
  /// （[MusicScanRootError]）照常抛给调用方：前者是部署缺陷，后者由来源行记录错误。
  Future<MusicScanSummary> scanSource({
    required int sourceId,
    required String rootPath,
    bool recursive = true,
  }) async {
    final MusicScanSummary summary = await _ingest(
      sourceId: sourceId,
      open: (Map<String, ({int mtimeMs, int size})> known) =>
          _scanner(rootPath, recursive: recursive, known: known),
    );
    // 盘不是音频文件，Rust 扫描不认；登记成专辑（章节由用户在专辑页导入）。
    final List<MusicScanError> discErrors = <MusicScanError>[
      for (final MapEntry<String, String> f in (await _discRegistrar(
        rootPath,
        recursive: recursive,
      )).entries)
        MusicScanError(f.key, f.value),
    ];
    if (discErrors.isEmpty) return summary;
    return MusicScanSummary(
      trackCount: summary.trackCount,
      parsedTrackCount: summary.parsedTrackCount,
      unchangedFileCount: summary.unchangedFileCount,
      removedTrackCount: summary.removedTrackCount,
      errors: <MusicScanError>[...summary.errors, ...discErrors],
    );
  }
}
