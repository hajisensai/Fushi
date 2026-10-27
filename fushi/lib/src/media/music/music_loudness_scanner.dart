/// 缺 ReplayGain 标签的曲目在后台用统一 FFmpeg 的 `ebur128` 测响度（设计 §7.3），结果只写
/// 曲库 DB（`music_tracks.rg_*` + `r128_scanned_at`），**不改用户文件**。
///
/// 计算在 FFmpeg 里（`ebur128=peak=true`，BS.1770 门限积分响度 + 真峰值），这里只做进程编排
/// 与落库：走 app 统一的 FFmpeg 后端装配（[resolveFfmpegBackend]），不另起一份 FFmpeg。
///
/// 换算（ReplayGain 2.0 参考响度 -18 LUFS）：曲目增益 = -18 - I；峰值 = 10^(TP/20)。专辑
/// 增益在整张专辑的曲目增益都齐了之后按时长加权的能量平均算：
/// `L_album = 10·log10(Σ dᵢ·10^(Lᵢ/10) / Σ dᵢ)`——这是对整碟拼起来再测一次的近似（门限
/// 按整碟算时略有差别），专辑峰值取各曲目峰值的最大值。
library;

import 'dart:async';
import 'dart:io' show ProcessException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

import 'package:fushi/src/media/music/disc/music_audio_cd.dart';

/// ReplayGain 2.0 参考响度（LUFS）。
const double kReplayGain2ReferenceLufs = -18;

/// `ebur128` 对整段静音报的门限下限：测不出响度。
const double _kSilenceLufs = -70;

/// 一次 `ebur128` 的摘要。
@immutable
class MusicLoudnessMeasurement {
  const MusicLoudnessMeasurement({
    required this.integratedLufs,
    required this.truePeakDbtp,
  });

  final double integratedLufs;

  /// 真峰值（dBTP）；`-inf`（全静音）为 null。
  final double? truePeakDbtp;

  /// 曲目增益（dB）；静音 / 测不出为 null。
  double? get replayGainDb => integratedLufs <= _kSilenceLufs
      ? null
      : kReplayGain2ReferenceLufs - integratedLufs;

  /// 线性峰值。
  double? get linearPeak =>
      truePeakDbtp == null ? null : math.pow(10, truePeakDbtp! / 20).toDouble();
}

/// 纯函数：FFmpeg `ebur128` 输出里的 Summary 段 → 测量值；没有 Summary 为 null。
MusicLoudnessMeasurement? parseEbur128Summary(String output) {
  final int summary = output.lastIndexOf('Summary:');
  if (summary < 0) return null;
  final String tail = output.substring(summary);
  final RegExpMatch? i = RegExp(
    r'I:\s+(-?[0-9]+(?:\.[0-9]+)?) LUFS',
  ).firstMatch(tail);
  if (i == null) return null;
  final RegExpMatch? peak = RegExp(
    r'Peak:\s+(-?inf|-?[0-9]+(?:\.[0-9]+)?) dBFS',
  ).firstMatch(tail);
  final String? peakText = peak?.group(1);
  return MusicLoudnessMeasurement(
    integratedLufs: double.parse(i.group(1)!),
    truePeakDbtp: peakText == null || peakText.endsWith('inf')
        ? null
        : double.parse(peakText),
  );
}

/// 纯函数：专辑增益（按时长加权的能量平均，见文件头）。任一曲目缺增益返回 null。
({double gain, double? peak})? musicAlbumLoudnessOf(
  List<({double? trackGain, double? trackPeak, int? durationMs})> tracks,
) {
  if (tracks.isEmpty) return null;
  double energy = 0;
  double weight = 0;
  double? peak;
  for (final ({double? trackGain, double? trackPeak, int? durationMs}) t
      in tracks) {
    final double? gain = t.trackGain;
    if (gain == null) return null;
    final double lufs = kReplayGain2ReferenceLufs - gain;
    final double d = math.max(1, t.durationMs ?? 1).toDouble();
    energy += d * math.pow(10, lufs / 10);
    weight += d;
    final double? p = t.trackPeak;
    if (p != null) peak = peak == null ? p : math.max(peak, p);
  }
  final double albumLufs = 10 * math.log(energy / weight) / math.ln10;
  return (gain: kReplayGain2ReferenceLufs - albumLufs, peak: peak);
}

/// FFmpeg 参数：测一首曲目（CUE 虚拟曲目带起止）。
List<String> musicEbur128Args(MusicTrackRow track) => <String>[
  '-hide_banner',
  '-nostats',
  if (track.cueStartMs != null && track.cueStartMs! > 0) ...<String>[
    '-ss',
    (track.cueStartMs! / 1000).toStringAsFixed(3),
  ],
  if (track.cueEndMs != null) ...<String>[
    '-t',
    ((track.cueEndMs! - (track.cueStartMs ?? 0)) / 1000).toStringAsFixed(3),
  ],
  '-i',
  track.path,
  '-map',
  '0:a:0',
  '-filter:a',
  'ebur128=peak=true',
  '-f',
  'null',
  '-',
];

