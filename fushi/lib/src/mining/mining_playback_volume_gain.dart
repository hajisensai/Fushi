/// 制卡句子音频跟随播放音量（反馈 d7mXlstcv9 / issue #3405，维护者拍板：跟随当前媒体的
/// 播放响度与音量调节，默认开）。
///
/// 句子片段以前一律按源文件原始电平裁，流行歌母带常在 -8～-10 LUFS，用户在播放器里把音量
/// 调小了、卡里还是原始的 100%。开关开着时，片段整体加上「播放时这一刻实际施加的增益」：
///
/// * 音乐：与播放同一份 ReplayGain（[musicReplayGainDb]，同模式 / preamp / 峰值限幅；
///   ReplayGain 关或曲目没有增益数据时 0 dB，与播放端一致）+ 音量滑块。
/// * 有声书：音量滑块。
///
/// 音量滑块换算成 dB 时按各自播放后端的真实音量曲线：libmpv 的 `volume` 是**立方**曲线
/// （mpv `player/audio.c`：`gain = pow(volume / 100, 3)`，音乐与 Windows / Linux 上的
/// 有声书都走它）；just_audio 的原生后端（Android ExoPlayer、Apple AVPlayer）是线性振幅。
///
/// 音量为 0（静音）时不跟滑块：截出一段无声的卡没有意义，这时只施加响度那部分增益。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 播放后端的音量曲线：滑块值 → 实际振幅倍数的换算方式。
enum PlaybackVolumeCurve {
  /// libmpv `volume`（0～100～`volume-max`，100 = 不改样本）：振幅 = (v/100)³。
  mpvCubic,

  /// 线性振幅（just_audio 原生后端 0～1～2，1 = 不改样本）：振幅 = v。
  linear,
}

/// 纯函数：播放音量滑块值折成 dB。[volume] 用后端自己的刻度（mpv 0～100+、线性 0～2）。
/// 0 / 负数 / 非有限值返回 0（静音不烤进卡，见文件头）。
double playbackVolumeGainDb(double volume, PlaybackVolumeCurve curve) {
  if (!volume.isFinite || volume <= 0) return 0;
  return switch (curve) {
    PlaybackVolumeCurve.mpvCubic => 60 * math.log(volume / 100) / math.ln10,
    PlaybackVolumeCurve.linear => 20 * math.log(volume) / math.ln10,
  };
}

/// 纯函数：歌曲制卡片段的增益（dB）= 播放时这首歌的 ReplayGain + 音量滑块（mpv 立方
/// 曲线）。[followPlayback] 关 → null（原始电平，ffmpeg 参数与现状逐字节相同）。
double? musicMiningClipGainDb({
  required bool followPlayback,
  required MusicPlayItem item,
  required MusicOutputSettings settings,
}) {
  if (!followPlayback) return null;
  final double replayGainDb = settings.replayGain == MusicReplayGainMode.off
      ? 0
      : musicReplayGainDb(
          albumMode: settings.replayGain == MusicReplayGainMode.album,
          trackGain: item.rgTrackGain,
          trackPeak: item.rgTrackPeak,
          albumGain: item.rgAlbumGain,
          albumPeak: item.rgAlbumPeak,
          preampDb: settings.replayGainPreampDb,
        );
  return replayGainDb +
      playbackVolumeGainDb(settings.volume, PlaybackVolumeCurve.mpvCubic);
}

/// 有声书播放器（just_audio）在本平台的音量曲线：Windows / Linux 由
/// `JustAudioMediaKit.ensureInitialized()`（缺省只接管这两端）交给 libmpv，其余平台走
/// just_audio 原生后端。
PlaybackVolumeCurve get audiobookPlaybackVolumeCurve =>
    Platform.isWindows || Platform.isLinux
    ? PlaybackVolumeCurve.mpvCubic
    : PlaybackVolumeCurve.linear;

/// 纯函数：有声书制卡片段的增益（dB）。[volume] 是 just_audio 的 0～2 刻度；mpv 后端
/// 收到的是 `volume × 100`（just_audio_media_kit 的换算），这里同样换算后再套立方曲线。
/// [followPlayback] 关或没有播放器 → null。
double? audiobookMiningClipGainDb({
  required bool followPlayback,
  required double? volume,
  required PlaybackVolumeCurve curve,
}) {
  if (!followPlayback || volume == null) return null;
  return switch (curve) {
    PlaybackVolumeCurve.mpvCubic => playbackVolumeGainDb(volume * 100, curve),
    PlaybackVolumeCurve.linear => playbackVolumeGainDb(volume, curve),
  };
}
