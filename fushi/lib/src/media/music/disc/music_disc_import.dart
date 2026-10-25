/// 演唱会 / MV 合集 DVD·BD「章节导入为曲目」的 app 侧装配（音乐方案 §9.2）。
///
/// 盘在曲库里就是一张带 `DVD` / `BD` 角标的专辑（`music_albums.disc_uid` →
/// `music_disc_sources`），不设「光盘」分区。流程：
///
/// 1. **登记**（[MusicDiscImportService.registerDisc]）：工具栏「添加光盘」选的目录 / 镜像，
///    或音乐来源扫描时顺带认出的盘（[findMusicDiscRoots]），建专辑 + 光盘来源行，不建曲目；
/// 2. **导入**（专辑详情 / 右键菜单「章节导入为曲目」）：用户选 title，章节逐个成曲目
///    （与 CUE 虚拟曲目同一约定：`path` = title 身份路径，`cue_start_ms` / `cue_end_ms` =
///    章节起止，见 `music_disc.dart`），之后可加歌单、挂歌词；
/// 3. **对号**（[MusicDiscImportService.applyRelease]）：盘名搜 MusicBrainz 的 DVD / BD 发行，
///    曲数 + 时长对上的那张给曲目改名。
///
/// 盘的路径是外部路径，曲库曲目的 `source_id` 留空：音乐来源重扫的「软删消失文件」不会
/// 把光盘曲目当成消失的文件。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:path/path.dart' as p;

/// 一次导入要落库的行（纯换算的产物，可单测）。
class MusicDiscImportRows {
  const MusicDiscImportRows({
    required this.album,
    required this.disc,
    required this.tracks,
    required this.refs,
  });

  final MusicAlbumsCompanion album;
  final MusicDiscSourcesCompanion disc;
  final List<MusicTracksCompanion> tracks;
  final List<MusicDiscTrackRef> refs;
}

/// 盘上认不出能导入的章节（DVD program map 缺失 / 选中的 title 都没章节）。
class MusicDiscNoChaptersException implements Exception {
  const MusicDiscNoChaptersException(this.rootPath);

  final String rootPath;

  @override
  String toString() => 'MusicDiscNoChaptersException: $rootPath';
}

/// 盘读不出来（不是盘 / 盘已经不在原路径）。
class MusicDiscUnreadableException implements Exception {
  const MusicDiscUnreadableException(this.path);

  final String path;

  @override
  String toString() => 'MusicDiscUnreadableException: $path';
}

/// 盘边上的封面图：文件夹形态看盘根，镜像看镜像所在目录（`cover.*` / `folder.*`）；BD 再看
/// `BDMV/META/DL` 里最大的那张 jpg（盘内缩略图）。没有返回 null。
String? findMusicDiscCover(MusicDiscInfo info) {
  const List<String> stems = <String>['cover', 'folder', 'front'];
  const List<String> exts = <String>['.jpg', '.jpeg', '.png', '.webp'];
  final String dir = FileSystemEntity.isFileSync(info.rootPath)
      ? p.dirname(info.rootPath)
      : info.rootPath;
  try {
    for (final FileSystemEntity e in Directory(dir).listSync()) {
      if (e is! File) continue;
      final String name = p.basenameWithoutExtension(e.path).toLowerCase();
      final String ext = p.extension(e.path).toLowerCase();
      if (stems.contains(name) && exts.contains(ext)) return e.path;
    }
  } on FileSystemException {
    // 读不了目录就当没有封面。
  }
  if (info.kind == MusicDiscKind.bluray) {
    final Directory meta = Directory(
      p.join(info.rootPath, 'BDMV', 'META', 'DL'),
    );
    try {
      File? best;
      int bestSize = 0;
      for (final FileSystemEntity e in meta.listSync()) {
        if (e is! File) continue;
        final String ext = p.extension(e.path).toLowerCase();
        if (ext != '.jpg' && ext != '.jpeg' && ext != '.png') continue;
        final int size = e.lengthSync();
        if (size > bestSize) {
          best = e;
          bestSize = size;
        }
      }
      return best?.path;
    } on FileSystemException {
      return null;
    }
  }
  return null;
}

