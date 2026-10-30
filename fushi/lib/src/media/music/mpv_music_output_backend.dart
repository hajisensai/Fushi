/// libmpv 输出后端（设计 §4.2 / §7）：音乐专用的独立 [Player] 实例，`vo=null` 纯音频，
/// 不与视频页抢同一个 mpv。播放列表恒为「当前 + 下一首」两项，`gapless-audio=weak` +
/// `prefetch-playlist=yes` 让同格式曲目真无缝。
///
/// **切歌以实际出声为准**：无缝衔接时 mpv 在前一首**解码**完就把 `playlist-playing-pos`
/// 切到下一首，而设备缓冲里还有前一首约 200–400 ms 的尾巴在放（mpv 源码
/// `player/audio.c`：`playing_audio_pts = written_audio_pts - speed·ao_get_delay`；
/// `time-pos` 在 `get_playback_time` 里把负值钳成 0）。所以下一首的 `audio-pts`（不钳位）
/// 在这段时间里是负的，越过该曲起点的那一刻才是它真正开始出声。后端在切换期用每个
/// `audio-pts` 采样算出「还差多少秒越过起点」（= 设备缓冲里剩下的前一首），在那个时刻
/// 发 [MusicBackendAdvanced]；切换期内的位置也按 `audio-pts` 折算成前一首的位置。
///
/// **ReplayGain 由本模块施加**（`replaygain=no` + `volume-gain`）：增益来自曲库（标签里
/// 的 REPLAYGAIN_* / R128_* / iTunNORM，缺标签时是 EBU R128 扫描结果），mpv 自己只认
/// 前一种。mpv 的软件增益在 AO 从缓冲取数据时乘上（`audio/out/buffer.c` →
/// `ao_post_process_data`），所以在出声切换点换增益，前一首的尾巴不会被下一首的增益改到。
///
/// **CUE 虚拟曲目走 EDL**（`edl://%len%path,start=…,length=…`），不用逐文件 `start` 选项：
/// mpv 对 `start` 的实现是加载后做一次播放器级 seek（`player/loadfile.c` →
/// `queue_seek(MPSEEK_ABSOLUTE)`），seek 会 `clear_audio_output_buffers` 把设备缓冲里
/// 前一首没放完的尾巴（实测约 360 ms）直接丢掉——拆轨点根本不无缝。EDL 在解复用层裁段、
/// 解码器按样本裁边，不经播放器 seek，前一首完整放完；而且每段时间轴从 0 开始，位置不用
/// 再减曲目起点。
///
/// **音频 CD 曲目不能走 EDL**（mpv 拒绝 EDL 里的 `cdda://` 源），只能直接加载整盘
/// `cdda://<设备>` + 逐文件 `start` / `end`（[musicCddaFileLocal]）。所以：
/// * 盘上**相邻**的下一首不另开 mpv 文件，而是把当前文件的 `end` 延到下一首的终点——同一条
///   连续的盘时间轴，轨界不经 seek，逐样本无缝；越过下一首起点时（按 `audio-pts` 算出声
///   时刻，同上）发 [MusicBackendAdvanced]。不相邻的下一首（随机 / 跳播 / 别的文件）照常排进
///   播放列表，但 `start` 是播放器级 seek，前一首尾巴会被清掉——这是 mpv 的限制，只在不相邻
///   时发生。
/// * 时间轴是盘时间：位置、seek、A-B 循环、交叉淡入的淡入淡出时刻都按本曲起点
///   （[_originSeconds]）换算。
/// * 盘协议在 media_kit 的播放列表里会丢掉直接请求的来源（`native_open_policy.dart`），所以
///   含 CD 的一对曲目用「单个 [Media] 打开 + [Player.add] 追加」（各自一条 `loadfile`）。
/// * 打开前按 Disc ID 核对光驱里的盘（[musicCdCheckDisc]）；CD 曲目提前结束或报错时再核对
///   一次，没盘 / 换盘给出带原因的 [MusicBackendFailed]。
/// * CD 没有 ReplayGain 标签、也不做响度扫描（光驱里的盘随时会换）：按 0 dB 播。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_engine/media/music/disc/music_disc_media.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginStream;
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart'
    show redactSubsonicCredentials;
import 'package:media_kit/media_kit.dart';

import 'package:fushi/src/media/music/disc/music_audio_cd.dart';
import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_equalizer.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_platform_output.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 纯函数：整轨文件里的一段 → mpv EDL URI。路径按 UTF-8 字节数加 `%len%` 前缀，
/// 路径里的逗号 / 等号不会被当成 EDL 分隔符。[endMs] 为 null = 播到文件尾。
///
/// 段尾补偿（[kMusicEdlEndSlackSeconds]）：mpv 按 `floor((end - pts) · rate)` 截段尾
/// （`audio/aframe.c` `mp_aframe_clip_timestamps`），边界恰好落在样本上时浮点误差让它少一个
/// 样本——实测每段都丢最后 1 个样本，两段拼起来比整轨少 2 个。段尾往后挪 1 µs（44.1 kHz
/// 下 0.044 个样本，768 kHz 下也不到 1 个）就落回正确的样本；段首按同一时刻取 floor，与上
/// 一段首尾相接，不重不漏（真 libmpv 用例逐样本比对整轨）。最后一轨（播到文件尾）给
/// [kMusicEdlOpenEndSeconds] 这样远超任何音轨的段长，让 mpv 播到真正的 EOF、不做段尾截断
/// （不给 length 时段尾取解复用器报的时长，同样会被截断吃掉 1 个样本）。
String musicEdlUri(String path, {required int startMs, int? endMs}) =>
    musicEdlSegmentUri(path, startMs: startMs, endMs: endMs);

/// 纯函数：一首曲目 → mpv 的 [Media]。普通文件直接给路径；CUE 虚拟曲目给 EDL 段。
/// 光盘章节曲目（DVD title / BD 播放列表 + 章节起止）走 [resolveMusicMedia]。
Media musicMediaOf(MusicPlayItem item) {
  final int start = item.startMs ?? 0;
  final int? end = item.endMs;
  if (start == 0 && end == null) return Media(item.path);
  return Media(musicEdlUri(item.path, startMs: start, endMs: end));
}

/// 一首曲目交给 mpv 的东西：[media] + 加载它时要下发的逐文件选项。
///
/// [expiresAt]：在线插件给的流地址过期时刻（epoch 毫秒）；其余为 null。
typedef MusicResolvedMedia = ({
  Media media,
  Map<String, String> fileLocal,
  int? expiresAt,
});

/// 纯函数：音频 CD 的一段盘时间轴 → 逐文件选项。起止按扇区还原到轨界
/// （[musicCddaSeconds]），段尾与 EDL 同样补 [kMusicEdlEndSlackSeconds]（mpv 按
/// `floor((end - pts) · rate)` 截尾，正好落在样本上时浮点误差会少一个样本）。[endMs] 为
/// null = 播到盘尾。
Map<String, String> musicCddaFileLocal({required int startMs, int? endMs}) =>
    <String, String>{
      // 段首同样后挪 1 µs：mpv 按 `trunc((start - pts) · rate)` 跳过样本，起点的十进制
      // 表示若略小于轨界，会多留轨界前的 1 个样本。
      'start': (musicCddaSeconds(startMs) + kMusicEdlEndSlackSeconds)
          .toStringAsFixed(9),
      'end': ?(endMs == null ? null : musicCddaEndOption(endMs)),
      'vid': 'no',
    };

/// CD 段尾的 `end` 值（见 [musicCddaFileLocal]）。
String musicCddaEndOption(int endMs) =>
    (musicCddaSeconds(endMs) + kMusicEdlEndSlackSeconds).toStringAsFixed(9);

