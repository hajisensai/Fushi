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
/// - 挂着的主字幕（多半是 ASR 转写，存在 app 的 `video_subtitles/` 里，删行会被回收）→
///   这首的手动指定歌词（[MusicSubtitleAdopter]，音乐歌词认 SRT / ASS / VTT / LRC）。
///   字幕搬不过去（读不到 / 解析失败）的行**不删**，下次启动再试；副字幕不搬。
/// - 原始音频文件转交给音乐曲目：删行时进删除护栏（[VideoBookRepository.deleteVideoBooksAndReclaimAssets]
///   的 `keepLocalFiles`），iOS 选择器副本也不回收，否则曲目指向的文件会被删掉。
/// - 学习统计（`study_segments`，按 bookUid 键控）**不删、不改键**：删视频行不碰这张
///   事实表，历史时长照旧计在当时的视频面上；改键会让已同步到别的设备的段对不上。
/// - 标签、书架条目、视频合集成员随视频行一起删（音乐库没有对应物）；被删空的音频专辑
///   合集随之删除。
library;

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/strm_file.dart'
    show isNetworkOnlyVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart' show DeleteScope;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_audio_intake.dart';

/// 把视频行挂的字幕文件 [subtitlePath] 定为曲目 [track] 的歌词；失败抛出（调用方据此
/// 保留源行）。生产接 `MusicLyricsService.adoptSubtitleFile`。
typedef MusicSubtitleAdopter =
    Future<void> Function(MusicTrackRow track, String subtitlePath);

/// 一次迁移的结果。
class VideoAudioMigrationReport {
  const VideoAudioMigrationReport({
    required this.candidates,
    required this.migrated,
    required this.playEventsWritten,
    required this.errors,
  });

  static const VideoAudioMigrationReport none = VideoAudioMigrationReport(
    candidates: 0,
    migrated: 0,
    playEventsWritten: 0,
    errors: <String>[],
  );

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
Future<VideoAudioMigrationReport> migrateAudioOnlyVideoBooksToMusic(
  FushiDatabase db, {
  MusicAudioIntake? intake,
  VideoBookRepository? repository,
  required bool Function(String path) fileExists,
  required MusicSubtitleAdopter adoptSubtitle,
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

  // 3. 已在曲库的行：搬字幕（搬不过去的行留下）、记播放记录，再从视频库删除。
  final List<VideoBookRow> done = <VideoBookRow>[];
  for (final VideoBookRow r in rows) {
    final MusicTrackRow? track = live[_key(r.videoPath)];
    if (track == null) continue;
    final String subtitle = (r.subtitleSource ?? '').trim();
    if (subtitle.isNotEmpty && p.isAbsolute(subtitle) && fileExists(subtitle)) {
      try {
        await adoptSubtitle(track, subtitle);
      } catch (e) {
        errors.add('${r.videoPath}: subtitle $subtitle: $e');
        continue;
      }
    }
    done.add(r);
  }
  int events = 0;
  for (final VideoBookRow r in done) {
    if (await _carryOverPlay(db, r, live[_key(r.videoPath)]!)) events++;
  }
  if (done.isNotEmpty) {
    await repo.deleteVideoBooksAndReclaimAssets(
      <String>[for (final VideoBookRow r in done) r.bookUid],
      scope: DeleteScope.keepLocalOnly,
      compactDatabase: false,
      keepLocalFiles: <String>[for (final VideoBookRow r in done) r.videoPath],
    );
  }
  return VideoAudioMigrationReport(
    candidates: rows.length,
    migrated: done.length,
    playEventsWritten: events,
    errors: errors,
  );
}

/// 路径比较键：曲库全仓只用 [musicTrackPathKey] 这一个定义（扫描落库认旧行用的也是它）。
String _key(String path) => musicTrackPathKey(path);

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
