/// 存量迁移：旧版按「无画面的视频」收进视频库的纯音频条目，搬到音乐库并从视频库移除
/// （用户 2026-11-06 拍板，反馈 QAondMh4M5；旧设计见提交 1e1a711a32）。
///
/// 每次启动跑一遍（[migrateAudioOnlyVideoBooksToMusic]），**按数据幂等**：判据是「视频库
/// 里还有没有本地纯音频行」，没有就什么都不做；搬过的行已删，不会再搬第二次。一行只有
/// 在它的文件**已经是音乐库里的在库曲目**之后才删，入库失败（原生库缺失、文件读不了、
/// 曲库不认的格式如 `.m4b` / `.ac3`）的行原样留在视频库，下次启动再试，绝不先删后补。
///
/// 入库走 [MusicAudioIntake]（与视频来源扫描、视频页拖放同一条交接）：
/// - 属于本地视频来源的行：按 `music_audio_roots.dart` 的规则登记常驻音乐来源（判
///   「与视频同目录」用同来源里其余非音频视频行所在目录）；
/// - 其余（手动导入、与视频同目录、网络来源已不在的）：已被音乐来源覆盖的重扫该来源，
///   否则逐个「仅此一次」导入。
///
/// 能保留的保留：
/// - 观看记录 → 一条音乐播放记录（`music_play_events`：开始时刻 = 最后播放时刻，收听
///   时长 = 断点（看完则取曲长），看完 = 完整听完），曲目由此进「最近播放」。音乐没有
///   逐曲断点续播，断点本身无处可放。
/// - 学习统计（`study_segments`，按 bookUid 键控）**不删、不改键**：删视频行不碰这张
///   事实表，历史时长照旧计在当时的视频面上；改键会让已同步到别的设备的段对不上。
/// - 标签、书架条目、视频合集成员随视频行一起删（音乐库没有对应物）；被删空的音频专辑
///   合集随之删除。
/// - 生成过的字幕（[_carryOverSubtitles]，按**路径**认，不只看 `subtitleSource`——整季
///   生成、或行上已有别的选择时，产物不会登记进 `subtitleSource`）：音频旁本管线写的
///   `<主名>.ja.srt`（`state.json` 哈希对得上）/ `.ja.asr.srt` 转成该曲的 `asr` 歌词行，
///   曲库歌词搜索立即可搜；用户在视频行上选过、又不在音频旁（app 文档目录里的导入 /
///   Jimaku / OCR 字幕，sidecar 规则认不到）的字幕转成该曲的手动指定（`user` 行）。
///   带走失败的行这次不删、下次再试。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show isDefaultVideoSubtitlePipelineOutput;
import 'package:fushi_engine/media/video/strm_file.dart'
    show isNetworkOnlyVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart' show DeleteScope;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/asr/music_asr_subtitle_sink.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';

/// 一次迁移的结果。
class VideoAudioMigrationReport {
  const VideoAudioMigrationReport({
    required this.candidates,
    required this.migrated,
    required this.playEventsWritten,
    required this.errors,
    this.subtitlesCarried = 0,
  });

  static const VideoAudioMigrationReport none = VideoAudioMigrationReport(
    candidates: 0,
    migrated: 0,
    playEventsWritten: 0,
    errors: <String>[],
  );

  /// 带进音乐库的字幕条数（`asr` / `user` 歌词行）。
  final int subtitlesCarried;

  /// 视频库里的本地纯音频行数（文件还在的）。
  final int candidates;

  /// 搬进音乐库并已从视频库删除的行数。
  final int migrated;

  /// 写下的播放记录条数。
  final int playEventsWritten;

  /// 交接时的扫描错误摘要。
  final List<String> errors;

  /// 还留在视频库里的候选行数（下次启动再试）。
  int get leftInVideoLibrary => candidates - migrated;
}

/// 纯函数：这一行是不是要搬的旧版「无画面视频」——本地纯音频单文件（多集合集行的
/// `videoPath` 只是其中一集，不在此列；网络流没有本地文件，音乐库收不了）。
bool isLegacyAudioOnlyVideoBook(VideoBookRow row) =>
    isAudioOnlyMediaPath(row.videoPath) &&
    (row.playlistJson ?? '').trim().isEmpty &&
    !isNetworkOnlyVideoPath(row.videoPath) &&
    p.isAbsolute(row.videoPath);