/// 纯函数：[to] 是否紧接 [from]、在同一个 `cdda://` 文件里接着播（同一台光驱、起点正好是
/// [from] 的终点）。
bool musicCddaContinues(MusicPlayItem from, MusicPlayItem to) =>
    isMusicCddaPath(from.path) &&
    to.path == from.path &&
    from.endMs != null &&
    to.startMs != null &&
    musicCddaSeconds(to.startMs!) == musicCddaSeconds(from.endMs!);

/// 一首曲目 → mpv 源。光盘章节曲目（`music_disc_media.dart`）换成 dvdvideo / m2ts 的 EDL
/// 段并带逐文件选项；盘不在了（读不到 MPLS）时原样交出路径，由 mpv 报打不开、走既有的
/// 播放失败路径，而不是在这里吞掉。
///
/// 音频 CD 曲目是整盘 `cdda://` + 逐文件起止（文件头「音频 CD」）；[playThrough] = 同一
/// 文件里接着播到的、盘上相邻的后一首（[musicCddaContinues]），文件终点取它的终点。
///
/// 在线音源插件曲目（`fushi-music-plugin://`）此时才向插件取流（[pluginResolver]，缺省
/// [resolveMusicPluginStream]），取不到抛 [MusicPluginStreamUnavailable]。
Future<MusicResolvedMedia> resolveMusicMedia(
  MusicPlayItem item, {
  MusicPlayItem? playThrough,
  MusicPluginStreamResolver? pluginResolver,
}) async {
  if (isMusicPluginPath(item.path)) {
    final MusicPluginStream s =
        await (pluginResolver ?? resolveMusicPluginStream)(item.path);
    return (
      media: Media(s.url, httpHeaders: s.headers.isEmpty ? null : s.headers),
      fileLocal: const <String, String>{},
      expiresAt: s.expiresAt,
    );
  }
  if (isMusicCddaPath(item.path)) {
    return (
      media: Media(item.path),
      fileLocal: musicCddaFileLocal(
        startMs: item.startMs ?? 0,
        endMs: (playThrough ?? item).endMs,
      ),
      expiresAt: null,
    );
  }
  if (isMusicDiscTitlePath(item.path)) {
    final MusicDiscMediaSource? disc = await resolveMusicDiscMediaSource(
      item.path,
      startMs: item.startMs ?? 0,
      endMs: item.endMs,
    );
    if (disc != null) {
      return (
        media: Media(disc.uri),
        fileLocal: disc.fileLocalOptions,
        expiresAt: null,
      );
    }
    return (
      media: Media(item.path),
      fileLocal: const <String, String>{},
      expiresAt: null,
    );
  }
  return (
    media: musicMediaOf(item),
    fileLocal: const <String, String>{},
    expiresAt: null,
  );
}

/// 插件流地址被服务端拒绝（签名过期）时 mpv 打出的那一行。本仓随包 libmpv 的 http(s) 走
/// curl 流（真 libmpv 实测：`[error] curl: HTTP error 403`，紧接着
/// `[error] stream: Failed to open <url>.`）；没有 curl 流、退回 FFmpeg http 协议的构建打的是
/// warning `https: HTTP error 403 Forbidden` / 错误 `Server returned 403 Forbidden`。三种都认。
final RegExp _kHttpRejected = RegExp(
  r'HTTP error (?:403|410)(?!\d)|Server returned 403 Forbidden',
);

/// 纯函数：这行 mpv 日志是不是「流地址被拒（403 / 410）」。
bool isMusicStreamRejectedLog(String text) => _kHttpRejected.hasMatch(text);

/// 当前进程的输出平台。
MusicOutputPlatform musicOutputPlatformOfHost() {
  if (Platform.isWindows) return MusicOutputPlatform.windows;
  if (Platform.isMacOS) return MusicOutputPlatform.macos;
  if (Platform.isLinux) return MusicOutputPlatform.linux;
  if (Platform.isAndroid) return MusicOutputPlatform.android;
  if (Platform.isIOS) return MusicOutputPlatform.ios;
  return MusicOutputPlatform.other;
}

/// 纯函数：输出设置 → 要下发的 mpv 属性（设计 §7.4 的平台表）。
///
/// * Windows `ao=wasapi`、macOS `ao=coreaudio`：独占时 `audio-exclusive=yes`
///   （macOS 下 mpv 重定向到 `coreaudio_exclusive`：hog mode + 切设备物理格式 / 采样率，
///   AO 卸载时还原）。**不**设 `audio-samplerate` / `audio-format`——独占时设备跟随源。
/// * Linux：`ao` 不钉（PipeWire 优先，退 ALSA）；选 `alsa/hw:…` 设备即硬件直出。
/// * Android / iOS：`ao` 用 media_kit 默认；bit-perfect / 采样率由平台通道处理。
/// * ReplayGain 恒 `replaygain=no`：增益由后端按曲目用 `volume-gain` 施加（见文件头）。
Map<String, String> musicMpvProperties(
  MusicOutputSettings settings, {
  required MusicOutputPlatform platform,
  bool exclusiveAllowed = true,
  bool deviceAllowed = true,
}) {
  final bool exclusive = settings.exclusive && exclusiveAllowed;
  return <String, String>{
    'gapless-audio': settings.gapless ? 'weak' : 'no',
    'prefetch-playlist': settings.gapless ? 'yes' : 'no',
    'replaygain': 'no',
    // 纯音频实例：没有画面，也不要封面当视频轨解码。
    'audio-display': 'no',
    if (platform == MusicOutputPlatform.windows) 'ao': 'wasapi',
    if (platform == MusicOutputPlatform.macos) 'ao': 'coreaudio',
    if (platform == MusicOutputPlatform.windows ||
        platform == MusicOutputPlatform.macos)
      'audio-exclusive': exclusive ? 'yes' : 'no',
    'audio-device': deviceAllowed ? settings.audioDevice : 'auto',
    'speed': settings.speed.toStringAsFixed(4),
    'audio-pitch-correction': 'yes',
    'volume': settings.volume.toStringAsFixed(2),
  };
}

/// mpv 打不开音频输出时打的那一行（`player/audio.c`）。
const String _kAoInitFailure = 'Could not open/initialize audio device';

