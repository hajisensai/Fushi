/// 存量迁移：旧版按「无画面的视频」收进视频库的纯音频条目，搬到音乐库并从视频库移除
/// （用户 2026-11-06 拍板，反馈 QAondMh4M5；旧设计见提交 1e1a711a32）。
///
/// 每次启动跑一遍（[migrateAudioOnlyVideoBooksToMusic]），**按数据幂等**：判据是「视频库
/// 里还有没有本地纯音频行」，没有就什么都不做；搬过的行已删，不会再搬第二次。一行只有
/// 在它的文件**已经是音乐库里的在库曲目**之后才删，入库失败（原生库缺失、文件读不了、
/// 坏文件）的行原样留在视频库，下次启动再试，绝不先删后补。
///
/// 入库走 [MusicAudioIntake]（与视频来源扫描、视频页拖放同一条交接）：
/// - 属于本地视频来源的行：按 `music_audio_roots.dart` 的规则登记常驻音乐来源（判
///   「与视频同目录」用同来源里其余非音频视频行所在目录）；
/// - 属于网络视频来源（SFTP / WebDAV / AList）的行：登记同一台服务器上的网络音乐来源
///   （[MusicAudioIntake.adoptRemoteVideoSourceAudio]），曲目按条目地址原样认；
/// - 其余（手动导入、与视频同目录、网络来源已不在的）：已被音乐来源覆盖的重扫该来源，
///   否则逐个「仅此一次」导入。
///
/// 能保留的保留：
/// - 观看记录 → 一条音乐播放记录（`music_play_events`：开始时刻 = 最后播放时刻，收听
///   时长 = 断点（看完则取曲长），看完 = 完整听完），曲目由此进「最近播放」。
/// - 没看完的断点 → 音乐逐曲断点（`music_resume_points`，`music_resume.dart`），再打开从
///   那里接着放。已在片尾区的（读取时也会从头放）不写。
/// - 一个文件拆成多首（整轨 + CUE、M4B 章节、内嵌 CUE）时视频行的断点是整个文件上的
///   绝对位置：播放记录和断点都落在断点所在的那一首，断点存相对那一首起点的位置、收听
///   时长按那一首的起点折算；看完的记在最后一首（[pickMigratedTrack]）。
/// - 字幕见末条（[_carryOverSubtitles]；拆成多首时按各曲区间切成曲内时间）。用户选过的
///   字幕带不走（读不到 / 解析失败）时：落在 app 的 `video_subtitles/`（导入副本，删行会
///   被回收，BUG-4175）的那一行**不删**、下次启动再试；在别处的照常迁移（删行不碰那个
///   文件），只记一条错误。副字幕不搬。
/// - 原始音频文件转交给音乐曲目：删行时进删除护栏（[VideoBookRepository.deleteVideoBooksAndReclaimAssets]
///   的 `keepLocalFiles`），iOS 选择器副本也不回收，否则曲目指向的文件会被删掉。
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
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart'
    show kStreamableVideoSourceTransports;