/// 见文件头。[fileExists] 默认真文件系统；[intake] / [repository] 测试注入。
/// [lyrics] + [subtitleJobsRoot]（视频字幕任务目录根）给了才带走生成过的字幕。
Future<VideoAudioMigrationReport> migrateAudioOnlyVideoBooksToMusic(
  FushiDatabase db, {
  MusicAudioIntake? intake,
  VideoBookRepository? repository,
  required bool Function(String path) fileExists,
  MusicLyricsService? lyrics,
  Directory? subtitleJobsRoot,
}) async {
  final VideoBookRepository repo = repository ?? VideoBookRepository(db);
  final List<VideoBookRow> all = await repo.listAll();
  final List<VideoBookRow> rows = <VideoBookRow>[
    for (final VideoBookRow r in all)
      if (isLegacyAudioOnlyVideoBook(r) && fileExists(r.videoPath)) r,
  ];
  if (rows.isEmpty) return VideoAudioMigrationReport.none;
  final MusicAudioIntake hand =
      intake ?? MusicAudioIntake(db, fileExists: fileExists);
  final List<String> errors = <String>[];

  // 1. 属于本地视频来源的行：按来源登记常驻音乐来源。
  final Map<int, List<VideoBookRow>> bySource = <int, List<VideoBookRow>>{};
  for (final VideoBookRow r in rows) {
    final int? sid = r.sourceId;
    if (sid != null) bySource.putIfAbsent(sid, () => <VideoBookRow>[]).add(r);
  }
  for (final MapEntry<int, List<VideoBookRow>> e in bySource.entries) {
    final SourceLibraryRow? source = await db.getMediaSourceById(e.key);
    if (source == null ||
        source.transport != 'local' ||
        source.mediaKind != SourceLibraryKind.video.dbValue) {
      continue;
    }
    final MusicAudioIntakeResult r = await hand.adoptVideoSourceAudio(
      videoRoot: source.rootPath,
      audioPaths: <String>[
        for (final VideoBookRow row in e.value) row.videoPath,
      ],
      videoMediaDirs: <String>{
        for (final VideoBookRow other in all)
          if (other.sourceId == e.key &&
              !isAudioOnlyMediaPath(other.videoPath) &&
              !isNetworkOnlyVideoPath(other.videoPath))
            p.dirname(other.videoPath),
      },
    );
    errors.addAll(r.errors);
  }

  // 2. 还不是在库曲目的：逐个交接（覆盖它的来源重扫 / 仅此一次导入）。
  Map<String, MusicTrackRow> live = await _liveTracksByPath(db);
  final List<String> pending = <String>[
    for (final VideoBookRow r in rows)
      if (!live.containsKey(_key(r.videoPath))) r.videoPath,
  ];
  if (pending.isNotEmpty) {
    final MusicAudioIntakeResult r = await hand.importAudioFiles(pending);
    errors.addAll(r.errors);
    live = await _liveTracksByPath(db);
  }

  // 3. 已在曲库的行：带走字幕与播放记录，再从视频库删除。字幕带走失败的行这次不删。
  final Map<String, List<MusicTrackRow>> tracksByPath =
      await _liveTrackListsByPath(db);
  final List<VideoBookRow> done = <VideoBookRow>[];
  int events = 0;
  int carried = 0;
  for (final VideoBookRow r in rows) {
    if (!live.containsKey(_key(r.videoPath))) continue;
    if (lyrics != null && subtitleJobsRoot != null) {
      try {
        carried += await _carryOverSubtitles(
          r,
          tracksByPath[_key(r.videoPath)]!,
          lyrics: lyrics,
          jobsRoot: subtitleJobsRoot,
          errors: errors,
        );
      } on Object catch (e) {
        errors.add('subtitle ${r.videoPath}: $e');
        continue;
      }
    }
    if (await _carryOverPlay(db, r, live[_key(r.videoPath)]!)) events++;
    done.add(r);
  }
  if (done.isNotEmpty) {
    await repo.deleteVideoBooksAndReclaimAssets(
      <String>[for (final VideoBookRow r in done) r.bookUid],
      scope: DeleteScope.keepLocalOnly,
      compactDatabase: false,
    );
  }
  return VideoAudioMigrationReport(
    candidates: rows.length,
    migrated: done.length,
    playEventsWritten: events,
    errors: errors,
    subtitlesCarried: carried,
  );
}

/// 在库曲目按路径（[_key]）分组（CUE 拆出的虚拟曲目共用一个路径）。
Future<Map<String, List<MusicTrackRow>>> _liveTrackListsByPath(
  FushiDatabase db,
) async {
  final Map<String, List<MusicTrackRow>> out = <String, List<MusicTrackRow>>{};
  for (final MusicTrackRow t in await (db.select(
    db.musicTracks,
  )..where(($MusicTracksTable t) => t.deletedAt.isNull())).get()) {
    out.putIfAbsent(_key(t.path), () => <MusicTrackRow>[]).add(t);
  }
  return out;
}

