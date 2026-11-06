/// 音乐库曲目 / 专辑 / 来源 → 「生成日语字幕」的目标（[AppVideoSubtitleTarget]）。
///
/// 与视频同一个服务、同一条管线、同一个面板（`AppVideoSubtitleService` /
/// `VideoSubtitlePipeline` / `showVideoSubtitleGenerateSheet`），只把产物落点换成
/// [MusicAsrSubtitleSink]。因此与视频生成共用「进程内同一时刻只跑一个任务」（识别占满
/// GPU / CPU），整张专辑批量时视频页会看到「已有任务在跑」。
///
/// 解析规则：
/// - 按**文件**去重成「集」：CUE 整轨多曲共用一个音频文件，只转写一次，登记时再按曲目
///   区间切（[MusicAsrTrackSlot]）；
/// - 插件 / 服务器 / Apple Music 等不是本机文件的曲目 → 不可处理（remote）；文件不在 →
///   missingFile；
/// - 批量（专辑 / 来源）时已有生成字幕（`asr` 行）的曲目跳过，整个文件的曲目都有了就不
///   排这个文件；单曲入口总是重新生成（覆盖）；
/// - 作品上下文（专名表的键）：专辑 `album:<albumUid>`，同一张广播剧 CD 各轨共用一张表。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart'
    show SubtitleWorkContext;
import 'package:fushi_engine/media/video/video_local_files.dart'
    show isLocalVideoFilePath;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/asr/music_asr_subtitle_sink.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart'
    show parseMusicPluginTrackPath;
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 纯函数：这首曲目是不是本机能转写的文件（插件 URI / 服务器流 / 相对路径都不是）。
bool isMusicTrackLocallyTranscribable(String path) =>
    parseMusicPluginTrackPath(path) == null && isLocalVideoFilePath(path);

class MusicSubtitleTargets {
  MusicSubtitleTargets({
    required this.database,
    required this.lyrics,
    Future<Directory> Function()? outRoot,
    Future<bool> Function(String path)? fileExists,
  }) : _outRoot =
           outRoot ??
           (() async => musicSubtitleOutRootUnder(
             await AppPaths.supportRootDirectory(),
           )),
       _fileExists = fileExists ?? ((String path) => File(path).exists());

  final FushiDatabase database;
  final MusicLyricsService lyrics;
  final Future<Directory> Function() _outRoot;
  final Future<bool> Function(String path) _fileExists;

  /// 单曲（歌词页 / 曲目详情页）：总是重新生成。
  Future<AppVideoSubtitleTarget> forTrack(String trackUid) async {
    final MusicTrackRow? row =
        await (database.select(database.musicTracks)
              ..where(($MusicTracksTable t) => t.trackUid.equals(trackUid)))
            .getSingleOrNull();
    if (row == null || row.deletedAt != null) {
      throw AppVideoSubtitleTargetNotFound('track $trackUid');
    }
    final MusicAlbumRow? album = await _album(row.albumUid);
    return _build(
      rows: <MusicTrackRow>[row],
      title: row.title,
      key: 'music:track:$trackUid',
      batch: false,
      work: _work(album, fallbackTitle: row.title, fallbackKey: trackUid),
    );
  }

  /// 整张专辑（专辑页「为本专辑生成字幕」）。
  Future<AppVideoSubtitleTarget> forAlbum(String albumUid) async {
    final MusicAlbumRow? album = await _album(albumUid);
    if (album == null) throw AppVideoSubtitleTargetNotFound('album $albumUid');
    final List<MusicTrackRow> rows =
        await (database.select(database.musicTracks)
              ..where(
                ($MusicTracksTable t) =>
                    t.albumUid.equals(albumUid) & t.deletedAt.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<$MusicTracksTable>>[
                ($MusicTracksTable t) => OrderingTerm.asc(t.discNo),
                ($MusicTracksTable t) => OrderingTerm.asc(t.trackNo),
                ($MusicTracksTable t) => OrderingTerm.asc(t.path),
              ]))
            .get();
    return _build(
      rows: rows,
      title: album.title,
      key: 'music:album:$albumUid',
      batch: true,
      work: _work(album, fallbackTitle: album.title, fallbackKey: albumUid),
    );
  }

