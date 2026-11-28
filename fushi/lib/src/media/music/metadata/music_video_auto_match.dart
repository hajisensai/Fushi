/// 本地 MV 后台自动匹配：音乐来源扫完后，把曲库里还没有 MV 的本机曲目和它们附近的视频
/// （同目录 / MV 目录 / 附近蓝光盘的流），以及同一个下载发布里的特典 / 原盘流（整理后
/// 与 CD 不在一棵目录树里，见 `music_release_videos.dart`）做声纹对齐，过门的自动绑定，
/// 歌词页就能直接放。
///
/// 省的是重复劳动，不是判据：
/// - **按目录收一次候选**：同目录的歌共用一份候选清单（后台 isolate 里列目录 + stat）；
/// - **视频只解码一次**：视频音轨声纹落库（`music_video_prints`，文件大小 / 修改时刻变了才
///   重算），一张盘十首歌只解码一遍，重启也不再解码；
/// - **一对只对一次**：（歌, 视频版本）对过就记（`music_video_match_checks`），没对上也记，
///   文件不变下次直接跳过——所以没有 MV 的 B 面曲不会每次扫描都再对一遍。
///
/// 已有绑定的曲目不找（用户确认过的、在线的、本机文件还在的）；只有本地绑定的文件都已
/// 不在时才重新找。歌词页本身不触发任何解码，只读绑定。手动「找本地 MV」照旧强制重对。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/media/music/music_local_video.dart'
    show isMusicLocalFilePath;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart' show isVideoMediaPath;
import 'package:fushi_engine/media/music/metadata/music_release_videos.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart'
    show MusicVideoKind;
import 'package:path/path.dart' as p;

/// 按目录收候选（真 app 在后台 isolate 里跑 [collectMusicVideoFilesNear]；测试注入替身）。
/// 键是曲目目录，值是这个目录所属下载发布里的候选（[musicReleaseVideosForDir]，可空）。
typedef MusicVideoNearbyCollector =
    Future<Map<String, MusicVideoNearbyFiles>> Function(
      Map<String, List<MusicReleaseVideoCandidate>> dirs,
    );

Future<Map<String, MusicVideoNearbyFiles>> _collectInBackground(
  Map<String, List<MusicReleaseVideoCandidate>> dirs,
) => Isolate.run(
  () => <String, MusicVideoNearbyFiles>{
    for (final MapEntry<String, List<MusicReleaseVideoCandidate>> d
        in dirs.entries)
      d.key: collectMusicVideoFilesNear(d.key, release: d.value),
  },
);

/// 这首曲目参不参加后台匹配：本机文件、本身不是视频。纯函数。
bool musicTrackWantsAutoVideoMatch(MusicTrackRow track) =>
    track.deletedAt == null &&
    isMusicLocalFilePath(track.path) &&
    !isVideoMediaPath(track.path);

/// 已有的绑定还算不算数（算数就不再自动找）：用户确认过的、非本地的（在线 / 动画集）都
/// 算；本地绑定只在文件还在时算。
bool musicVideoBindingsSatisfied(List<MusicVideoRow> rows) => rows.any(
  (MusicVideoRow r) =>
      r.isUserBound ||
      r.kind != MusicVideoKind.local ||
      File(r.ref).existsSync(),
);

/// 后台自动匹配：同一时刻只跑一轮（对齐本身经识别器串行）；跑的时候再来的请求合并成
/// 「跑完再看一遍」。
class MusicVideoAutoMatcher extends ChangeNotifier {
  MusicVideoAutoMatcher({
    required FushiDatabase? Function() database,
    required bool Function() enabled,
    MusicVideoService Function(FushiDatabase db)? service,
    MusicVideoNearbyCollector? collect,
  }) : _database = database,
       _enabled = enabled,
       _service =
           service ?? ((FushiDatabase db) => MusicVideoService(database: db)),
       _collect = collect ?? _collectInBackground;

  final FushiDatabase? Function() _database;
  final bool Function() _enabled;
  final MusicVideoService Function(FushiDatabase db) _service;
  final MusicVideoNearbyCollector _collect;

  bool _running = false;
  bool _again = false;
  int _boundThisRun = 0;

  bool get isRunning => _running;

  /// 本轮新绑定的曲目数。
  int get boundThisRun => _boundThisRun;

