/// 服务器没给响度的服务器曲目（Jellyfin 没开 LUFS 扫描、纯 Subsonic）在客户端测响度。
///
/// 与本地曲库同一条测量路径（统一 FFmpeg 后端的 `ebur128`，[measureMusicLoudness] /
/// [musicEbur128ArgsFor]），换算成 ReplayGain 2.0 曲目增益 / 峰值；播放时由起播期的响度补查
/// （`music_server_loudness_resolver.dart`）在服务器没有值时取用，与服务器值同一条施加路径
/// （mpv `volume-gain`，信号路径面板的 `rg_*`）。**服务器给的值永远优先**：服务器报了曲目增益
/// 的不测，测过之后服务器又有了值（开了 LUFS 扫描）也以服务器为准。
///
/// - **只测播过的**：挂在 `MusicSession` 的「一首被换下」上（[trackLeft]），听够
///   [kMusicServerMeasureMinListen]（或一半 / 播完）才排一次；从不预取、从不扫整个服务器曲库。
/// - **离线副本**：测本机文件，存进音频旁 `.loudness.json` 的 `measured`
///   （下完时 `music_server_downloads.dart` 已测过的不再测；存量副本在第一次播过之后补测）。
/// - **串流曲目**：先确认服务器答复了、而且没有曲目增益，再从服务器流测一次（后台、串行、每首
///   至多 [kMusicServerMeasureTimeout]），存进 v176 `music_server_track_states`（设备本地）。
///   流地址带凭据：只交给 FFmpeg，不进日志 / 错误文本 / 表——失败只记 FFmpeg 返回码。
/// - 每首每个进程至多尝试一次（失败不连环重试，下次启动后播到再试）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';

import 'package:fushi/src/media/music/music_loudness_scanner.dart'
    show MusicLoudnessOutcome, measureMusicLoudness;
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart'
    show MusicTrackLeave;
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_loudness_resolver.dart'
    show MusicServerLoudnessAnswer;
import 'package:fushi/src/media/music/server/music_server_offline_queue.dart'
    show musicServerKindQueueable;
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show
        MusicServerLocalCopy,
        MusicServerLocalCopyLookup,
        musicServerLocalCopyLookup;

/// 听了多久才算「播过」、值得测（或听过一半 / 播完）。
const Duration kMusicServerMeasureMinListen = Duration(seconds: 30);

/// 一首的测量上限（串流读整首要时间）。
const Duration kMusicServerMeasureTimeout = Duration(minutes: 5);

/// 只问服务器的响度（app 装配：`BindingMusicServerLoudnessResolver.serverLoudness`）。
typedef MusicServerLoudnessServerLookup =
    Future<MusicServerLoudnessAnswer> Function(MusicServerTrackRef ref);

/// 测一个输入的响度（测试注入；生产 = [measureMusicLoudness]）。
typedef MusicServerLoudnessMeasure =
    Future<MusicLoudnessOutcome> Function(String input);

/// 客户端测量值的读取（播放时的后备）：离线副本取 sidecar，串流曲目取 v176 表。app 装配给
/// `BindingMusicServerLoudnessResolver(measured: …)`。
Future<MusicServerLoudness?> musicServerMeasuredLoudness(
  MusicServerTrackRef ref, {
  required FushiDatabase? db,
  MusicServerLocalCopyLookup? localCopies,
}) async {
  final MusicServerLocalCopy? local =
      (localCopies ?? musicServerLocalCopyLookup)?.call(ref.trackUid);
  final MusicServerLoudness? fromSidecar = local?.measuredLoudness;
  if (fromSidecar?.trackGainDb != null) return fromSidecar;
  final MusicServerTrackStateRow? row = await db?.getMusicServerTrackState(
    ref.trackUid,
  );
  final double? gain = row?.measuredTrackGain;
  if (gain == null) return null;
  return MusicServerLoudness(
    trackGainDb: gain,
    trackPeak: row?.measuredTrackPeak,
  );
}

