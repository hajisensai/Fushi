/// 音乐来源库扫描入库（设计 §4.1）：目录遍历 / 标签 / CUE 拆轨全在 Rust
/// （`package:fushi_music`，后台 isolate），这里只把批次换算成 Drift 行落库、软删
/// 消失的文件。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

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
MusicScanBatchWrite musicScanBatchWriteOf(
  Iterable<MusicScannedTrack> tracks, {
  required int? sourceId,
  required int now,
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
        hasEmbeddedCover: Value<bool>(t.hasEmbeddedCover),
        addedAt: now,
      ),
    );
    final String? albumUid = t.albumUid;
    final String? albumTitle = t.albumTitle;
    if (albumUid != null && albumTitle != null) {
      final MusicAlbumsCompanion? prev = albums[albumUid];
      // 同一批里同一张专辑多首：封面取第一个有的（目录图优先于内嵌图）；没有封面的
      // 曲目不写封面列（absent），不会把别的批次已写的封面冲成 NULL。
      final String? cover = t.folderCoverPath;
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
            : (t.hasEmbeddedCover
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

class MusicLibraryScanner {
  MusicLibraryScanner(this._db, {MusicRootScanner? scanner})
    : _scanner = scanner ?? _nativeScanner;

  final FushiDatabase _db;
  final MusicRootScanner _scanner;

  /// 扫一个音乐来源（本地目录）。原生库缺失（[FushiMusicUnavailableError]）与根不可读
  /// （[MusicScanRootError]）照常抛给调用方：前者是部署缺陷，后者由来源行记录错误。
  Future<MusicScanSummary> scanSource({
    required int sourceId,
    required String rootPath,
    bool recursive = true,
  }) async {
    final List<({String path, int mtimeAt, int size, String trackUid})> known =
        await _db.musicTrackFilesOfSource(sourceId);
    final Map<String, ({int mtimeMs, int size})> knownFiles =
        <String, ({int mtimeMs, int size})>{
          for (final ({String path, int mtimeAt, int size, String trackUid}) k
              in known)
            k.path: (mtimeMs: k.mtimeAt, size: k.size),
        };
    final Map<String, List<String>> uidsByPath = <String, List<String>>{};
    for (final ({String path, int mtimeAt, int size, String trackUid}) k
        in known) {
      uidsByPath.putIfAbsent(k.path, () => <String>[]).add(k.trackUid);
    }

    final Set<String> seen = <String>{};
    final List<MusicScanError> errors = <MusicScanError>[];
    int parsed = 0;
    int unchanged = 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await for (final MusicScanBatch batch in _scanner(
      rootPath,
      recursive: recursive,
      known: knownFiles,
    )) {
      final List<MusicScannedTrack> tracks = <MusicScannedTrack>[];
      for (final MusicScanRecord r in batch.records) {
        switch (r) {
          case MusicScannedTrack():
            tracks.add(r);
            seen.add(r.trackUid);
          case MusicScanUnchanged(:final String path):
            unchanged++;
            seen.addAll(uidsByPath[path] ?? const <String>[]);
          case MusicScanError():
            errors.add(r);
        }
      }
      if (tracks.isNotEmpty) {
        parsed += tracks.length;
        await _db.writeMusicScanBatch(
          musicScanBatchWriteOf(tracks, sourceId: sourceId, now: now),
        );
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
}