/// 一次迁移的结果。
class VideoAudioMigrationReport {
  const VideoAudioMigrationReport({
    required this.candidates,
    required this.migrated,
    required this.playEventsWritten,
    this.resumePointsWritten = 0,
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

  /// 带过来的断点条数。
  final int resumePointsWritten;

  /// 交接时的扫描错误摘要。
  final List<String> errors;

  /// 还留在视频库里的候选行数（下次启动再试）。
  int get leftInVideoLibrary => candidates - migrated;
}

/// 纯函数：这一行是不是要搬的旧版「无画面视频」——本地纯音频单文件（多集合集行的
/// `videoPath` 只是其中一集，不在此列；网络来源的行见 [isLegacyRemoteAudioOnlyVideoBook]）。
bool isLegacyAudioOnlyVideoBook(VideoBookRow row) =>
    isAudioOnlyMediaPath(row.videoPath) &&
    (row.playlistJson ?? '').trim().isEmpty &&
    !isNetworkOnlyVideoPath(row.videoPath) &&
    p.isAbsolute(row.videoPath);

/// 纯函数：这一行是不是要搬的旧版网络来源纯音频（反馈 QAondMh4M5）——属于某个来源、
/// 路径是网络来源条目地址（`sftp://` 稳定地址 / WebDAV·AList 的 http(s) 地址）的纯音频
/// 单文件。番剧源 / 媒体服务器 / 手动贴的 URL 没有 sourceId，不在此列：音乐库没有对应的
/// 网络来源可以收它们。
bool isLegacyRemoteAudioOnlyVideoBook(VideoBookRow row) {
  if (row.sourceId == null) return false;
  if (!isAudioOnlyMediaPath(row.videoPath)) return false;
  if ((row.playlistJson ?? '').trim().isNotEmpty) return false;
  final String lower = row.videoPath.toLowerCase();
  return lower.startsWith('sftp://') ||
      lower.startsWith('https://') ||
      lower.startsWith('http://');
}

/// 见文件头。[fileExists] 默认真文件系统；[intake] / [repository] 测试注入。
/// [lyrics] 是字幕的落点，[subtitleJobsRoot] 是视频字幕任务目录根（认本管线产物），
/// [importedSubtitlesDir] 是视频库导入字幕副本目录（`VideoStorage.subtitlesDir`，删行会
/// 回收里面的文件）。三者必给：少了任何一个就会在删行时悄悄丢掉字幕。
Future<VideoAudioMigrationReport> migrateAudioOnlyVideoBooksToMusic(
  FushiDatabase db, {
  MusicAudioIntake? intake,
  VideoBookRepository? repository,
  required bool Function(String path) fileExists,
  required MusicLyricsService lyrics,
  required Directory subtitleJobsRoot,
  required Directory importedSubtitlesDir,
}) async {
  final VideoBookRepository repo = repository ?? VideoBookRepository(db);
  final List<VideoBookRow> all = await repo.listAll();
  final List<VideoBookRow> rows = <VideoBookRow>[
    for (final VideoBookRow r in all)
      if (isLegacyAudioOnlyVideoBook(r) && fileExists(r.videoPath)) r,
  ];
  final List<VideoBookRow> remoteRows = <VideoBookRow>[
    for (final VideoBookRow r in all)
      if (isLegacyRemoteAudioOnlyVideoBook(r)) r,
  ];
  if (rows.isEmpty && remoteRows.isEmpty) {
    return VideoAudioMigrationReport.none;
  }
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
    // 只交来这几个旧行，不是视频根下的全貌：不对账（reconcile 默认 false）。
    final MusicAudioIntakeResult r = await hand.adoptVideoSourceAudio(
      owner: source,
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
      videoFilePaths: <String>[
        for (final VideoBookRow other in all)
          if (other.sourceId == e.key &&
              !isAudioOnlyMediaPath(other.videoPath) &&
              !isNetworkOnlyVideoPath(other.videoPath))
            other.videoPath,
      ],
    );
    errors.addAll(r.errors);
  }

  // 1b. 网络视频来源（SFTP / WebDAV / AList）的行：登记同一台服务器上的网络音乐来源并
  // 扫描；已被同服务器音乐来源覆盖的，重扫覆盖它的来源。条目地址与视频行同一命名空间。
  // 与视频同目录的（外挂音轨）不收、留在视频库；连不上的下次启动再试。
  final Map<int, List<VideoBookRow>> remoteBySource =
      <int, List<VideoBookRow>>{};
  for (final VideoBookRow r in remoteRows) {
    remoteBySource.putIfAbsent(r.sourceId!, () => <VideoBookRow>[]).add(r);
  }
  for (final MapEntry<int, List<VideoBookRow>> e in remoteBySource.entries) {
    final SourceLibraryRow? source = await db.getMediaSourceById(e.key);
    if (source == null ||
        !kStreamableVideoSourceTransports.contains(source.transport) ||
        source.mediaKind != SourceLibraryKind.video.dbValue) {
      continue;
    }
    final MusicAudioIntakeResult r = await hand.adoptRemoteVideoSourceAudio(
      videoSource: source,
      scanRoot: remoteSourceNamespacedRoot(source),
      audioPaths: <String>[
        for (final VideoBookRow row in e.value) row.videoPath,
      ],
      videoMediaDirs: <String>{
        for (final VideoBookRow other in all)
          if (other.sourceId == e.key && !isAudioOnlyMediaPath(other.videoPath))
            p.url.dirname(other.videoPath),
      },
      videoFilePaths: <String>[
        for (final VideoBookRow other in all)
          if (other.sourceId == e.key && !isAudioOnlyMediaPath(other.videoPath))
            other.videoPath,
      ],
      rescanCoveringSources: true,
    );
    errors.addAll(r.errors);
  }

  // 2. 还不是在库曲目的：逐个交接（覆盖它的来源重扫 / 仅此一次导入）。
  Map<String, List<MusicTrackRow>> live = await _liveTracksByPath(db);
  final List<String> pending = <String>[
    for (final VideoBookRow r in rows)
      if (!live.containsKey(_key(r.videoPath))) r.videoPath,
  ];
  if (pending.isNotEmpty) {
    final MusicAudioIntakeResult r = await hand.importAudioFiles(pending);
    errors.addAll(r.errors);
    live = await _liveTracksByPath(db);
  }
  // 网络来源曲目按地址**原样**比（不 canonicalize：URL 区分大小写，`p.canonicalize`
  // 在 Windows 上还会把 `/` 换成 `\`）。
  final Map<String, List<MusicTrackRow>> remoteLive = remoteRows.isEmpty
      ? const <String, List<MusicTrackRow>>{}
      : await _liveTracksByPath(db, key: (String path) => path);
  List<MusicTrackRow>? tracksOf(VideoBookRow r) =>
      isLegacyRemoteAudioOnlyVideoBook(r)
      ? remoteLive[r.videoPath]
      : live[_key(r.videoPath)];

  // 3. 已在曲库的行：带走字幕与播放记录，再从视频库删除。字幕带走失败的行这次不删。
  final List<VideoBookRow> done = <VideoBookRow>[];
  int events = 0;
  int resumes = 0;
  int carried = 0;
  for (final VideoBookRow r in <VideoBookRow>[...rows, ...remoteRows]) {
    final List<MusicTrackRow>? tracks = tracksOf(r);
    if (tracks == null || tracks.isEmpty) continue;
    try {
      final ({int wrote, bool keepRow}) sub = await _carryOverSubtitles(
        r,
        tracks,
        lyrics: lyrics,
        jobsRoot: subtitleJobsRoot,
        importedSubtitlesDir: importedSubtitlesDir,
        errors: errors,
      );
      carried += sub.wrote;
      if (sub.keepRow) continue;
    } on Object catch (e) {
      errors.add('subtitle ${r.videoPath}: $e');
      continue;
    }
    final MigratedTrack target = pickMigratedTrack(
      tracks,
      positionMs: r.lastPositionMs,
      completed: r.completedAt != null,
    );
    if (await _carryOverPlay(db, r, target)) events++;
    if (await _carryOverResume(db, r, target.track, target.relativeMs)) {
      resumes++;
    }
    done.add(r);
  }
  if (done.isNotEmpty) {
    await repo.deleteVideoBooksAndReclaimAssets(
      <String>[for (final VideoBookRow r in done) r.bookUid],
      scope: DeleteScope.keepLocalOnly,
      compactDatabase: false,
      keepLocalFiles: <String>[
        for (final VideoBookRow r in done)
          if (!isLegacyRemoteAudioOnlyVideoBook(r)) r.videoPath,
      ],
    );
  }
  return VideoAudioMigrationReport(
    candidates: rows.length + remoteRows.length,
    migrated: done.length,
    playEventsWritten: events,
    resumePointsWritten: resumes,
    errors: errors,
    subtitlesCarried: carried,
  );
}

/// 视频行生成 / 选过的字幕 → 音乐库歌词行（见文件头）。返回写了几条、这一行这次要不要
/// 留在视频库；读写库失败抛出（这一行这次不删）。
///
/// - 本管线产物（[isDefaultVideoSubtitlePipelineOutput]）：优先行上选着的那份，其次
///   `<主名>.ja.srt`、`.ja.asr.srt`；带样式的 `.ass` 换成同名 SRT。写成 `asr` 行（CUE
///   虚拟曲目按区间切），已有 `asr` 行的曲目不覆盖（迁移每次启动都跑，下次重跑不重写）。
/// - 用户选过的别的字幕文件：不在音频旁（音频旁同主名的由 sidecar 规则直接显示）时写成
///   `user` 行；CUE 镜像按各曲区间切成曲内时间（字幕时间轴是整文件的），已有手动指定的
///   曲目不覆盖。
Future<({int wrote, bool keepRow})> _carryOverSubtitles(
  VideoBookRow row,
  List<MusicTrackRow> tracks, {
  required MusicLyricsService lyrics,
  required Directory jobsRoot,
  required Directory importedSubtitlesDir,
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
  // 网络来源的行（条目地址）旁边没有本地文件可找：只认行上选着的那份。
  final bool localAudio = !isLegacyRemoteAudioOnlyVideoBook(row);
  final List<String> ownCandidates = <String>[
    if (selected != null) srtOf(selected),
    if (localAudio) p.join(dir, '$stem.ja.srt'),
    if (localAudio) p.join(dir, '$stem.ja.asr.srt'),
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
      p.isAbsolute(selected) &&
      await File(selected).exists()) {
    final List<String>? chose = await lyrics
        .chooseFileForTracks(selected, <MusicLyricsFileTrack>[
          for (final MusicTrackRow t in tracks)
            (
              trackUid: t.trackUid,
              cueStartMs: t.cueStartMs,
              cueEndMs: t.cueStartMs == null ? null : t.cueEndMs,
              durationMs: t.durationMs,
            ),
        ]);
    if (chose != null) {
      wrote += chose.length;
    } else if (p.isWithin(importedSubtitlesDir.path, selected)) {
      // 导入副本：删行会把它回收（BUG-4175），带不走就这次不删、下次启动再试。
      errors.add('subtitle not carried, row kept: $selected');
      return (wrote: wrote, keepRow: true);
    } else {
      // 别处的文件读不了 / 不是字幕：删行不碰它，不该让这一行永远卡在视频库，记下来
      // 照常迁移。
      errors.add('subtitle not readable: $selected');
    }
  }
  return (wrote: wrote, keepRow: false);
}

/// 路径比较键：曲库全仓只用 [musicTrackPathKey] 这一个定义（扫描落库认旧行用的也是它）。
String _key(String path) => musicTrackPathKey(path);

/// 在库曲目按路径（[_key]）索引。CUE / M4B 章节拆出的虚拟曲目共用一个路径，全部保留、
/// 按起点升序。
Future<Map<String, List<MusicTrackRow>>> _liveTracksByPath(
  FushiDatabase db, {
  String Function(String path) key = _key,
}) async {
  final Map<String, List<MusicTrackRow>> out = <String, List<MusicTrackRow>>{};
  for (final MusicTrackRow t in await (db.select(
    db.musicTracks,
  )..where(($MusicTracksTable t) => t.deletedAt.isNull())).get()) {
    out.putIfAbsent(key(t.path), () => <MusicTrackRow>[]).add(t);
  }
  for (final List<MusicTrackRow> tracks in out.values) {
    tracks.sort(
      (MusicTrackRow a, MusicTrackRow b) =>
          (a.cueStartMs ?? 0).compareTo(b.cueStartMs ?? 0),
    );
  }
  return out;
}

/// 一行旧视频记录落到哪一首：[MigratedTrack.track]、相对它起点的断点
/// `relativeMs`（逐曲断点用）与收听时长 `listenedMs`（播放记录用）。
typedef MigratedTrack = ({MusicTrackRow track, int relativeMs, int listenedMs});

/// 纯函数：同一文件拆出的曲目 [tracks]（按起点升序，至少一首；普通单文件只有一首）里，
/// 视频行的观看记录该落到哪一首。[positionMs] 是视频行的断点（整个文件上的绝对位置）。
///
/// - 看完（[completed]）→ 最后一首，收听时长 = 那一首的曲长（未知时按断点折算）；
/// - 否则 → 起点 ≤ 断点的最后一首（曲目首尾相接；最后一轨常不知道终点，断点超过文件尾
///   也落在它上面；断点在第一首之前（含 0）落在第一首）。收听时长 = 断点 − 那一首的
///   起点，不超过那一首的曲长。
///
/// `relativeMs` = 断点 − 所选那一首的起点，夹到 ≥ 0、不夹曲长（超出曲长由断点写入方按
/// 片尾区判掉）。
MigratedTrack pickMigratedTrack(
  List<MusicTrackRow> tracks, {
  required int positionMs,
  required bool completed,
}) {
  MusicTrackRow target = tracks.first;
  if (completed) {
    target = tracks.last;
  } else {
    for (final MusicTrackRow t in tracks) {
      if ((t.cueStartMs ?? 0) <= positionMs) target = t;
    }
  }
  final int offset = positionMs - (target.cueStartMs ?? 0);
  final int relativeMs = offset < 0 ? 0 : offset;
  final int? duration = target.durationMs;
  final int listenedMs = completed
      ? (duration ?? relativeMs)
      : (duration != null && relativeMs > duration ? duration : relativeMs);
  return (track: target, relativeMs: relativeMs, listenedMs: listenedMs);
}

/// 视频行的观看记录 → 一条音乐播放记录。没播放过不写；同一首同一时刻已有记录（上次
/// 迁移写完记录、删行前被打断）不重复写。返回是否写了。
Future<bool> _carryOverPlay(
  FushiDatabase db,
  VideoBookRow row,
  MigratedTrack target,
) async {
  final MusicTrackRow track = target.track;
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
    listenedMs: target.listenedMs,
    completed: completed,
  );
  return true;
}

/// 视频行没看完的断点 → 音乐逐曲断点（[track] 上、相对它起点的 [relativeMs]）。看完 /
/// 没断点 / 已在片尾区不写；库里已有同一首更新（或同刻）的断点不覆盖——重跑幂等，也
/// 不把用户在音乐库里听到的新位置倒退回去。返回是否写了。
Future<bool> _carryOverResume(
  FushiDatabase db,
  VideoBookRow row,
  MusicTrackRow track,
  int relativeMs,
) async {
  if (row.completedAt != null || row.lastPositionMs <= 0) return false;
  if (musicResumePointIsFinished(
    positionMs: relativeMs,
    durationMs: track.durationMs,
  )) {
    return false;
  }
  final int at = row.lastPlayedAt ?? 0;
  final MusicResumePointRow? existing = await db.getMusicResumePoint(
    track.trackUid,
  );
  if (existing != null && existing.updatedAt >= at) return false;
  await db.upsertMusicResumePoint(
    track.trackUid,
    positionMs: relativeMs,
    durationMs: track.durationMs,
    updatedAt: at,
  );
  return true;
}
