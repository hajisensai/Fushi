/// 音乐播放的输出层抽象（设计 §4.2.1）：v1 只有 libmpv 实现
/// （[MpvMusicOutputBackend]），留给将来的「HiFi 直出后端」（ASIO / WASAPI 独占 /
/// Android USB / DoP）。队列与无缝编排在 [MusicPlayerEngine]，后端只认「当前 + 下一首」。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 一首要播的曲目（CUE 虚拟曲目带起止）。
@immutable
class MusicPlayItem {
  const MusicPlayItem({
    required this.trackUid,
    required this.path,
    required this.title,
    this.startMs,
    this.endMs,
    this.artist,
    this.album,
    this.albumUid,
    this.durationMs,
    this.coverPath,
  });

  final String trackUid;
  final String path;
  final String title;

  /// CUE 虚拟曲目在整轨文件里的起止（毫秒）；普通文件为 null。
  final int? startMs;
  final int? endMs;
  final String? artist;
  final String? album;
  final String? albumUid;
  final int? durationMs;
  final String? coverPath;

  @override
  bool operator ==(Object other) =>
      other is MusicPlayItem && other.trackUid == trackUid;

  @override
  int get hashCode => trackUid.hashCode;
}

/// ReplayGain 模式（设计 §7.2：专辑模式 album、随机播放 track）。
enum MusicReplayGainMode {
  off('no'),
  track('track'),
  album('album');

  const MusicReplayGainMode(this.mpvValue);

  /// mpv `replaygain` 属性值。
  final String mpvValue;
}

/// 输出层设置。
@immutable
class MusicOutputSettings {
  const MusicOutputSettings({
    required this.gapless,
    required this.replayGain,
    this.replayGainPreampDb = 0,
  });

  /// mpv `gapless-audio=weak`（同格式真无缝，格式变化时重开设备）。
  final bool gapless;
  final MusicReplayGainMode replayGain;
  final double replayGainPreampDb;

  @override
  bool operator ==(Object other) =>
      other is MusicOutputSettings &&
      other.gapless == gapless &&
      other.replayGain == replayGain &&
      other.replayGainPreampDb == replayGainPreampDb;

  @override
  int get hashCode => Object.hash(gapless, replayGain, replayGainPreampDb);
}

/// 后端上报的事件。
sealed class MusicBackendEvent {
  const MusicBackendEvent();
}

/// 播放位置（相对**当前曲目**起点，CUE 虚拟曲目已减去起点）。
final class MusicBackendPosition extends MusicBackendEvent {
  const MusicBackendPosition(this.position, this.duration);

  final Duration position;
  final Duration? duration;
}

final class MusicBackendPlaying extends MusicBackendEvent {
  const MusicBackendPlaying(this.playing);

  final bool playing;
}

/// 后端已无缝切到预先排好的「下一首」。
final class MusicBackendAdvanced extends MusicBackendEvent {
  const MusicBackendAdvanced();
}

/// 当前曲目播完且后面没有排好的下一首。
final class MusicBackendCompleted extends MusicBackendEvent {
  const MusicBackendCompleted();
}

final class MusicBackendFailed extends MusicBackendEvent {
  const MusicBackendFailed(this.message);

  final String message;
}

/// 输出后端。实现必须保证：[openPair] 后后端只持有 [current] 与（可选）[next] 两项；
/// 自然播完 [current] 时若有 next 则无缝切过去并发 [MusicBackendAdvanced]，否则发
/// [MusicBackendCompleted]。
abstract interface class MusicOutputBackend {
  Stream<MusicBackendEvent> get events;

  Future<void> applySettings(MusicOutputSettings settings);

  /// 换掉整个播放列表：从 [current] 开始，预排 [next]。
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
  });

  /// 只换「下一首」（当前曲目不中断）。
  Future<void> replaceNext(MusicPlayItem? next);

  Future<void> play();
  Future<void> pause();

  /// 跳到当前曲目内的 [position]（相对曲目起点）。
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}