/// 后台响度扫描：同一时刻只跑一个循环（一首一个 FFmpeg 进程，串行）；扫描期间再来的
/// 请求合并成「跑完再看一遍」。
class MusicLoudnessScanner extends ChangeNotifier {
  MusicLoudnessScanner({
    required FushiDatabase? Function() database,
    required bool Function() enabled,
    FfmpegBackend Function()? ffmpeg,
    Duration perTrackTimeout = const Duration(minutes: 5),
  }) : _database = database,
       _enabled = enabled,
       _ffmpeg = ffmpeg ?? resolveFfmpegBackend,
       _perTrackTimeout = perTrackTimeout;

  final FushiDatabase? Function() _database;
  final bool Function() _enabled;
  final FfmpegBackend Function() _ffmpeg;
  final Duration _perTrackTimeout;

  bool _running = false;
  bool _again = false;
  int _scannedThisRun = 0;
  String? _lastError;

  bool get isRunning => _running;

  /// 本轮已测完的曲目数（进度显示用）。
  int get scannedThisRun => _scannedThisRun;
  String? get lastError => _lastError;

  /// 请求一轮扫描（曲库扫描完 / 设置页「立即测量」）。[force] 忽略「自动测量」开关。
  Future<void> schedule({bool force = false}) async {
    if (!force && !_enabled()) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _scannedThisRun = 0;
    notifyListeners();
    try {
      do {
        _again = false;
        await _runOnce();
      } while (_again);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _runOnce() async {
    final Set<String> albums = <String>{};
    while (true) {
      final FushiDatabase? db = _database();
      if (db == null) return;
      final List<MusicTrackRow> batch = await db
          .listMusicTracksNeedingLoudnessScan(limit: 50);
      if (batch.isEmpty) break;
      for (final MusicTrackRow track in batch) {
        final MusicLoudnessMeasurement? m;
        try {
          m = await _measure(track);
        } on ProcessException catch (e) {
          // FFmpeg 本身起不来（没装 / 捆绑件缺失或损坏）：FFmpeg 后端契约是把
          // ProcessException 抛给调用方处置。这不是这一首的问题——不能把曲目记成
          // 「已扫描」（装好 FFmpeg 后就再也不会测），也不能让异常逃出 schedule()
          // （三个调用点都是 unawaited，逃出去就是未处理的异步错误、设置页也看不到原因）。
          // 记下原因、整轮停下，曲目保持待测。
          _lastError = describeFfmpegProcessException(e);
          debugPrint('[music-loudness] $_lastError');
          notifyListeners();
          return;
        }
        await db.writeMusicTrackLoudness(
          track.trackUid,
          gain: m?.replayGainDb,
          peak: m?.replayGainDb == null ? null : m?.linearPeak,
          scannedAt: DateTime.now().millisecondsSinceEpoch,
        );
        if (track.albumUid != null) albums.add(track.albumUid!);
        _scannedThisRun++;
        notifyListeners();
      }
    }
    final FushiDatabase? db = _database();
    if (db == null) return;
    for (final String albumUid in albums) {
      final List<MusicTrackRow> tracks = await db.listMusicTracks(
        albumUid: albumUid,
      );
      if (tracks.every((MusicTrackRow t) => t.rgAlbumGain != null)) continue;
      final ({double gain, double? peak})? album = musicAlbumLoudnessOf(
        <({double? trackGain, double? trackPeak, int? durationMs})>[
          for (final MusicTrackRow t in tracks)
            (
              trackGain: t.rgTrackGain,
              trackPeak: t.rgTrackPeak,
              durationMs: t.durationMs,
            ),
        ],
      );
      if (album == null) continue;
      await db.writeMusicAlbumLoudness(
        albumUid,
        gain: album.gain,
        peak: album.peak,
      );
    }
  }

  Future<MusicLoudnessMeasurement?> _measure(MusicTrackRow track) async {
    // 音频 CD 曲目：FFmpeg 没有 cdda 协议，光驱里的盘也随时会换——不测，按 0 dB 播
    // （记成已扫描、增益为空，信号路径面板照实显示没有 ReplayGain）。
    if (isMusicCddaPath(track.path)) return null;
    final FfmpegRunResult r = await _ffmpeg().run(
      musicEbur128Args(track),
      _perTrackTimeout,
    );
    final MusicLoudnessMeasurement? m = r.isSuccess
        ? parseEbur128Summary(r.output)
        : null;
    if (m == null) {
      _lastError = '${track.path}: ${r.failureSummary}';
      debugPrint('[music-loudness] $_lastError');
    }
    return m;
  }
}
