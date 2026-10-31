/// 音乐播放的输出层抽象（设计 §4.2.1）：v1 只有 libmpv 实现
/// （[MpvMusicOutputBackend]），留给将来的「HiFi 直出后端」（ASIO / WASAPI 独占 /
/// Android USB / DoP）。队列与无缝编排在 [MusicPlayerEngine]，后端只认「当前 + 下一首」。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_equalizer.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

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
    this.discNo,
    this.trackNo,
    this.durationMs,
    this.coverPath,
    this.codec,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.rgTrackGain,
    this.rgTrackPeak,
    this.rgAlbumGain,
    this.rgAlbumPeak,
    this.artistRefs = const <MusicPlayArtistRef>[],
    this.sourceAlbumId,
  });

  final String trackUid;
  final String path;
  final String title;

  /// 来源侧的歌手引用（插件曲目带插件里的歌手 id），歌词页点歌手跳详情用；
  /// 本地曲目为空（按曲库的歌手表匹配名字）。
  final List<MusicPlayArtistRef> artistRefs;

  /// 来源侧的专辑 id（插件曲目）；本地曲目用 [albumUid]。
  final String? sourceAlbumId;

  /// CUE 虚拟曲目在整轨文件里的起止（毫秒）；普通文件为 null。
  final int? startMs;
  final int? endMs;
  final String? artist;
  final String? album;
  final String? albumUid;

  /// 碟号 / 轨号（判「专辑连续曲目」用，见 `musicTransitionIsBoundary`）。
  final int? discNo;
  final int? trackNo;
  final int? durationMs;
  final String? coverPath;

  /// 曲库扫描从文件头读到的源属性（`dsd` / `flac` …；位深 mpv 不报，信号路径用这里的）。
  final String? codec;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;

  /// ReplayGain（dB / 线性峰值）：标签（REPLAYGAIN_* / R128_* / iTunNORM）或 EBU R128 扫描。
  final double? rgTrackGain;
  final double? rgTrackPeak;
  final double? rgAlbumGain;
  final double? rgAlbumPeak;

  bool get isDsd => codec == 'dsd';

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

/// DSD → PCM 的目标采样率（设计 §7.1）：mpv 不支持 DoP / 原生 DSD 输出，只能先转 PCM。
enum MusicDsdPcmRate {
  khz176(176400),
  khz352(352800);

  const MusicDsdPcmRate(this.hz);

  final int hz;
}

/// 输出层设置。
@immutable
class MusicOutputSettings {
  const MusicOutputSettings({
    required this.gapless,
    required this.replayGain,
    this.replayGainPreampDb = 0,
    this.exclusive = false,
    this.audioDevice = 'auto',
    this.speed = 1,
    this.volume = 100,
    this.dsdPcmRate = MusicDsdPcmRate.khz176,
    this.crossfade = Duration.zero,
    this.crossfadeContinuous = false,
    this.equalizer = const MusicEqualizerSettings(),
  });

  /// mpv `gapless-audio=weak`（同格式真无缝，格式变化时重开设备）。
  final bool gapless;
  final MusicReplayGainMode replayGain;
  final double replayGainPreampDb;

  /// 独占 / bit-perfect 输出（设计 §7.4）：Windows WASAPI 独占、macOS hog mode、
  /// Android 14+ USB bit-perfect 混音属性。独占时不设 `audio-samplerate`、不强制
  /// `audio-format`，设备跟随源格式。
  final bool exclusive;

  /// mpv `audio-device`（`auto` = 系统默认）。
  final String audioDevice;

  /// 播放速度（≠1 时 mpv 自动插 scaletempo2，变速不变调）。
  final double speed;

  /// 软件音量（100 = 不改样本）。
  final double volume;
  final MusicDsdPcmRate dsdPcmRate;

  /// 交叉淡入时长；[Duration.zero] = 关（默认）。开了即非 bit-perfect。
  final Duration crossfade;

  /// 专辑连续曲目 / CUE 拆轨这类本来就该无缝的衔接也交叉淡入（默认否：真无缝优先）。
  final bool crossfadeContinuous;

  /// 图示均衡器（P5，可选）：作用于信号时即非 bit-perfect；关 / 平直时不挂滤镜。
  final MusicEqualizerSettings equalizer;