  /// 整个音乐来源（来源页「为此来源生成字幕」）。
  Future<AppVideoSubtitleTarget> forSource(int sourceId, String title) async {
    final List<MusicTrackRow> rows =
        await (database.select(database.musicTracks)
              ..where(
                ($MusicTracksTable t) =>
                    t.sourceId.equals(sourceId) & t.deletedAt.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<$MusicTracksTable>>[
                ($MusicTracksTable t) => OrderingTerm.asc(t.path),
              ]))
            .get();
    return _build(
      rows: rows,
      title: title,
      key: 'music:source:$sourceId',
      batch: true,
      work: SubtitleWorkContext(
        workKey: 'music-source:$sourceId',
        title: title,
      ),
    );
  }

  Future<MusicAlbumRow?> _album(String? albumUid) async => albumUid == null
      ? null
      : await (database.select(database.musicAlbums)
              ..where(($MusicAlbumsTable a) => a.albumUid.equals(albumUid)))
            .getSingleOrNull();

  SubtitleWorkContext _work(
    MusicAlbumRow? album, {
    required String fallbackTitle,
    required String fallbackKey,
  }) => album == null
      ? SubtitleWorkContext(
          workKey: 'music-track:$fallbackKey',
          title: fallbackTitle,
        )
      : SubtitleWorkContext(
          workKey: 'album:${album.albumUid}',
          title: album.title,
        );

  Future<AppVideoSubtitleTarget> _build({
    required List<MusicTrackRow> rows,
    required String title,
    required String key,
    required bool batch,
    required SubtitleWorkContext work,
  }) async {
    final Set<String> done = batch
        ? await _tracksWithGenerated(<String>[
            for (final MusicTrackRow r in rows) r.trackUid,
          ])
        : const <String>{};
    final Map<String, List<MusicTrackRow>> byPath =
        <String, List<MusicTrackRow>>{};
    for (final MusicTrackRow r in rows) {
      byPath.putIfAbsent(r.path, () => <MusicTrackRow>[]).add(r);
    }
    final List<AppVideoSubtitleEpisode> episodes = <AppVideoSubtitleEpisode>[];
    final List<AppVideoSubtitleUnavailable> unavailable =
        <AppVideoSubtitleUnavailable>[];
    final Map<String, List<MusicAsrTrackSlot>> slots =
        <String, List<MusicAsrTrackSlot>>{};
    for (final MapEntry<String, List<MusicTrackRow>> e in byPath.entries) {
      final String path = e.key;
      final List<MusicTrackRow> pending = <MusicTrackRow>[
        for (final MusicTrackRow r in e.value)
          if (!done.contains(r.trackUid)) r,
      ];
      if (pending.isEmpty) continue;
      // 一个文件多首（CUE 整轨）时这一集以文件名示人，单首用曲名。
      final String episodeTitle = e.value.length > 1
          ? p.basenameWithoutExtension(path)
          : e.value.single.title;
      if (!isMusicTrackLocallyTranscribable(path)) {
        unavailable.add(
          AppVideoSubtitleUnavailable(
            title: episodeTitle,
            reason: AppVideoSubtitleUnavailableReason.remote,
          ),
        );
        continue;
      }
      // 存在性 async 判：音乐常在网络盘上（BUG-3756 同理）。
      if (!await _fileExists(path)) {
        unavailable.add(
          AppVideoSubtitleUnavailable(
            title: episodeTitle,
            reason: AppVideoSubtitleUnavailableReason.missingFile,
          ),
        );
        continue;
      }
      episodes.add(
        AppVideoSubtitleEpisode(videoPath: path, title: episodeTitle),
      );
      slots[path] = <MusicAsrTrackSlot>[
        for (final MusicTrackRow r in pending)
          MusicAsrTrackSlot(
            trackUid: r.trackUid,
            cueStartMs: r.cueStartMs,
            cueEndMs: r.cueStartMs == null ? null : r.cueEndMs,
          ),
      ];
    }
    return AppVideoSubtitleTarget(
      title: title,
      work: work,
      episodes: episodes,
      unavailable: unavailable,
      sink: MusicAsrSubtitleSink(
        outRoot: await _outRoot(),
        lyrics: lyrics,
        slotsByPath: slots,
      ),
      wholeSeason: batch,
      key: key,
    );
  }

  Future<Set<String>> _tracksWithGenerated(List<String> uids) async {
    if (uids.isEmpty) return const <String>{};
    final List<MusicLyricRow> rows =
        await (database.select(database.musicLyrics)..where(
              ($MusicLyricsTable l) =>
                  l.trackUid.isIn(uids) &
                  l.source.equals(MusicLyricsSource.asr) &
                  l.format.equals(kMusicLyricsNoneFormat).not(),
            ))
            .get();
    return <String>{for (final MusicLyricRow r in rows) r.trackUid};
  }
}