/// 视频行生成 / 选过的字幕 → 音乐库歌词行（见文件头）。返回写了几条；读写库失败抛出
/// （这一行这次不删）。
///
/// - 本管线产物（[isDefaultVideoSubtitlePipelineOutput]）：优先行上选着的那份，其次
///   `<主名>.ja.srt`、`.ja.asr.srt`；带样式的 `.ass` 换成同名 SRT。写成 `asr` 行（CUE
///   虚拟曲目按区间切），已有 `asr` 行的曲目不覆盖（迁移每次启动都跑，下次重跑不重写）。
/// - 用户选过的别的字幕文件：不在音频旁（音频旁同主名的由 sidecar 规则直接显示）时写成
///   `user` 行；只对单一整文件曲目做（CUE 镜像的整文件字幕时间轴对不上各曲）。
Future<int> _carryOverSubtitles(
  VideoBookRow row,
  List<MusicTrackRow> tracks, {
  required MusicLyricsService lyrics,
  required Directory jobsRoot,
  required List<String> errors,
}) async {
  final String audio = row.videoPath;
  final String dir = p.dirname(audio);
  final String stem = p.basenameWithoutExtension(audio);
  bool own(String path) => isDefaultVideoSubtitlePipelineOutput(
    jobsRoot: jobsRoot,
    mediaPath: audio,
    path: path,
  );
  String srtOf(String path) => p.extension(path).toLowerCase() == '.ass'
      ? p.setExtension(path, '.srt')
      : path;

  final String? selected = row.subtitleSource?.trim().isEmpty ?? true
      ? null
      : row.subtitleSource!.trim();
  final List<String> ownCandidates = <String>[
    if (selected != null) srtOf(selected),
    p.join(dir, '$stem.ja.srt'),
    p.join(dir, '$stem.ja.asr.srt'),
  ];
  String? generated;
  for (final String c in ownCandidates) {
    if (await File(c).exists() && own(c)) {
      generated = c;
      break;
    }
  }
  int wrote = 0;
  if (generated != null) {
    final Set<String> have = await lyrics.tracksWithGenerated(<String>[
      for (final MusicTrackRow t in tracks) t.trackUid,
    ]);
    final List<MusicAsrTrackSlot> slots = <MusicAsrTrackSlot>[
      for (final MusicTrackRow t in tracks)
        if (!have.contains(t.trackUid))
          MusicAsrTrackSlot(
            trackUid: t.trackUid,
            cueStartMs: t.cueStartMs,
            cueEndMs: t.cueStartMs == null ? null : t.cueEndMs,
          ),
    ];
    wrote += (await saveGeneratedSubtitleForTracks(
      lyrics,
      await File(generated).readAsBytes(),
      slots,
    )).length;
  }
  final bool besideAudio =
      selected != null &&
      p.equals(p.dirname(selected), dir) &&
      p.basename(selected).toLowerCase().startsWith('${stem.toLowerCase()}.');
  if (selected != null &&
      !besideAudio &&
      (generated == null || !p.equals(srtOf(selected), generated)) &&
      tracks.length == 1 &&
      tracks.single.cueStartMs == null &&
      p.isAbsolute(selected) &&
      await File(selected).exists() &&
      !await lyrics.hasUserChoice(tracks.single.trackUid)) {
    if (await lyrics.chooseFile(
      tracks.single.trackUid,
      selected,
      durationMs: tracks.single.durationMs,
    )) {
      wrote++;
    } else {
      // 文件读不了 / 不是字幕：带不走也不该让这一行永远卡在视频库，记下来照常迁移。
      errors.add('subtitle not readable: $selected');
    }
  }
  return wrote;
}

/// 路径比较键：音乐扫描拼出的路径与视频行记的路径分隔符 / 大小写写法可能不同
/// （来源根按正斜杠归一、Rust 用平台分隔符拼文件名）。
String _key(String path) => p.canonicalize(path);

/// 在库曲目按路径（[_key]）索引。CUE 拆出的虚拟曲目共用一个路径，取起点最早的一首。
Future<Map<String, MusicTrackRow>> _liveTracksByPath(FushiDatabase db) async {
  final Map<String, MusicTrackRow> out = <String, MusicTrackRow>{};
  for (final MusicTrackRow t in await (db.select(
    db.musicTracks,
  )..where(($MusicTracksTable t) => t.deletedAt.isNull())).get()) {
    final String k = _key(t.path);
    final MusicTrackRow? prev = out[k];
    if (prev == null || (t.cueStartMs ?? 0) < (prev.cueStartMs ?? 0)) {
      out[k] = t;
    }
  }
  return out;
}

/// 视频行的观看记录 → 一条音乐播放记录。没播放过不写；同一首同一时刻已有记录（上次
/// 迁移写完记录、删行前被打断）不重复写。返回是否写了。
Future<bool> _carryOverPlay(
  FushiDatabase db,
  VideoBookRow row,
  MusicTrackRow track,
) async {
  final int? playedAt = row.lastPlayedAt;
  if (playedAt == null) return false;
  final List<MusicPlayEventRow> existing =
      await (db.select(db.musicPlayEvents)..where(
            ($MusicPlayEventsTable e) =>
                e.trackUid.equals(track.trackUid) &
                e.startedAt.equals(playedAt),
          ))
          .get();
  if (existing.isNotEmpty) return false;
  final bool completed = row.completedAt != null;
  final int id = await db.startMusicPlayEvent(
    trackUid: track.trackUid,
    startedAt: playedAt,
  );
  await db.finishMusicPlayEvent(
    id,
    listenedMs: completed
        ? (track.durationMs ?? row.lastPositionMs)
        : row.lastPositionMs,
    completed: completed,
  );
  return true;
}