  MusicOutputSettings copyWith({
    bool? gapless,
    MusicReplayGainMode? replayGain,
    double? replayGainPreampDb,
    bool? exclusive,
    String? audioDevice,
    double? speed,
    double? volume,
    MusicDsdPcmRate? dsdPcmRate,
    Duration? crossfade,
    bool? crossfadeContinuous,
    MusicEqualizerSettings? equalizer,
  }) => MusicOutputSettings(
    gapless: gapless ?? this.gapless,
    replayGain: replayGain ?? this.replayGain,
    replayGainPreampDb: replayGainPreampDb ?? this.replayGainPreampDb,
    exclusive: exclusive ?? this.exclusive,
    audioDevice: audioDevice ?? this.audioDevice,
    speed: speed ?? this.speed,
    volume: volume ?? this.volume,
    dsdPcmRate: dsdPcmRate ?? this.dsdPcmRate,
    crossfade: crossfade ?? this.crossfade,
    crossfadeContinuous: crossfadeContinuous ?? this.crossfadeContinuous,
    equalizer: equalizer ?? this.equalizer,
  );

  @override
  bool operator ==(Object other) =>
      other is MusicOutputSettings &&
      other.gapless == gapless &&
      other.replayGain == replayGain &&
      other.replayGainPreampDb == replayGainPreampDb &&
      other.exclusive == exclusive &&
      other.audioDevice == audioDevice &&
      other.speed == speed &&
      other.volume == volume &&
      other.dsdPcmRate == dsdPcmRate &&
      other.crossfade == crossfade &&
      other.crossfadeContinuous == crossfadeContinuous &&
      other.equalizer == equalizer;

  @override
  int get hashCode => Object.hash(
    gapless,
    replayGain,
    replayGainPreampDb,
    exclusive,
    audioDevice,
    speed,
    volume,
    dsdPcmRate,
    crossfade,
    crossfadeContinuous,
    equalizer,
  );
}

/// 一个后端对某首曲目能做什么。mpv 链路全能；系统 / SDK 托管播放的后端（如 MusicKit，
/// 解密与出声在 Apple 授权的播放器里）拿不到音频信号，信号路径、A-B 循环等只能关掉。
/// 由 [MusicPlayerEngine.capabilities] 按**当前曲目所属后端**给出，界面据此隐藏入口。
@immutable
class MusicBackendCapabilities {
  const MusicBackendCapabilities({
    required this.signalPath,
    required this.abLoop,
  });

  /// libmpv 链路：一切照旧。
  static const MusicBackendCapabilities full = MusicBackendCapabilities(
    signalPath: true,
    abLoop: true,
  );

  /// 能读信号路径（源格式 / 解码 / 滤镜 / 输出设备 / bit-perfect 判定）。
  final bool signalPath;

  /// 能在音频时间轴上做 A-B 循环（[MusicOutputBackend.setAbLoop]）。
  final bool abLoop;

  @override
  bool operator ==(Object other) =>
      other is MusicBackendCapabilities &&
      other.signalPath == signalPath &&
      other.abLoop == abLoop;

  @override
  int get hashCode => Object.hash(signalPath, abLoop);
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

/// 后端已无缝切到预先排好的「下一首」——以**实际出声**为准（设备缓冲里前一首的尾巴
/// 放完那一刻），不是解码器开始读下一首的时刻。
final class MusicBackendAdvanced extends MusicBackendEvent {
  const MusicBackendAdvanced([this.trackUid]);

  /// 现在出声的曲目；null = 后端不知道（引擎按队列顺序推进一首）。
  final String? trackUid;
}

/// 当前曲目播完且后面没有排好的下一首。
final class MusicBackendCompleted extends MusicBackendEvent {
  const MusicBackendCompleted();
}

/// 输出降级的原因。
enum MusicOutputFallbackReason {
  /// 独占打不开（设备被别的程序独占、驱动不支持独占等），已退回共享模式。
  exclusiveUnavailable,

  /// 选的输出设备打不开（拔掉了 / 不存在），已退回系统默认设备。
  deviceUnavailable,
}

/// 输出层没能按设置打开、已经自动退回（独占 → 共享 / 指定设备 → 默认）。界面必须明确
/// 提示，不能静默。
final class MusicBackendOutputFallback extends MusicBackendEvent {
  const MusicBackendOutputFallback(this.reason, this.detail);

