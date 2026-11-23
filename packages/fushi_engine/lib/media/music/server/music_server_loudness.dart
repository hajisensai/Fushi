/// 服务器曲目的响度（ReplayGain 2.0 口径）。
///
/// 本地曲库的响度来自标签或后台 `ebur128` 扫描，结果落 `music_tracks.rg_*`。服务器曲目
/// （Jellyfin / Subsonic）不进那张表：服务器自己已经测过 / 读过响度，直接用服务器给的——
/// - Jellyfin 10.9+：条目的 `NormalizationGain`（服务器按 EBU R128 测，目标 -18 LUFS，与
///   ReplayGain 2.0 参考响度同口径；曲目与专辑条目各有一份，媒体库开了「LUFS 扫描」才有）；
/// - OpenSubsonic：曲目的 `replayGain`（`trackGain` / `albumGain` dB、`trackPeak` / `albumPeak`
///   线性峰值，服务器读的是文件标签）。
///
/// 列表接口带回来的直接解析进 [MusicServerTrack.loudness]；从音乐库 / 歌单还原的服务器曲目
/// （v149 行里不存响度）起播时经可选能力 [MusicServerLoudnessLookup] 补查。不在客户端下载整首
/// 测量：服务器已经有结论，客户端测要把整首拉下来一遍、结果也没有表可落。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'package:fushi_engine/media/music/server/music_server.dart';

/// 一首服务器曲目的响度。增益为 dB（正 = 调大），峰值为线性满幅比例；缺的为 null。
class MusicServerLoudness {
  const MusicServerLoudness({
    this.trackGainDb,
    this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
  });

  final double? trackGainDb;
  final double? trackPeak;
  final double? albumGainDb;
  final double? albumPeak;

  /// 一项都没有（服务器没测 / 文件没标签）。
  bool get isEmpty =>
      trackGainDb == null &&
      trackPeak == null &&
      albumGainDb == null &&
      albumPeak == null;

  @override
  bool operator ==(Object other) =>
      other is MusicServerLoudness &&
      other.trackGainDb == trackGainDb &&
      other.trackPeak == trackPeak &&
      other.albumGainDb == albumGainDb &&
      other.albumPeak == albumPeak;

  @override
  int get hashCode =>
      Object.hash(trackGainDb, trackPeak, albumGainDb, albumPeak);

  @override
  String toString() =>
      'MusicServerLoudness(track: $trackGainDb dB / $trackPeak, '
      'album: $albumGainDb dB / $albumPeak)';
}

/// 可选能力：按曲目向服务器补查响度（与 [MusicServerPlaylistEditing] 同模式，浏览器实现了
/// 才有；Apple Music / YouTube 不实现）。没有响度回 null；网络 / 服务器错误照常抛。
abstract interface class MusicServerLoudnessLookup {
  Future<MusicServerLoudness?> loudnessOf(MusicServerTrackRef track);
}

double? _double(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final double? d = double.tryParse(v.trim());
    return d != null && d.isFinite ? d : null;
  }
  return null;
}

/// Jellyfin 条目的 `NormalizationGain`（dB）；没有为 null。
double? jellyfinNormalizationGainOf(Map<String, Object?> item) =>
    _double(item['NormalizationGain']);

/// Jellyfin 曲目条目 → 响度（只有曲目增益：专辑增益在专辑条目上）；没有为 null。
MusicServerLoudness? jellyfinTrackLoudnessOf(Map<String, Object?> item) {
  final double? gain = jellyfinNormalizationGainOf(item);
  return gain == null ? null : MusicServerLoudness(trackGainDb: gain);
}

/// Jellyfin `Items?Ids=<曲目>,<专辑>` 的结果 → 响度（曲目增益取曲目条目、专辑增益取专辑
/// 条目）；两样都没有为 null。
MusicServerLoudness? jellyfinLoudnessOfItems(
  List<Map<String, Object?>> items, {
  required String trackId,
  String? albumId,
}) {
  double? track;
  double? album;
  for (final Map<String, Object?> i in items) {
    final Object? id = i['Id'];
    if (id == trackId) track = jellyfinNormalizationGainOf(i);
    if (albumId != null && id == albumId) {
      album = jellyfinNormalizationGainOf(i);
    }
  }
  final MusicServerLoudness l = MusicServerLoudness(
    trackGainDb: track,
    albumGainDb: album,
  );
  return l.isEmpty ? null : l;
}

/// OpenSubsonic 曲目的 `replayGain` 对象 → 响度；没有 / 全空为 null。增益为 0 且没有峰值的
/// 一项按「没有」处理：有的服务器对没标签的文件填 0 占位。
MusicServerLoudness? parseOpenSubsonicReplayGain(Object? replayGain) {
  if (replayGain is! Map<String, Object?>) return null;
  double? gain(String key, String peakKey) {
    final double? g = _double(replayGain[key]);
    if (g == null) return null;
    if (g == 0 && _double(replayGain[peakKey]) == null) return null;
    return g;
  }

  double? peak(String key) {
    final double? p = _double(replayGain[key]);
    return p == null || p <= 0 ? null : p;
  }

  final MusicServerLoudness l = MusicServerLoudness(
    trackGainDb: gain('trackGain', 'trackPeak'),
    trackPeak: peak('trackPeak'),
    albumGainDb: gain('albumGain', 'albumPeak'),
    albumPeak: peak('albumPeak'),
  );
  return l.isEmpty ? null : l;
}