class MpvMusicOutputBackend implements MusicCrossfadeInstance {
  /// [initialProperties] 在第一次下发设置前写一次，且之后的设置不会覆盖其中的键
  /// （测试用 `ao=null` 免得真出声）。
  MpvMusicOutputBackend({
    // 日志要到 warn 级：随包 libmpv 的 curl 流把「HTTP error 403」打在 error 级，但退回
    // FFmpeg http 协议的构建打在 warning 级；原位重取（[_onLog]）靠这行分辨「地址过期」与
    // 「流坏了」。
    PlayerConfiguration configuration = const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music',
      logLevel: MPVLogLevel.warn,
    ),
    Map<String, String> initialProperties = const <String, String>{},
    MusicOutputPlatform? platform,
    MusicPlatformOutput platformOutput = const MusicPlatformOutput(),
    MusicCdDiscIdReader? cdDiscIdReader,
    MusicPluginStreamResolver? pluginStreamResolver,
    int Function()? nowMs,
  }) : _player = Player(configuration: configuration),
       _initialProperties = initialProperties,
       _platform = platform ?? musicOutputPlatformOfHost(),
       _platformOutput = platformOutput,
       _cdDiscIdReader = cdDiscIdReader,
       _pluginStreamResolver = pluginStreamResolver,
       _nowMs = nowMs ?? _wallClockMs {
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.playing.listen(_onPlaying));
    _subs.add(_player.stream.playlist.listen(_onPlaylist));
    _subs.add(_player.stream.completed.listen(_onCompleted));
    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(_player.stream.audioParams.listen(_onAudioParams));
    _subs.add(_player.stream.log.listen(_onLog));
  }

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 插件曲目取流（null = 全局装配点 [resolveMusicPluginStream]）。
  final MusicPluginStreamResolver? _pluginStreamResolver;

  /// 墙钟（epoch 毫秒），判插件流地址是否过期。
  final int Function() _nowMs;

  /// 打开代次：每次 [openPair]（及内部重开 / [stop]）加一。取流回来时代次已变 = 用户已经
  /// 切走，结果丢弃、不碰播放器。
  int _openGen = 0;

  /// 「下一首」代次：每次换下一首（[openPair] / [replaceNext] / [stop]）加一。异步取流的下一首
  /// 回来时代次已变就丢弃。
  int _nextGen = 0;

  /// 插件流地址的过期时刻（epoch 毫秒），按曲目。
  final Map<String, int> _streamExpiresAt = <String, int>{};

  /// 预排的插件下一首在流地址过期前重取（[_scheduleNextRefresh]）。
  Timer? _nextRefreshTimer;

  /// 自上次把文件交给 mpv 以来见过 HTTP 403 / 410（插件流地址过期）。
  bool _httpRejected = false;

  /// 本轮打开里已经原位重取过一次流的曲目（再被拒就按取流失败报）。
  final Set<String> _refetched = <String>{};

  /// 出声曲目最近一次上报的位置（原位重取后跳回这里）。
  Duration _lastPosition = Duration.zero;

  final Player _player;
  final Map<String, String> _initialProperties;
  final MusicOutputPlatform _platform;
  final MusicPlatformOutput _platformOutput;

  /// 音频 CD 核对盘用（null = 后台 isolate 现读光驱）。
  final MusicCdDiscIdReader? _cdDiscIdReader;
  bool _initialised = false;

  /// 底层 mpv 播放器（测试读属性 / 日志用）。
  @visibleForTesting
  Player get debugPlayer => _player;
  final StreamController<MusicBackendEvent> _events =
      StreamController<MusicBackendEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  MusicOutputSettings _settings = const MusicOutputSettings(
    gapless: true,
    replayGain: MusicReplayGainMode.off,
  );
  final Map<String, String> _applied = <String, String>{};

  /// 正在**出声**的曲目。
  MusicPlayItem? _audible;

  /// mpv 已经切过去、但前一首尾巴还在设备缓冲里没放完的曲目（切换期）。
  MusicPlayItem? _pending;

  /// mpv 播放列表里排在已加载曲目之后的那一首（[_nextContinues] 时它不是单独一项，而是
  /// 同一个 `cdda://` 文件的后半段）。
  MusicPlayItem? _next;

  /// [_next] 是盘上紧接着的 CD 曲目，与已加载曲目同在一个 mpv 文件里（文件头「音频 CD」）。
  bool _nextContinues = false;

  /// [_next] 是 CD 曲目但核对盘没通过，没有交给 mpv：前一首放完时报这个原因。
  ({MusicCdDiscCheck check, MusicPlayItem item})? _nextUnavailable;

  /// 与 mpv 播放列表逐项对应（on_load 钩子按 `playlist-pos` 查是哪一首）。
  List<MusicPlayItem> _mpvItems = <MusicPlayItem>[];

  Timer? _advanceTimer;
  bool _playing = false;

  /// 切换期前一首的时长（把下一首的负 `audio-pts` 折算成前一首位置用）。
  Duration? _pendingFromDuration;

  /// 我们自己发起的播放列表变更期间不把 index 变化当成「无缝推进」。
  bool _rewiring = false;
  int _lastIndex = 0;

  /// 独占 / 指定设备打不开后自动退回；用户再改这两项设置时清掉。
  bool _exclusiveFallback = false;
  bool _deviceFallback = false;

  /// 正在从输出失败中恢复：这期间 mpv 报的「播完」是失败导致的，不当真。
  bool _recovering = false;

  /// 当前这一项是否真的出过声（收到过 `audio-pts`：mpv 只在音频输出已在播时才给这个
  /// 属性）。AO 打不开时 mpv 先报 `eof-reached` 再送出报错日志（实测顺序），没出过声的
  /// 「播完」不是曲目播完。
  bool _entryProducedAudio = false;

  /// 交叉淡入（[MusicCrossfadeBackend] 打开）：之后加载的文件都装逐文件淡入淡出滤镜。
  /// 关着时 `af` 一概不碰。
  bool _crossfadeFilters = false;

  /// 交叉淡入进来的曲目 → 加载时的淡入长度（on_load 钩子取走）。
  final Map<String, Duration> _fadeInFor = <String, Duration>{};

  /// 加载时装了交叉淡入滤镜的曲目。
  final Set<String> _filteredUids = <String>{};
  void Function(double pts)? _onAudiblePts;

  MusicBitPerfectResult? _androidBitPerfect;
  MusicIosSampleRateResult? _iosSampleRate;
  String? _lastPlatformFormatKey;

  @override
  Stream<MusicBackendEvent> get events => _events.stream;

  NativePlayer? get _native => _player.platform is NativePlayer
      ? _player.platform! as NativePlayer
      : null;

  void _emit(MusicBackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Future<void> _ensureInitialised() async {
    if (_initialised) return;
    _initialised = true;
    final NativePlayer? native = _native;
    if (native == null) return;
    for (final MapEntry<String, String> e in _initialProperties.entries) {
      await native.setProperty(e.key, e.value);
    }
    native.onLoadHooks.add(_onLoadHook);
    await native.observePropertyChanges('audio-pts', _onAudioPts);
  }

  Future<void> _setIfChanged(String key, String value) async {
    final NativePlayer? native = _native;
    if (native == null) return;
    if (_initialProperties.containsKey(key)) return;
    if (_applied[key] == value) return;
    _applied[key] = value;
    await native.setProperty(key, value);
  }

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {
    await _ensureInitialised();
    if (settings.exclusive != _settings.exclusive) _exclusiveFallback = false;
    if (settings.audioDevice != _settings.audioDevice) _deviceFallback = false;
    final bool exclusiveTurnedOff = _settings.exclusive && !settings.exclusive;
    _settings = settings;
    for (final MapEntry<String, String> e in musicMpvProperties(
      settings,
      platform: _platform,
      exclusiveAllowed: !_exclusiveFallback,
      deviceAllowed: !_deviceFallback,
    ).entries) {
      await _setIfChanged(e.key, e.value);
    }
    await _applyGain(_audible);
    // 均衡器（P5）：没装交叉淡入滤镜时挂在全局 `af` 上（关 / 平直 = 空，bit-perfect 不动）；
    // 装了交叉淡入时由 on_load 钩子与淡入淡出拼进同一条逐文件链（逐文件 `af` 整体替换全局
    // 的，单挂全局会在淡入淡出的那几首上丢掉均衡）。
    if (!_crossfadeFilters) {
      await _setIfChanged('af', musicEqualizerAf(settings.equalizer) ?? '');
    }
    if (_platform == MusicOutputPlatform.android) {
      if (exclusiveTurnedOff) {
        _androidBitPerfect = null;
        _lastPlatformFormatKey = null;
        await _platformOutput.clearBitPerfect();
      } else if (settings.exclusive) {
        _lastPlatformFormatKey = null;
        await _syncPlatformFormat(_player.state.audioParams);
      }
    }
  }

  /// 按出声曲目下发 ReplayGain（`volume-gain`，dB）。
  Future<void> _applyGain(MusicPlayItem? item) async {
    final double db =
        item == null || _settings.replayGain == MusicReplayGainMode.off
        ? 0
        : musicReplayGainDb(
            albumMode: _settings.replayGain == MusicReplayGainMode.album,
            trackGain: item.rgTrackGain,
            trackPeak: item.rgTrackPeak,
            albumGain: item.rgAlbumGain,
            albumPeak: item.rgAlbumPeak,
            preampDb: _settings.replayGainPreampDb,
          );
    await _setIfChanged('volume-gain', db.toStringAsFixed(2));
  }

  /// mpv `on_load` 钩子：按正在加载的那一项下发逐文件选项。DSD 源设
  /// `file-local-options/audio-samplerate`（DSD→PCM 目标采样率，设计 §7.1），换下一首时
  /// mpv 自动还原；PCM 源什么都不设（独占时设备跟随源）。
  Future<void> _onLoadHook() async {
    final NativePlayer? native = _native;
    if (native == null) return;
    final int? index = int.tryParse(
      await native.getPropertyAsync('playlist-pos'),
    );
    if (index == null || index < 0 || index >= _mpvItems.length) return;
    final MusicPlayItem item = _mpvItems[index];
    final Duration? fadeIn = _fadeInFor.remove(item.trackUid);
    if (_crossfadeFilters) {
      await native.setProperty(
        'file-local-options/af',
        musicComposeAf(<String?>[
          musicEqualizerAf(_settings.equalizer),
          musicCrossfadeAf(
            fadeIn: fadeIn ?? Duration.zero,
            originSeconds: _originSeconds(item),
          ),
        ]),
      );
      _filteredUids.add(item.trackUid);
    } else {
      _filteredUids.remove(item.trackUid);
    }
    if (item.isDsd) {
      await native.setProperty(
        'file-local-options/audio-samplerate',
        '${_settings.dsdPcmRate.hz}',
      );
    }
    // 光盘章节曲目：dvdvideo demuxer 选 title、只要音频（[resolveMusicMedia]）。
    for (final MapEntry<String, String> e
        in (_fileLocalFor[item.trackUid] ?? const <String, String>{}).entries) {
      await native.setProperty('file-local-options/${e.key}', e.value);
    }
  }

  /// 曲目 → 逐文件选项（[resolveMusicMedia] 解析时记下，`on_load` 钩子取用）。
  final Map<String, Map<String, String>> _fileLocalFor =
      <String, Map<String, String>>{};

  Future<Media> _mediaFor(
    MusicPlayItem item, {
    MusicPlayItem? playThrough,
  }) async {
    final MusicResolvedMedia resolved = await resolveMusicMedia(
      item,
      playThrough: playThrough,
      pluginResolver: _pluginStreamResolver,
    );
    if (resolved.fileLocal.isEmpty) {
      _fileLocalFor.remove(item.trackUid);
    } else {
      _fileLocalFor[item.trackUid] = resolved.fileLocal;
    }
    final int? expiresAt = resolved.expiresAt;
    if (expiresAt == null) {
      _streamExpiresAt.remove(item.trackUid);
    } else {
      _streamExpiresAt[item.trackUid] = expiresAt;
    }
    return resolved.media;
  }

  /// 预排的下一首：插件曲目取不到流时不排（放到它时 [_handleCompleted] 再取一次）。
  Future<Media?> _mediaForOrNull(MusicPlayItem item) async {
    try {
      return await _mediaFor(item);
    } on MusicPluginStreamUnavailable {
      return null;
    }
  }

  static bool _isPlugin(MusicPlayItem? item) =>
      item != null && isMusicPluginPath(item.path);

  static MusicBackendFailed _unavailable(String message, MusicPlayItem item) =>
      MusicBackendFailed(
        message,
        reason: MusicPlaybackFailure.trackUnavailable,
        trackUid: item.trackUid,
      );

  static bool _isCd(MusicPlayItem? item) =>
      item != null && isMusicCddaPath(item.path);

  /// 这一首在它所在 mpv 文件时间轴上的起点（秒）：CD 曲目是盘时间，其余从 0 起。
  static double _originSeconds(MusicPlayItem? item) =>
      _isCd(item) ? musicCddaSeconds(item!.startMs ?? 0) : 0;

  static Duration _originOf(MusicPlayItem? item) =>
      Duration(microseconds: (_originSeconds(item) * 1e6).round());

  Future<MusicCdDiscCheck> _checkCd(MusicPlayItem item) => musicCdCheckDisc(
    device: musicCddaDevice(item.path),
    trackUid: item.trackUid,
    trackNo: item.trackNo,
    readDiscId: _cdDiscIdReader,
  );

  void _emitCdFailure(MusicCdDiscCheck check, MusicPlayItem item) {
    _emit(
      MusicBackendFailed(
        '${check.name}: ${item.path}',
        reason: check == MusicCdDiscCheck.otherDisc
            ? MusicPlaybackFailure.cdOtherDisc
            : MusicPlaybackFailure.cdNoDisc,
        device: musicCddaDevice(item.path),
        trackUid: item.trackUid,
      ),
    );
  }

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    _refetched.clear();
    await _open(current, next, play: play);
  }

  /// [openPair] 的实现。返回 false = 被更晚的一次打开作废（或 CD 核对没过），没有打开
  /// [current]。取流失败抛 [MusicTrackOpenException]（被作废的不抛）。
  Future<bool> _open(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
  }) async {
    final int gen = ++_openGen;
    _nextGen++;
    _cancelNextRefresh();
    await _ensureInitialised();
    if (gen != _openGen) return false;
    _cancelPending();
    if (_isCd(current)) {
      final MusicCdDiscCheck check = await _checkCd(current);
      if (gen != _openGen) return false;
      if (check != MusicCdDiscCheck.ok) {
        // 不把光驱里的别的盘当成这首播：停掉、交还设备、明确报原因。
        _audible = current;
        _next = null;
        _nextContinues = false;
        _nextUnavailable = null;
        await _releaseAudioDevice();
        _emitCdFailure(check, current);
        return false;
      }
    }
    if (_isPlugin(current)) {
      // 取流要走网络（可能几秒）：先停掉正在放的旧曲。取流期间没有出声曲目，旧曲的位置 /
      // 播完不会被当成新曲的上报。
      await _unload();
      if (gen != _openGen) return false;
    }
    final bool continues = next != null && musicCddaContinues(current, next);
    final Media first;
    try {
      first = await _mediaFor(current, playThrough: continues ? next : null);
    } on MusicPluginStreamUnavailable catch (e) {
      if (gen != _openGen) return false;
      throw MusicTrackOpenException(_unavailable(e.message, current));
    }
    if (gen != _openGen) return false;
    _nextUnavailable = null;
    final MusicPlayItem? separate = continues
        ? null
        : await _queueableNext(next);
    if (gen != _openGen) return false;
    // 插件下一首要走网络取流：先把当前曲交给 mpv，下一首随后异步补进播放列表
    // （[_attachNext]），不让它拖慢起播。
    final MusicPlayItem? lateNext = _isPlugin(separate) ? separate : null;
    final Media? second = separate == null || lateNext != null
        ? null
        : await _mediaFor(separate);
    if (gen != _openGen) return false;
    _rewiring = true;
    _entryProducedAudio = false;
    try {
      _audible = current;
      _next = next;
      _nextContinues = continues;
      _lastIndex = 0;
      _lastPosition = Duration.zero;
      _httpRejected = false;
      _mpvItems = <MusicPlayItem>[current, if (second != null) separate!];
      await _applyGain(current);
      if (_isCd(current) || _isCd(separate)) {
        // 盘协议进播放列表会丢掉直接请求的来源（native_open_policy.dart）：各自 loadfile。
        await _player.open(first, play: play);
        if (second != null) await _player.add(second);
      } else {
        await _player.open(Playlist(<Media>[first, ?second]), play: play);
      }
    } finally {
      _rewiring = false;
    }
    if (second != null) _scheduleNextRefresh(separate!);
    if (lateNext != null) unawaited(_attachNext(lateNext, _nextGen));
    return gen == _openGen;
  }

  /// 卸掉正在放的文件（不交还设备），清空出声 / 预排状态。
  Future<void> _unload() async {
    _cancelPending();
    _audible = null;
    _next = null;
    _nextContinues = false;
    _nextUnavailable = null;
    _mpvItems = <MusicPlayItem>[];
    _rewiring = true;
    try {
      await _player.stop();
    } finally {
      _rewiring = false;
    }
  }

  /// 异步取到插件下一首的流后补进 mpv 播放列表。期间下一首换了（[_nextGen] 变了）就丢弃；
  /// 取不到流就不排（当前曲放完时 [_handleCompleted] 再取一次、仍失败按这一首失败报）。
  Future<void> _attachNext(MusicPlayItem item, int nextGen) async {
    final Media? media = await _mediaForOrNull(item);
    if (media == null ||
        nextGen != _nextGen ||
        !identical(_next, item) ||
        _pending != null ||
        _mpvItems.length != 1) {
      return;
    }
    _rewiring = true;
    try {
      await _player.add(media);
      _mpvItems = <MusicPlayItem>[..._mpvItems, item];
    } finally {
      _rewiring = false;
    }
    _scheduleNextRefresh(item);
  }

  void _cancelNextRefresh() {
    _nextRefreshTimer?.cancel();
    _nextRefreshTimer = null;
  }

  /// 预排进 mpv 的插件下一首：流地址到期前 [kMusicPluginStreamRefreshMargin] 重取一次并换掉
  /// 播放列表里那一项（暂停时同样到点重取——长暂停后续播不会拿过期地址）。地址本来就快过期
  /// （有效期短于余量）时不排，免得反复重取；真被拒由 HTTP 403 / 410 的原位重取兜住。
  void _scheduleNextRefresh(MusicPlayItem item) {
    _cancelNextRefresh();
    if (!_isPlugin(item)) return;
    final int? expiresAt = _streamExpiresAt[item.trackUid];
    if (expiresAt == null) return;
    final int dueMs =
        expiresAt - kMusicPluginStreamRefreshMargin.inMilliseconds - _nowMs();
    if (dueMs <= 0) return;
    final int nextGen = _nextGen;
    _nextRefreshTimer = Timer(
      Duration(milliseconds: dueMs),
      () => unawaited(_refreshQueuedNext(item, nextGen)),
    );
  }

  bool _nextStillQueued(MusicPlayItem item, int nextGen) =>
      nextGen == _nextGen &&
      identical(_next, item) &&
      _pending == null &&
      _mpvItems.length == 2 &&
      identical(_mpvItems.last, item);

  Future<void> _refreshQueuedNext(MusicPlayItem item, int nextGen) async {
    _nextRefreshTimer = null;
    if (!_nextStillQueued(item, nextGen)) return;
    final Media? media = await _mediaForOrNull(item);
    if (!_nextStillQueued(item, nextGen)) return;
    _rewiring = true;
    try {
      final int count = _player.state.playlist.medias.length;
      final int index = _player.state.playlist.index;
      for (int i = count - 1; i > index; i--) {
        await _player.remove(i);
      }
      _lastIndex = _player.state.playlist.index;
      _mpvItems = <MusicPlayItem>[_mpvItems.first];
      if (media != null) {
        await _player.add(media);
        _mpvItems = <MusicPlayItem>[..._mpvItems, item];
      }
    } finally {
      _rewiring = false;
    }
    if (media != null) _scheduleNextRefresh(item);
  }

  /// 不在同一文件里接着播的下一首能不能交给 mpv：CD 曲目先核对盘，不通过就记下原因、不排
  /// （前一首放完时报，见 [_handleCompleted]）。
  Future<MusicPlayItem?> _queueableNext(MusicPlayItem? next) async {
    if (next == null || !_isCd(next)) return next;
    final MusicCdDiscCheck check = await _checkCd(next);
    if (check == MusicCdDiscCheck.ok) return next;
    _nextUnavailable = (check: check, item: next);
    return null;
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    final int nextGen = ++_nextGen;
    _cancelNextRefresh();
    _rewiring = true;
    MusicPlayItem? lateNext;
    MusicPlayItem? queued;
    try {
      final int count = _player.state.playlist.medias.length;
      final int index = _player.state.playlist.index;
      // 已播完的前项与旧的「下一首」都移掉，只留正在播的那一项。
      for (int i = count - 1; i > index; i--) {
        await _player.remove(i);
      }
      for (int i = index - 1; i >= 0; i--) {
        await _player.remove(i);
      }
      _lastIndex = 0;
      final MusicPlayItem? loaded = _pending ?? _audible;
      final bool continued = _nextContinues;
      _next = next;
      _nextContinues =
          loaded != null && next != null && musicCddaContinues(loaded, next);
      _nextUnavailable = null;
      if (loaded != null && (_nextContinues || continued)) {
        // 同一个 cdda:// 文件：终点延到相邻的下一首，或收回到本首终点。
        final int? end = (_nextContinues ? next! : loaded).endMs;
        final String value = end == null ? 'none' : musicCddaEndOption(end);
        // 刚打开、on_load 钩子还没跑时，它会按记下的逐文件选项写 end：记下的也换掉。
        final MusicPlayItem? head = index >= 0 && index < _mpvItems.length
            ? _mpvItems[index]
            : null;
        final Map<String, String>? recorded = head == null
            ? null
            : _fileLocalFor[head.trackUid];
        if (head != null && recorded != null) {
          _fileLocalFor[head.trackUid] = <String, String>{
            ...recorded,
            'end': value,
          };
        }
        await _native?.setProperty('file-local-options/end', value);
      }
      _mpvItems = <MusicPlayItem>[?loaded];
      final MusicPlayItem? separate = _nextContinues
          ? null
          : await _queueableNext(next);
      if (nextGen != _nextGen) return;
      if (_isPlugin(separate)) {
        // 走网络取流：不在 rewiring 里等（等的这段时间 mpv 的自然推进不能被吞掉）。
        lateNext = separate;
      } else if (separate != null) {
        final Media? media = await _mediaForOrNull(separate);
        if (nextGen != _nextGen) return;
        if (media != null) {
          await _player.add(media);
          _mpvItems = <MusicPlayItem>[..._mpvItems, separate];
          queued = separate;
        }
      }
    } finally {
      _rewiring = false;
    }
    if (queued != null) _scheduleNextRefresh(queued);
    if (lateNext != null) await _attachNext(lateNext, nextGen);
  }

  void _onPlaylist(Playlist playlist) {
    if (_rewiring) {
      _lastIndex = playlist.index;
      return;
    }
    if (playlist.index > _lastIndex && _rejectedMidStream()) {
      // 插件流地址中途被拒（长暂停后重连拿到 403 / 410），mpv 把它当成文件结束切走了：
      // 不是播完，原位重取。
      _lastIndex = playlist.index;
      unawaited(_refetchInPlace(_audible!));
      return;
    }
    if (playlist.index > _lastIndex && _next != null) {
      // mpv 开始**解码**下一首；前一首尾巴还在设备缓冲里。等 audio-pts 越过起点再推进。
      _pending = _next;
      _next = null;
      _entryProducedAudio = false;
      _pendingFromDuration = _audible?.durationMs == null
          ? null
          : Duration(milliseconds: _audible!.durationMs!);
      _lastIndex = playlist.index;
      return;
    }
    _lastIndex = playlist.index;
  }

  /// 切换期：每个 `audio-pts` 采样都重新算越过下一首起点的时刻（采样只有约 10 Hz，直接
  /// 等「下一个非负采样」会晚到 100 ms）。
  Future<void> _onAudioPts(String raw) async {
    final double? pts = double.tryParse(raw);
    if (pts == null) return;
    _entryProducedAudio = true;
    final double speed = _settings.speed <= 0 ? 1 : _settings.speed;
    final MusicPlayItem? pending = _pending;
    if (pending == null) {
      final MusicPlayItem? next = _next;
      if (_nextContinues && next != null) {
        // 同一 cdda:// 文件里的下一首：越过它在盘上的起点即开始出声。
        _scheduleAdvance(
          (_originSeconds(next) - pts) / speed,
          _commitContinuedAdvance,
        );
      }
      _onAudiblePts?.call(pts - _originSeconds(_audible));
      return;
    }
    // 每一项时间轴从这一首的起点开始（含 CUE 的 EDL 段从 0 起；CD 曲目是它的盘时间起点）：
    // 越过起点即开始出声。
    final double remainingS = (_originSeconds(pending) - pts) / speed;
    final Duration? fromDuration = _pendingFromDuration;
    if (fromDuration != null) {
      final Duration pos =
          fromDuration -
          Duration(microseconds: (remainingS * speed * 1e6).round());
      _emit(
        MusicBackendPosition(
          pos < Duration.zero ? Duration.zero : pos,
          fromDuration,
        ),
      );
    }
    _scheduleAdvance(remainingS, _commitAdvance);
  }

  /// 按「还差多少秒出声」安排推进（暂停时不排，恢复后的下一个采样重算）。
  void _scheduleAdvance(double remainingS, Future<void> Function() commit) {
    _advanceTimer?.cancel();
    if (remainingS <= 0) {
      unawaited(commit());
    } else if (_playing) {
      _advanceTimer = Timer(
        Duration(microseconds: (remainingS * 1e6).round()),
        () => unawaited(commit()),
      );
    }
  }

  /// 同一 cdda:// 文件里的下一首开始出声。
  Future<void> _commitContinuedAdvance() async {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    final MusicPlayItem? next = _next;
    final MusicPlayItem? from = _audible;
    if (!_nextContinues || next == null) return;
    _nextContinues = false;
    _next = null;
    _audible = next;
    // 逐文件滤镜（交叉淡入的淡出）装在整个文件上，下一首同样带着。
    if (from != null && _filteredUids.contains(from.trackUid)) {
      _filteredUids.add(next.trackUid);
    }
    _emit(MusicBackendAdvanced(next.trackUid));
    await _applyGain(next);
  }

  Future<void> _commitAdvance() async {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    final MusicPlayItem? pending = _pending;
    if (pending == null) return;
    _pending = null;
    _pendingFromDuration = null;
    _audible = pending;
    _emit(MusicBackendAdvanced(pending.trackUid));
    await _applyGain(pending);
  }

  void _cancelPending() {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    _pending = null;
    _pendingFromDuration = null;
  }

  void _onPlaying(bool playing) {
    _playing = playing;
    // 暂停时设备停止消耗缓冲，越过时刻要等恢复后的下一个 audio-pts 重新算。
    if (!playing) _advanceTimer?.cancel();
    _emit(MusicBackendPlaying(playing));
  }

  void _onCompleted(bool done) {
    // 没有出声曲目 = 取流期间卸掉旧曲带出来的「播完」，不当真。
    if (!done || _recovering || _audible == null) return;
    unawaited(_handleCompleted());
  }

  /// 插件曲目没放到结尾（离结尾还有 5 秒以上）就结束了、而且这期间见过 HTTP 403 / 410：
  /// 流地址过期，不是播完。
  bool _rejectedMidStream() {
    final MusicPlayItem? audible = _audible;
    if (_refetching) return false;
    if (!_httpRejected || _pending != null || !_isPlugin(audible)) {
      return false;
    }
    final int? ms = audible!.durationMs;
    return ms == null ||
        _lastPosition + const Duration(seconds: 5) < Duration(milliseconds: ms);
  }

  Future<void> _handleCompleted() async {
    if (!_entryProducedAudio) {
      // 没收到过 audio-pts：要么 AO 打不开（报错日志随后到，由 [_recoverOutput] 处理），
      // 要么是不发 audio-pts 的非实时 AO（ao=pcm），要么是插件流地址一打开就被拒（由
      // [_onError] 原位重取）。AO 还开着 = 第二种，照常算播完。
      final NativePlayer? native = _native;
      if (native == null) return;
      if ((await native.getPropertyAsync('current-ao')).isEmpty) return;
    }
    if (_recovering || _refetching || _audible == null) return;
    if (_rejectedMidStream()) {
      await _refetchInPlace(_audible!);
      return;
    }
    if (_pending != null) await _commitAdvance();
    // 文件放完 = 同一文件里接着的那一首也放完了。
    if (_nextContinues) await _commitContinuedAdvance();
    final MusicPlayItem? audible = _audible;
    if (_isCd(audible)) {
      // CD 中途拔出 / 换盘时 mpv 读不到扇区就当文件结束：核对一次，别当成正常播完。
      final MusicCdDiscCheck check = await _checkCd(audible!);
      if (check != MusicCdDiscCheck.ok) {
        _next = null;
        _nextUnavailable = null;
        await _releaseAudioDevice();
        _emitCdFailure(check, audible);
        return;
      }
    }
    final ({MusicCdDiscCheck check, MusicPlayItem item})? unavailable =
        _nextUnavailable;
    if (unavailable != null && identical(unavailable.item, _next)) {
      // 下一首是 CD 曲目但盘不对，没交给 mpv：停在这里并说明原因。
      _next = null;
      _nextUnavailable = null;
      await _releaseAudioDevice();
      _emitCdFailure(unavailable.check, unavailable.item);
      return;
    }
    final MusicPlayItem? next = _next;
    if (next != null &&
        !_mpvItems.any((MusicPlayItem i) => identical(i, next))) {
      // 下一首没进 mpv 播放列表（插件曲目预排时没取到流 / 取流还没回来）：现在取。
      await _openDeferredNext(next);
      return;
    }
    if (_next != null) return;
    _emit(const MusicBackendCompleted());
    await _releaseAudioDevice();
  }

  /// 当前曲放完、下一首（插件曲目）还没交给 mpv：现在取流。取到就当作 mpv 自然前进
  /// （[MusicBackendAdvanced]，引擎随后照常 [replaceNext]）；仍取不到就停下，报**这一首**
  /// 取流失败（引擎据 trackUid 推进到它并按失败处理：跳下一首或停）。
  Future<void> _openDeferredNext(MusicPlayItem item) async {
    final int gen = ++_openGen;
    _nextGen++;
    _cancelNextRefresh();
    final Media media;
    try {
      media = await _mediaFor(item);
    } on MusicPluginStreamUnavailable catch (e) {
      if (gen != _openGen) return;
      _next = null;
      await _releaseAudioDevice();
      _emit(_unavailable(e.message, item));
      return;
    }
    if (gen != _openGen) return;
    _rewiring = true;
    _entryProducedAudio = false;
    try {
      _audible = item;
      _next = null;
      _nextContinues = false;
      _lastIndex = 0;
      _lastPosition = Duration.zero;
      _httpRejected = false;
      _mpvItems = <MusicPlayItem>[item];
      await _applyGain(item);
      await _player.open(Playlist(<Media>[media]));
    } finally {
      _rewiring = false;
    }
    _emit(MusicBackendAdvanced(item.trackUid));
  }

  /// 插件流地址被拒（HTTP 403 / 410，签名过期）：重新取流、在原位置接着放。同一首在一次
  /// 打开里只重取一次，再被拒按取流失败报（引擎跳下一首）。
  Future<void> _refetchInPlace(MusicPlayItem item) async {
    // 同一次被拒会同时触发打开失败、文件结束与播放列表前进：只处理第一个。
    if (_refetching) return;
    _refetching = true;
    try {
      await _refetchInPlaceOnce(item);
    } finally {
      _refetching = false;
    }
  }

  bool _refetching = false;

  Future<void> _refetchInPlaceOnce(MusicPlayItem item) async {
    _httpRejected = false;
    if (!_refetched.add(item.trackUid)) {
      _next = null;
      await _releaseAudioDevice();
      _emit(_unavailable('流地址被服务器拒绝（HTTP 403 / 410）', item));
      return;
    }
    // 被拒的是切换期里刚开始解码的下一首：它从头放，并补发推进（前一首的尾巴随之丢掉）。
    final bool wasPending = identical(item, _pending);
    final Duration at = wasPending ? Duration.zero : _lastPosition;
    final bool opened;
    try {
      opened = await _open(item, wasPending ? null : _next, play: true);
    } on MusicTrackOpenException catch (e) {
      _emit(e.failure);
      return;
    }
    if (!opened) return;
    if (wasPending) _emit(MusicBackendAdvanced(item.trackUid));
    if (at > Duration.zero) await seek(at);
  }

  /// 卸载文件并交还音频设备（独占 / hog mode 随之释放）。
  ///
  /// gapless 下 mpv 播完不卸载 AO（`player/loadfile.c`：`!gapless_audio` 才
  /// `uninit_audio_out`），keep-open 停在文件尾时也一直占着设备；media_kit 的
  /// `dispose` 还要再过 5 秒才 `mpv_terminate_destroy`。独占模式下这段时间别的程序
  /// （以及紧接着新建的下一个音乐实例）都拿不到设备。先 `stop` 卸掉文件（没有音频链），
  /// 再 `ao-reload`——此时它只卸载、不重开（`player/audio.c` `reload_audio_output`）。
  /// 下次 loadfile 自动重开设备。
  Future<void> _releaseAudioDevice() async {
    final NativePlayer? native = _native;
    if (native == null || !_initialised) return;
    _cancelPending();
    _rewiring = true;
    try {
      await _player.stop();
    } finally {
      _rewiring = false;
    }
    _mpvItems = <MusicPlayItem>[];
    await native.command(<String>['ao-reload']);
  }

  void _onError(String message) {
    if (message.contains(_kAoInitFailure)) {
      unawaited(_recoverOutput(message));
      return;
    }
    final MusicPlayItem? item = _pending ?? _audible;
    // 没有出声曲目（取流期间卸掉旧曲）时的报错属于旧曲，不上报。
    if (item == null) return;
    if (_isCd(item)) {
      unawaited(_reportCdError(item, message));
      return;
    }
    if (_isPlugin(item)) {
      if (_refetching) return;
      if (_httpRejected) {
        // 流地址过期被拒：原位重取一次。
        unawaited(_refetchInPlace(item));
        return;
      }
      // 插件流打不开（网络 / 服务端拒绝）：只是这一首拿不到流，引擎跳下一首。
      _emit(_unavailable(redactSubsonicCredentials(message), item));
      return;
    }
    // 服务器曲库的流地址把凭据放在 query 里（mpv 没有头通道）：mpv 的打开失败文本会带上
    // 整条 URL，界面 toast / 错误日志拿到前先脱敏（含 Subsonic 的 t / s）。
    _emit(
      MusicBackendFailed(
        redactSubsonicCredentials(message),
        trackUid: item.trackUid,
      ),
    );
  }

  /// mpv 日志：记下插件流地址被拒（403 / 410）。这行（`curl:` / `ffmpeg:` 前缀）不进 media_kit
  /// 的错误流，错误流只收到随后的「Failed to open」；据此才把那次失败判成地址过期而不是坏流。
  void _onLog(PlayerLog log) {
    if (isMusicStreamRejectedLog(log.text)) _httpRejected = true;
  }

  /// CD 曲目播放报错：盘不在 / 换了盘时报这个原因，否则原样报 mpv 的文本。
  Future<void> _reportCdError(MusicPlayItem item, String message) async {
    final MusicCdDiscCheck check = await _checkCd(item);
    if (check == MusicCdDiscCheck.ok) {
      _emit(MusicBackendFailed(message, trackUid: item.trackUid));
    } else {
      _emitCdFailure(check, item);
    }
  }

  /// 输出打不开：独占 → 共享；还不行（或本来就是共享）且指定了设备 → 默认设备。每一步
  /// 都发 [MusicBackendOutputFallback] 让界面明确提示，然后在原位置重开。
  Future<void> _recoverOutput(String message) async {
    final MusicOutputFallbackReason reason;
    if (_settings.exclusive && !_exclusiveFallback) {
      _exclusiveFallback = true;
      reason = MusicOutputFallbackReason.exclusiveUnavailable;
    } else if (_settings.audioDevice != 'auto' && !_deviceFallback) {
      _deviceFallback = true;
      reason = MusicOutputFallbackReason.deviceUnavailable;
    } else {
      _emit(MusicBackendFailed(message));
      return;
    }
    final MusicPlayItem? audible = _audible;
    _recovering = true;
    try {
      _emit(MusicBackendOutputFallback(reason, message));
      await applySettings(_settings);
      if (audible == null) return;
      final Duration at = _player.state.position - _originOf(audible);
      final bool opened;
      try {
        opened = await _open(audible, _next, play: true);
      } on MusicTrackOpenException catch (e) {
        _emit(e.failure);
        return;
      }
      if (opened && at > Duration.zero) await seek(at);
    } finally {
      _recovering = false;
    }
  }

  void _onAudioParams(AudioParams params) {
    unawaited(_syncPlatformFormat(params));
  }

  /// 解码格式变了（新曲目开始解码）：Android 独占时按源格式请求 bit-perfect 混音属性；
  /// iOS 把首选采样率设成源采样率。
  Future<void> _syncPlatformFormat(AudioParams params) async {
    final int? rate = params.sampleRate;
    final int? channels = params.channelCount;
    if (rate == null || channels == null || rate <= 0) return;
    final MusicPlayItem? item = _pending ?? _audible;
    final String key = '$rate/${params.format}/$channels/${item?.bitDepth}';
    if (key == _lastPlatformFormatKey) return;
    _lastPlatformFormatKey = key;
    switch (_platform) {
      case MusicOutputPlatform.android:
        if (!_settings.exclusive) return;
        final MusicPcmEncoding? encoding = musicPcmEncodingOf(
          params.format,
          sourceBitDepth: item?.bitDepth,
        );
        if (encoding == null) return;
        final MusicBitPerfectState? before = _androidBitPerfect?.state;
        final MusicBitPerfectResult result = await _platformOutput
            .requestBitPerfect(
              sampleRate: rate,
              channelCount: channels,
              encoding: encoding,
            );
        _androidBitPerfect = result;
        if (!result.enabled && result.state != before) {
          _emit(
            MusicBackendOutputFallback(
              MusicOutputFallbackReason.exclusiveUnavailable,
              '${result.state.wire}: ${result.message ?? ''}',
            ),
          );
        }
      case MusicOutputPlatform.ios:
        _iosSampleRate = await _platformOutput.setPreferredSampleRate(rate);
      case MusicOutputPlatform.windows:
      case MusicOutputPlatform.macos:
      case MusicOutputPlatform.linux:
      case MusicOutputPlatform.other:
        return;
    }
  }

  void _onPosition(Duration absolute) {
    // 切换期 mpv 的 time-pos 已是下一首（钳在 0），位置由 audio-pts 折算。
    if (_pending != null) return;
    final MusicPlayItem? next = _next;
    if (_nextContinues && next != null && absolute >= _originOf(next)) {
      // 同一 cdda:// 文件里已放到下一首（不发 audio-pts 的 AO 只能靠这里推进）。
      unawaited(_commitContinuedAdvance());
      return;
    }
    final MusicPlayItem? item = _audible;
    // 取流期间没有出声曲目：mpv 卸掉旧曲时报的位置不上报。
    if (item == null) return;
    final Duration? duration = item.durationMs == null
        ? (_player.state.duration > Duration.zero
              ? _player.state.duration
              : null)
        : Duration(milliseconds: item.durationMs!);
    final Duration relative = absolute - _originOf(item);
    final Duration clamped = relative < Duration.zero
        ? Duration.zero
        : relative;
    _lastPosition = clamped;
    _emit(MusicBackendPosition(clamped, duration));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) async {
    final MusicPlayItem? audible = _audible;
    if (_pending != null && audible != null) {
      // 切换期 mpv 已加载下一首，用户拖的是还在出声的前一首：重开前一首再跳。
      final MusicPlayItem pending = _pending!;
      final bool wasPlaying = _playing;
      try {
        if (!await _open(audible, pending, play: wasPlaying)) return;
      } on MusicTrackOpenException catch (e) {
        _emit(e.failure);
        return;
      }
    }
    // 同一 cdda:// 文件里接着的下一首：已排的推进时刻作废，下一个 audio-pts 重算。
    if (_nextContinues) _advanceTimer?.cancel();
    // CD 曲目的时间轴是盘时间：加上本曲起点。
    await _player.seek(position + _originOf(_audible));
  }

  /// mpv 原生 `ab-loop-a` / `ab-loop-b`（秒，相对当前播放项——CUE 曲目的 EDL 段同样
  /// 从 0 起，CD 曲目加上本曲在盘上的起点）。`no` = 关。这两个属性跨 loadfile 保留，所以
  /// 换曲目必须显式关。
  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {
    await _ensureInitialised();
    final NativePlayer? native = _native;
    if (native == null) return;
    final Duration origin = _originOf(_audible);
    String secondsOf(Duration? d) => d == null
        ? 'no'
        : ((d + origin).inMicroseconds / 1e6).toStringAsFixed(3);
    final bool on = a != null && b != null && b > a;
    await native.setProperty('ab-loop-a', on ? secondsOf(a) : 'no');
    await native.setProperty('ab-loop-b', on ? secondsOf(b) : 'no');
  }

  @override
  Future<void> stop() async {
    // 在途的打开 / 取流作废：回来后不再把文件交给 mpv。
    _openGen++;
    _nextGen++;
    _cancelNextRefresh();
    await _releaseAudioDevice();
    if (_platform == MusicOutputPlatform.android &&
        _androidBitPerfect != null) {
      _androidBitPerfect = null;
      _lastPlatformFormatKey = null;
      await _platformOutput.clearBitPerfect();
    }
  }

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async {
    await _ensureInitialised();
    final NativePlayer? native = _native;
    if (native == null) return const <MusicAudioDevice>[];
    return MusicAudioDevice.listFromMpvJson(
      await native.getPropertyAsync('audio-device-list'),
    );
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async {
    final NativePlayer? native = _native;
    if (native == null || _audible == null) return null;
    Future<String> read(String p) => native.getPropertyAsync(p);
    double readDouble(String raw, double fallback) =>
        double.tryParse(raw) ?? fallback;
    final String device = await read('audio-device');
    final List<MusicAudioDevice> devices = MusicAudioDevice.listFromMpvJson(
      await read('audio-device-list'),
    );
    String? deviceDescription;
    for (final MusicAudioDevice d in devices) {
      if (d.name == device) deviceDescription = d.description;
    }
    final MusicPlayItem? item = _pending ?? _audible;
    final String rawAf = await read('af');
    return MusicSignalPathSnapshot(
      platform: _platform,
      fileFormat: _nonEmpty(await read('file-format')),
      codec: _nonEmpty(await read('current-tracks/audio/codec')),
      codecDescription: _nonEmpty(await read('audio-codec')),
      sourceSampleRate: int.tryParse(
        await read('current-tracks/audio/demux-samplerate'),
      ),
      sourceChannelCount: int.tryParse(
        await read('current-tracks/audio/demux-channel-count'),
      ),
      sourceBitDepth: item?.bitDepth,
      bitrate: double.tryParse(await read('audio-bitrate'))?.round(),
      decoded: MusicAudioFormat.fromMpvJson(await read('audio-params')),
      output: MusicAudioFormat.fromMpvJson(await read('audio-out-params')),
      currentAo: _nonEmpty(await read('current-ao')),
      audioDevice: _nonEmpty(device),
      audioDeviceDescription: deviceDescription,
      exclusiveRequested: await read('audio-exclusive') == 'yes',
      volume: readDouble(await read('volume'), 100),
      volumeGainDb: readDouble(await read('volume-gain'), 0),
      muted: await read('mute') == 'yes',
      speed: readDouble(await read('speed'), 1),
      pitchCorrection: await read('audio-pitch-correction') == 'yes',
      userFilters: musicStripEqualizerFilters(
        musicStripCrossfadeFilters(rawAf),
      ),
      equalizer: musicAfHasEqualizer(rawAf),
      crossfade: item != null && _filteredUids.contains(item.trackUid),
      crossfadeAvailability: musicCrossfadeAvailability(
        _settings,
        platform: _platform,
      ),
      androidBitPerfect: _androidBitPerfect,
      iosSampleRate: _iosSampleRate,
    );
  }

  static String? _nonEmpty(String s) => s.isEmpty ? null : s;

  /// 测试：加载时装了交叉淡入滤镜的曲目。
  @visibleForTesting
  Set<String> get debugCrossfadeFilteredUids =>
      Set<String>.unmodifiable(_filteredUids);

  /// 测试：[dispose] 已调用。
  @visibleForTesting
  bool get debugDisposed => _disposed;
  bool _disposed = false;

  @override
  Future<void> dispose() async {
    _disposed = true;
    _openGen++;
    _nextGen++;
    _cancelNextRefresh();
    _cancelPending();
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _events.close();
    if (_platform == MusicOutputPlatform.android &&
        _androidBitPerfect != null) {
      await _platformOutput.clearBitPerfect();
    }
    // 立刻卸载 AO（不等 media_kit 5 秒后的 mpv_terminate_destroy）：WASAPI 独占即时释放，
    // macOS coreaudio_exclusive 在卸载时交还 hog mode 并还原设备原物理格式 / 采样率。
    await _releaseAudioDevice();
    await _player.dispose();
  }

  // ── 交叉淡入（MusicCrossfadeInstance）─────────────────────────────────────

  @override
  set crossfadeFiltersEnabled(bool value) => _crossfadeFilters = value;

  @override
  Future<void> openIncoming(
    MusicPlayItem item, {
    required Duration fadeIn,
  }) async {
    _fadeInFor[item.trackUid] = fadeIn;
    await openPair(item, null, play: false);
  }

  @override
  bool get audibleHasCrossfadeFilters {
    final MusicPlayItem? audible = _audible;
    return _pending == null &&
        audible != null &&
        _filteredUids.contains(audible.trackUid);
  }

  @override
  Duration? get audibleMediaDuration {
    if (_pending != null) return null;
    final int? ms = _audible?.durationMs;
    // CD 曲目的 mpv 文件是整盘（加起止），文件时长不是这一首的时长。
    if (_isCd(_audible)) return ms == null ? null : Duration(milliseconds: ms);
    final Duration d = _player.state.duration;
    if (d > Duration.zero) return d;
    return ms == null ? null : Duration(milliseconds: ms);
  }

  @override
  bool get advancePending => _pending != null;

  Future<void> _fadeOutCommand(String option, String value) async {
    final NativePlayer? native = _native;
    if (native == null) return;
    await native.command(<String>[
      'af-command',
      kMusicCrossfadeOutLabel,
      option,
      value,
    ]);
  }

  static String _seconds(Duration d) =>
      (d.inMicroseconds / 1e6).toStringAsFixed(6);

  @override
  Future<void> armFadeOut({
    required Duration start,
    required Duration length,
  }) async {
    // 先长度后起点：afade 每条命令后都按秒重算样本数，起点最后改，中间态不会提前淡出。
    await _fadeOutCommand('d', _seconds(length));
    // afade 按文件时间戳算：CD 曲目要加上本曲在盘上的起点。
    await _fadeOutCommand('st', _seconds(start + _originOf(_audible)));
  }

  @override
  Future<void> disarmFadeOut() =>
      _fadeOutCommand('st', kMusicCrossfadeIdleStartSeconds.toStringAsFixed(0));

  @override
  set onAudiblePts(void Function(double pts)? callback) =>
      _onAudiblePts = callback;

  /// 测试 / 诊断：后端是否处在「已解码下一首、前一首尾巴还在出声」的切换期。
  @visibleForTesting
  bool get debugAdvancePending => _pending != null;
}