  final MusicOutputFallbackReason reason;

  /// mpv 的原始报错。
  final String detail;
}

/// 播放失败里界面要单独说清楚的几种（其余只有 mpv 原文）。
enum MusicPlaybackFailure {
  /// 音频 CD 曲目：光驱里没有能读的盘（没盘 / 托盘开着 / 中途拔出）。
  cdNoDisc,

  /// 音频 CD 曲目：光驱里换成了另一张盘（Disc ID 对不上）。
  cdOtherDisc,

  /// 这一首拿不到可播放的流（在线插件曲目：会员 / 无版权 / 只给试听 / 插件已停用或卸载 /
  /// 取流超时 / 流地址打不开）。只影响这一首：引擎自动跳到下一首（连续多首都这样才停）。
  trackUnavailable,
}

final class MusicBackendFailed extends MusicBackendEvent {
  const MusicBackendFailed(
    this.message, {
    this.reason,
    this.device,
    this.trackUid,
  });

  final String message;

  /// 已知原因；null = 只有 [message]。
  final MusicPlaybackFailure? reason;

  /// [reason] 涉及的设备（音频 CD 的光驱，如 `E:`）。
  final String? device;

  /// 失败的是哪一首（后端知道时给）。引擎按它对位：不是当前曲目、也不是预排的下一首的
  /// 失败是过期事件（用户已经切走了），丢弃。
  final String? trackUid;
}

/// [MusicOutputBackend.openPair] 打不开「当前」这一首（取流失败等，打开前就能确定的失败）：
/// 不以事件上报，而是让 `openPair` 直接抛出，调用方（引擎）据此决定跳过还是停下——这样
/// 失败与这一次打开严格对应，不会和用户随后的切歌事件交错。
final class MusicTrackOpenException implements Exception {
  const MusicTrackOpenException(this.failure);

  final MusicBackendFailed failure;

  @override
  String toString() => 'MusicTrackOpenException(${failure.message})';
}

/// 输出后端。实现必须保证：[openPair] 后后端只持有 [current] 与（可选）[next] 两项；
/// 自然播完 [current] 时若有 next 则无缝切过去并发 [MusicBackendAdvanced]，否则发
/// [MusicBackendCompleted]。
///
/// `crossfadeNext` = 引擎判定 current → next 是真边界、该交叉淡入（只有支持交叉淡入的
/// 后端理会；不支持的照常 gapless）。
abstract interface class MusicOutputBackend {
  Stream<MusicBackendEvent> get events;

  Future<void> applySettings(MusicOutputSettings settings);

  /// 换掉整个播放列表：从 [current] 开始，预排 [next]。
  ///
  /// 打开前就确定打不开 [current]（取流失败）时抛 [MusicTrackOpenException]。后来的
  /// `openPair` 会作废还没打开完的前一次（前一次静默返回、不再碰播放器，也不抛）：调用方
  /// 自己按代次判断结果是否还作数。需要异步取流的曲目在取流期间先停掉正在放的旧曲，新文件
  /// 真正交给播放器之后才上报它的位置。
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  });

  /// 只换「下一首」（当前曲目不中断）。
  Future<void> replaceNext(MusicPlayItem? next, {bool crossfadeNext = false});

  Future<void> play();
  Future<void> pause();

  /// 跳到当前曲目内的 [position]（相对曲目起点）。
  Future<void> seek(Duration position);

  /// AB 循环（设计 §12，歌词一行 / 多行）：播到 [b] 立即回到 [a]，两点都相对当前曲目
  /// 起点。两个都给 null = 关。循环由后端在音频时间轴上做（不靠 Dart 定时器追位置），
  /// 换曲目时由引擎显式关掉。
  Future<void> setAbLoop(Duration? a, Duration? b);
  Future<void> stop();
  Future<void> dispose();

  /// 当前信号路径的原始数据（面板用）；没在播时为 null。
  Future<MusicSignalPathSnapshot?> readSignalPath();

  /// 可选的输出设备。
  Future<List<MusicAudioDevice>> listAudioDevices();
}

/// 播放项上的一个歌手引用：[id] 是来源侧（插件）的歌手 id，没有就只按名字找。
class MusicPlayArtistRef {
  const MusicPlayArtistRef({required this.name, this.id});

  final String? id;
  final String name;
}