class MusicServerLoudnessMeasurer {
  MusicServerLoudnessMeasurer({
    required FushiDatabase? Function() database,
    required MusicServerLoudnessServerLookup serverLoudness,
    required bool Function() enabled,
    MusicServerLoudnessMeasure? measure,
    MusicServerLocalCopyLookup? localCopies,
    MusicServerDownloadIndex? index,
    int Function()? clock,
  }) : _database = database,
       _serverLoudness = serverLoudness,
       _enabled = enabled,
       _measure =
           measure ??
           ((String input) => measureMusicLoudness(
             input,
             timeout: kMusicServerMeasureTimeout,
           )),
       _localCopies = localCopies,
       _index = index,
       _clock = clock ?? _now;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  final FushiDatabase? Function() _database;
  final MusicServerLoudnessServerLookup _serverLoudness;
  final bool Function() _enabled;
  final MusicServerLoudnessMeasure _measure;
  final MusicServerLocalCopyLookup? _localCopies;
  final MusicServerDownloadIndex? _index;
  final int Function() _clock;

  /// 本进程试过的曲目（成败都算）：不连环重试。
  final Set<String> _tried = <String>{};

  /// 串行：同一时刻只跑一个 FFmpeg。
  Future<void> _queue = Future<void>.value();

  /// 测试用：等已排的测量做完。
  Future<void> get idle => _queue;

  /// 一首被换下（`MusicSession` 的曲目生命周期）：播过的服务器曲目排一次测量。
  void trackLeft(MusicTrackLeave leave) {
    final Duration? d = leave.duration;
    final bool played =
        leave.completed ||
        leave.position >= kMusicServerMeasureMinListen ||
        (d != null && d > Duration.zero && leave.position * 2 >= d);
    if (played) trackPlayed(leave.item);
  }

  /// [item] 播过了：值得测就排进后台队列。
  void trackPlayed(MusicPlayItem item) {
    final MusicServerTrackRef? ref = item.serverTrack;
    if (ref == null || item.isPreview || !musicServerKindQueueable(ref.kind)) {
      return;
    }
    // 播放项自带曲目增益 = 服务器给的（列表 / 下载时存下的服务器值）：不测。
    if (item.rgTrackGain != null) return;
    if (!_enabled() || !_tried.add(item.trackUid)) return;
    _queue = _queue.then((_) => _run(item, ref)).catchError((Object e) {
      debugPrint('[music-loudness] measure failed: ${e.runtimeType}');
    });
  }

  Future<void> _run(MusicPlayItem item, MusicServerTrackRef ref) async {
    final MusicServerLocalCopy? local =
        (_localCopies ?? musicServerLocalCopyLookup)?.call(ref.trackUid);
    if (local != null) {
      await _measureLocalCopy(local);
      return;
    }
    final String path = item.path;
    if (!path.startsWith('http://') && !path.startsWith('https://')) return;
    final FushiDatabase? db = _database();
    if (db == null) return;
    if ((await db.getMusicServerTrackState(ref.trackUid))?.loudnessMeasuredAt !=
        null) {
      return;
    }
    final MusicServerLoudnessAnswer answer = await _serverLoudness(ref);
    // 服务器没答复（连不上 / 配置删了）：不知道服务器有没有值，不测（下次进程再试）。
    if (!answer.reached || answer.loudness?.trackGainDb != null) return;
    final MusicLoudnessOutcome m = await _measure(path);
    if (m.failed) {
      debugPrint(
        '[music-loudness] stream measurement failed '
        '(ffmpeg returnCode=${m.returnCode})',
      );
      return;
    }
    final double? gain = m.measurement?.replayGainDb;
    await db.writeMusicServerTrackMeasuredLoudness(
      trackUid: ref.trackUid,
      serverKind: ref.kind.wire,
      serverId: ref.serverId,
      itemId: ref.trackId,
      gain: gain,
      peak: gain == null ? null : m.measurement?.linearPeak,
      at: _clock(),
    );
    debugPrint('[music-loudness] measured server stream: gain=$gain dB');
  }

  Future<void> _measureLocalCopy(MusicServerLocalCopy local) async {
    if (local.loudness?.trackGainDb != null) return;
    if (await musicServerDownloadLoudnessMeasured(local.path)) return;
    final MusicLoudnessOutcome m = await _measure(local.path);
    if (m.failed) {
      debugPrint(
        '[music-loudness] local copy measurement failed '
        '(ffmpeg returnCode=${m.returnCode})',
      );
      return;
    }
    final double? gain = m.measurement?.replayGainDb;
    await writeMusicServerDownloadMeasuredLoudness(
      local.path,
      trackGainDb: gain,
      trackPeak: gain == null ? null : m.measurement?.linearPeak,
      measuredAt: _clock(),
    );
    await (_index ?? MusicServerDownloadIndex.instance).refreshLoudness(
      local.path,
    );
    debugPrint('[music-loudness] measured local copy: gain=$gain dB');
  }
}