/// 纯换算：盘 + 选中的 title → 专辑 / 光盘来源 / 曲目行。曲目按 title 号、章节序连续编号；
/// [chapterTitle] 给章节曲目的默认名（本地化由调用方做；MusicBrainz 对号后会改掉）。
MusicDiscImportRows musicDiscImportRows(
  MusicDiscInfo info, {
  required Set<int> titleNumbers,
  required String Function(MusicDiscTitle title, MusicDiscChapter chapter)
  chapterTitle,
  required int now,
  required int fileMtimeAt,
  required int fileSize,
  String? coverPath,
}) {
  final String albumUid = musicDiscAlbumUid(info.kind, info.discId);
  final String discUid = musicDiscUid(info.kind, info.discId);
  final List<MusicTracksCompanion> tracks = <MusicTracksCompanion>[];
  final List<MusicDiscTrackRef> refs = <MusicDiscTrackRef>[];
  int trackNo = 0;
  for (final MusicDiscTitle title in info.titles) {
    if (!titleNumbers.contains(title.number)) continue;
    for (final MusicDiscChapter c in title.chapters) {
      trackNo++;
      final String uid = musicDiscChapterTrackUid(
        kind: info.kind,
        discId: info.discId,
        titleNumber: title.number,
        chapterNumber: c.number,
      );
      final bool lastOfTitle = c.end >= title.duration;
      tracks.add(
        MusicTracksCompanion.insert(
          trackUid: uid,
          sourceId: const Value<int?>(null),
          path: title.titlePath,
          cueStartMs: Value<int?>(c.start.inMilliseconds),
          // title 的最后一章播到 title 结尾（与 CUE 最后一轨同理：不在段尾截掉样本）。
          cueEndMs: Value<int?>(lastOfTitle ? null : c.end.inMilliseconds),
          durationMs: Value<int?>(c.duration.inMilliseconds),
          title: chapterTitle(title, c),
          albumUid: Value<String?>(albumUid),
          trackNo: Value<int?>(trackNo),
          fileMtimeAt: fileMtimeAt,
          fileSize: fileSize,
          addedAt: now,
        ),
      );
      refs.add(
        MusicDiscTrackRef(
          trackUid: uid,
          titleNumber: title.number,
          chapterNumber: c.number,
        ),
      );
    }
  }
  return MusicDiscImportRows(
    album: MusicAlbumsCompanion.insert(
      albumUid: albumUid,
      title: info.name,
      coverPath: Value<String?>(coverPath),
      discUid: Value<String?>(discUid),
      addedAt: now,
      updatedAt: now,
    ),
    disc: MusicDiscSourcesCompanion.insert(
      discUid: discUid,
      path: info.rootPath,
      kind: info.kind.wire,
      volumeId: Value<String?>(info.volumeLabel),
      hasMenu: const Value<bool>(true),
      titleMapJson: Value<String?>(
        refs.isEmpty ? null : encodeMusicDiscTitleMap(refs),
      ),
      addedAt: now,
    ),
    tracks: tracks,
    refs: refs,
  );
}

/// 纯换算：一次对号结论 → 专辑更新 + 逐首改名。曲目按 [tracks] 的顺序（专辑页的轨号序）
/// 与对号结论逐首对应；数量不一致返回 null（不半截套用）。
({
  MusicAlbumsCompanion album,
  List<({String trackUid, String title, String? artist, String? mbRecordingId})>
  names,
})?
musicDiscReleaseUpdate(
  MusicDiscReleaseMatch match,
  List<MusicTrackRow> tracks, {
  required int now,
}) {
  if (tracks.length != match.tracks.length) return null;
  final MusicReleaseTracklist r = match.release;
  return (
    album: MusicAlbumsCompanion(
      title: r.title.isEmpty
          ? const Value<String>.absent()
          : Value<String>(r.title),
      albumArtistCredit: Value<String?>(r.artistCredit),
      mbReleaseId: Value<String?>(r.mbReleaseId),
      mbReleaseGroupId: Value<String?>(r.releaseGroupId),
      releaseDate: Value<String?>(r.date),
      catalogNo: Value<String?>(
        r.catalogNumbers.isEmpty ? null : r.catalogNumbers.first,
      ),
      updatedAt: Value<int>(now),
    ),
    names:
        <
          ({
            String trackUid,
            String title,
            String? artist,
            String? mbRecordingId,
          })
        >[
          for (int i = 0; i < tracks.length; i++)
            (
              trackUid: tracks[i].trackUid,
              title: match.tracks[i].title.isEmpty
                  ? tracks[i].title
                  : match.tracks[i].title,
              artist: match.tracks[i].artistCredit ?? r.artistCredit,
              mbRecordingId: match.tracks[i].mbRecordingId,
            ),
        ],
  );
}

/// 目录树里的光盘：`VIDEO_TS/VIDEO_TS.IFO` 所在盘根、`BDMV/PLAYLIST` 所在盘根、`.iso` 文件。
/// 只看名字与少量 `exists`；盘内部不往下走（VIDEO_TS / BDMV 里不会再套盘）。
/// 同步实现，调用方放后台 isolate（[findMusicDiscRootsInBackground]）。
List<String> findMusicDiscRoots(String root, {bool recursive = true}) {
  final List<String> out = <String>[];
  void walk(Directory dir, int depth) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    bool hasVideoTs = false;
    bool hasBdmv = false;
    for (final FileSystemEntity e in entries) {
      final String name = p.basename(e.path);
      if (e is Directory && name == 'VIDEO_TS') {
        hasVideoTs = File(p.join(e.path, 'VIDEO_TS.IFO')).existsSync();
      } else if (e is Directory && name == 'BDMV') {
        hasBdmv = Directory(p.join(e.path, 'PLAYLIST')).existsSync();
      }
    }
    if (hasVideoTs || hasBdmv) {
      out.add(dir.path);
      return;
    }
    for (final FileSystemEntity e in entries) {
      if (e is File && p.extension(e.path).toLowerCase() == '.iso') {
        out.add(e.path);
      } else if (e is Directory && (recursive || depth == 0)) {
        if (recursive) walk(e, depth + 1);
      }
    }
  }

  walk(Directory(root), 0);
  out.sort();
  return out;
}