  /// 请求一轮匹配（音乐来源扫描完 / 打开「有 MV 时背景放 MV」）。
  Future<void> schedule() async {
    if (!_enabled()) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _boundThisRun = 0;
    notifyListeners();
    try {
      do {
        _again = false;
        await _runOnce();
      } while (_again && _enabled());
    } on Object catch (e, st) {
      ErrorLogService.instance.log('MusicVideoAutoMatcher', e, st);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// 一轮绑定在**开轮时的那一个库**上（与响度扫描同一做法，BUG-5387）：换库 / 关库时
  /// 被取消，对到一半的那对不再等，旧库读出的曲目不会写进换上来的新库。
  Future<void> _runOnce() async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    try {
      await db.runBackgroundWork<void>(
        'music.videoAutoMatch',
        (DatabaseWorkToken work) => _runOnceOn(db, work),
      );
    } on DatabaseWorkCancelledException {
      // 库要关了：没对的配对仍缺 match_check，下次开库启动那一轮再对。
      _again = false;
    }
  }

  Future<void> _runOnceOn(FushiDatabase db, DatabaseWorkToken work) async {
    final Map<String, List<MusicTrackRow>> byDir =
        <String, List<MusicTrackRow>>{};
    for (final MusicTrackRow t in await db.listMusicTracks()) {
      if (!musicTrackWantsAutoVideoMatch(t)) continue;
      (byDir[p.dirname(t.path)] ??= <MusicTrackRow>[]).add(t);
    }
    if (byDir.isEmpty) return;
    final List<MusicRelease> releases = await loadMusicReleases(db);
    final Map<String, MusicVideoNearbyFiles> near = await _collect(
      <String, List<MusicReleaseVideoCandidate>>{
        for (final String dir in byDir.keys)
          dir: musicReleaseVideosForDir(dir, releases),
      },
    );
    final Set<String> withVideos = await db.musicTrackUidsWithVideos();
    final Map<(String, String), MusicVideoMatchCheckRow> checks = await db
        .allMusicVideoMatchChecks();
    final MusicVideoService service = _service(db);
    for (final MapEntry<String, List<MusicTrackRow>> dir in byDir.entries) {
      final MusicVideoNearbyFiles? files = near[dir.key];
      if (files == null || files.isEmpty) continue;
      for (final MusicTrackRow track in dir.value) {
        if (!_enabled()) return;
        if (withVideos.contains(track.trackUid) &&
            musicVideoBindingsSatisfied(
              await db.listMusicVideos(track.trackUid),
            )) {
          continue;
        }
        for (final MusicVideoFileStamp video in musicVideoPairsToCheck(
          files,
          track: track,
          checks: checks,
        )) {
          if (!_enabled()) return;
          work.throwIfCancelled();
          if (await _alignPair(service, track, video, work)) {
            _boundThisRun++;
            notifyListeners();
            break;
          }
        }
      }
    }
  }

  /// 对一对（歌, 视频）。一对出错只影响这一对：记日志、不记「已对过」（下一轮再试），
  /// 本轮接着对后面的——不能让一个读不了的文件把整轮、以及之后每一轮都挡在同一处。
  /// 起止各记一条诊断（带耗时），卡住时能从诊断环看出卡在哪一对。
  Future<bool> _alignPair(
    MusicVideoService service,
    MusicTrackRow track,
    MusicVideoFileStamp video,
    DatabaseWorkToken work,
  ) async {
    final Stopwatch watch = Stopwatch()..start();
    ErrorLogService.instance.logDiagnostic(
      'MusicVideoAutoMatcher',
      'align start: ${track.path} <-> ${video.path}',
    );
    try {
      final bool bound = (await work.guard(
        service.alignLocal(track, video),
      )).bound;
      ErrorLogService.instance.logDiagnostic(
        'MusicVideoAutoMatcher',
        'align done in ${watch.elapsedMilliseconds} ms (bound=$bound): '
            '${track.path} <-> ${video.path}',
      );
      return bound;
    } on DatabaseWorkCancelledException {
      rethrow;
    } on Object catch (e, st) {
      ErrorLogService.instance.log(
        'MusicVideoAutoMatcher.align',
        'Failed after ${watch.elapsedMilliseconds} ms: '
            '${track.path} <-> ${video.path}: $e',
        st,
      );
      return false;
    }
  }
}

/// 一首歌这一轮还要对齐的候选（纯函数）：[musicVideoCandidatesFor] 的候选里去掉「这个
/// 视频版本已经对过」的。
List<MusicVideoFileStamp> musicVideoPairsToCheck(
  MusicVideoNearbyFiles files, {
  required MusicTrackRow track,
  required Map<(String, String), MusicVideoMatchCheckRow> checks,
}) => <MusicVideoFileStamp>[
  for (final ({MusicVideoFileStamp file, double score}) c
      in musicVideoCandidatesFor(
        files,
        title: track.title,
        artist: track.artistCredit,
      ))
    if (!_checked(checks[(track.trackUid, c.file.path)], c.file)) c.file,
];

bool _checked(MusicVideoMatchCheckRow? row, MusicVideoFileStamp file) =>
    row != null &&
    row.fileSizeBytes == file.size &&
    row.fileModifiedAt == file.mtimeMs;