Future<List<String>> findMusicDiscRootsInBackground(
  String root, {
  bool recursive = true,
}) => Isolate.run(
  () => findMusicDiscRoots(root, recursive: recursive),
  debugName: 'music-disc-roots',
);

typedef MusicDiscReader = Future<MusicDiscInfo?> Function(String path);

class MusicDiscImportService {
  MusicDiscImportService(
    this._db, {
    MusicDiscReader? reader,
    int Function()? now,
  }) : _read = reader ?? readMusicDiscInfo,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase _db;
  final MusicDiscReader _read;
  final int Function() _now;

  /// 读盘；读不出抛 [MusicDiscUnreadableException]。
  Future<MusicDiscInfo> readDisc(String path) async {
    final MusicDiscInfo? info = await _read(path);
    if (info == null) throw MusicDiscUnreadableException(path);
    return info;
  }

  /// 把 [path] 这张盘登记进曲库，返回专辑 uid。不是盘 / 读不出抛
  /// [MusicDiscUnreadableException]。
  Future<String> registerDisc(String path) async {
    final MusicDiscInfo info = await readDisc(path);
    final int now = _now();
    final MusicDiscImportRows rows = musicDiscImportRows(
      info,
      titleNumbers: const <int>{},
      chapterTitle: (_, _) => '',
      now: now,
      fileMtimeAt: 0,
      fileSize: 0,
      coverPath: findMusicDiscCover(info),
    );
    await _db.registerMusicDisc(album: rows.album, disc: rows.disc);
    return rows.album.albumUid.value;
  }

  /// 导入选中 title 的章节为曲目（重新导入覆盖上一轮的选择）。返回导入的曲目数。
  Future<int> importChapters(
    MusicDiscInfo info, {
    required Set<int> titleNumbers,
    required String Function(MusicDiscTitle title, MusicDiscChapter chapter)
    chapterTitle,
  }) async {
    final FileStat stat = await FileStat.stat(info.identityFilePath);
    final MusicDiscImportRows rows = musicDiscImportRows(
      info,
      titleNumbers: titleNumbers,
      chapterTitle: chapterTitle,
      now: _now(),
      fileMtimeAt: stat.type == FileSystemEntityType.notFound
          ? 0
          : stat.modified.millisecondsSinceEpoch,
      fileSize: stat.type == FileSystemEntityType.notFound ? 0 : stat.size,
      coverPath: findMusicDiscCover(info),
    );
    if (rows.tracks.isEmpty) throw MusicDiscNoChaptersException(info.rootPath);
    await _db.writeMusicDiscImport(
      album: rows.album,
      disc: rows.disc,
      tracks: rows.tracks,
      deletedAt: _now(),
    );
    return rows.tracks.length;
  }

  /// 套用一次对号结论。曲目数对不上返回 false（不半截套用）。
  Future<bool> applyRelease({
    required String albumUid,
    required MusicDiscReleaseMatch match,
    required List<MusicTrackRow> tracks,
  }) async {
    final ({
      MusicAlbumsCompanion album,
      List<
        ({String trackUid, String title, String? artist, String? mbRecordingId})
      >
      names,
    })?
    update = musicDiscReleaseUpdate(match, tracks, now: _now());
    if (update == null) return false;
    await _db.applyMusicDiscRelease(
      albumUid: albumUid,
      album: update.album,
      names: update.names,
    );
    return true;
  }

  /// 音乐来源扫描后顺带登记目录树里的盘（已登记的只刷新路径）。返回登记失败的盘
  /// （路径 → 原因），不抛：一张坏盘不连坐整次扫描。
  Future<Map<String, String>> registerDiscsUnder(String root) async {
    final Map<String, String> failures = <String, String>{};
    for (final String disc in await findMusicDiscRootsInBackground(root)) {
      try {
        await registerDisc(disc);
      } on MusicDiscUnreadableException {
        // 名字像盘但读不出 title（空 VIDEO_TS、数据盘镜像）：不是音乐盘，跳过。
      } on Exception catch (e) {
        failures[disc] = e.toString();
      }
    }
    return failures;
  }
}
