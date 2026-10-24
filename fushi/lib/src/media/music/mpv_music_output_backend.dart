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
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:media_kit/media_kit.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_platform_output.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// EDL 段尾的补偿（秒）。mpv 按 `floor((end - pts) · rate)` 截段尾（`audio/aframe.c`
/// `mp_aframe_clip_timestamps`），边界恰好落在样本上时浮点误差让它少一个样本——实测
/// 每段都丢最后 1 个样本，两段拼起来比整轨少 2 个。段尾往后挪 1 µs（44.1 kHz 下 0.044
/// 个样本，768 kHz 下也不到 1 个）就落回正确的样本；段首按同一时刻取 floor，与上一段
/// 首尾相接，不重不漏（真 libmpv 用例逐样本比对整轨）。
const double _kEdlEndSlackSeconds = 0.000001;

/// 最后一轨（播到文件尾）的段长：给一个远超任何音轨的长度，让 mpv 播到真正的 EOF、
/// 不做段尾截断（不给 length 时段尾取解复用器报的时长，同样会被上面的截断吃掉 1 个样本）。
const int _kEdlOpenEndSeconds = 86400;

/// 纯函数：整轨文件里的一段 → mpv EDL URI。路径按 UTF-8 字节数加 `%len%` 前缀，
/// 路径里的逗号 / 等号不会被当成 EDL 分隔符。[endMs] 为 null = 播到文件尾。
String musicEdlUri(String path, {required int startMs, int? endMs}) {
  final String length = endMs == null
      ? '$_kEdlOpenEndSeconds'
      : ((endMs - startMs) / 1000 + _kEdlEndSlackSeconds).toStringAsFixed(6);
  return 'edl://%${utf8.encode(path).length}%$path,'
      'start=${(startMs / 1000).toStringAsFixed(6)},length=$length';
}

/// 纯函数：一首曲目 → mpv 的 [Media]。普通文件直接给路径；CUE 虚拟曲目给 EDL 段。
Media musicMediaOf(MusicPlayItem item) {
  final int start = item.startMs ?? 0;
  final int? end = item.endMs;
  if (start == 0 && end == null) return Media(item.path);
  return Media(musicEdlUri(item.path, startMs: start, endMs: end));
}

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

class MpvMusicOutputBackend implements MusicOutputBackend {
  /// [initialProperties] 在第一次下发设置前写一次，且之后的设置不会覆盖其中的键
  /// （测试用 `ao=null` 免得真出声）。
  MpvMusicOutputBackend({
    PlayerConfiguration configuration = const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music',
    ),
    Map<String, String> initialProperties = const <String, String>{},
    MusicOutputPlatform? platform,
    MusicPlatformOutput platformOutput = const MusicPlatformOutput(),
  }) : _player = Player(configuration: configuration),
       _initialProperties = initialProperties,
       _platform = platform ?? musicOutputPlatformOfHost(),
       _platformOutput = platformOutput {
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.playing.listen(_onPlaying));
    _subs.add(_player.stream.playlist.listen(_onPlaylist));
    _subs.add(_player.stream.completed.listen(_onCompleted));
    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(_player.stream.audioParams.listen(_onAudioParams));
  }

  final Player _player;
  final Map<String, String> _initialProperties;
  final MusicOutputPlatform _platform;
  final MusicPlatformOutput _platformOutput;
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

  /// mpv 播放列表里排在已加载曲目之后的那一首。
  MusicPlayItem? _next;

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
    if (item.isDsd) {
      await native.setProperty(
        'file-local-options/audio-samplerate',
        '${_settings.dsdPcmRate.hz}',
      );
    }
  }

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
  }) async {
    await _ensureInitialised();
    _cancelPending();
    _rewiring = true;
    _entryProducedAudio = false;
    try {
      _audible = current;
      _next = next;
      _lastIndex = 0;
      _mpvItems = <MusicPlayItem>[current, ?next];
      await _applyGain(current);
      await _player.open(
        Playlist(<Media>[
          for (final MusicPlayItem i in _mpvItems) musicMediaOf(i),
        ]),
        play: play,
      );
    } finally {
      _rewiring = false;
    }
  }

  @override
  Future<void> replaceNext(MusicPlayItem? next) async {
    _rewiring = true;
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
      _next = next;
      final MusicPlayItem? loaded = _pending ?? _audible;
      _mpvItems = <MusicPlayItem>[?loaded, ?next];
      if (next != null) await _player.add(musicMediaOf(next));
    } finally {
      _rewiring = false;
    }
  }

  void _onPlaylist(Playlist playlist) {
    if (_rewiring) {
      _lastIndex = playlist.index;
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
    final MusicPlayItem? pending = _pending;
    if (pending == null) return;
    // 每一项（含 CUE 的 EDL 段）时间轴都从 0 开始：越过 0 即开始出声。
    final double speed = _settings.speed <= 0 ? 1 : _settings.speed;
    final double remainingS = -pts / speed;
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
    _advanceTimer?.cancel();
    if (remainingS <= 0) {
      unawaited(_commitAdvance());
    } else if (_playing) {
      _advanceTimer = Timer(
        Duration(microseconds: (remainingS * 1e6).round()),
        () => unawaited(_commitAdvance()),
      );
    }
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
    if (!done || _recovering) return;
    unawaited(_handleCompleted());
  }

  Future<void> _handleCompleted() async {
    if (!_entryProducedAudio) {
      // 没收到过 audio-pts：要么 AO 打不开（报错日志随后到，由 [_recoverOutput] 处理），
      // 要么是不发 audio-pts 的非实时 AO（ao=pcm）。AO 还开着 = 后者，照常算播完。
      final NativePlayer? native = _native;
      if (native == null) return;
      if ((await native.getPropertyAsync('current-ao')).isEmpty) return;
    }
    if (_recovering) return;
    if (_pending != null) await _commitAdvance();
    if (_next != null) return;
    _emit(const MusicBackendCompleted());
    await _releaseAudioDevice();
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
    _emit(MusicBackendFailed(message));
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
      final Duration at = _player.state.position;
      await openPair(audible, _next, play: true);
      if (at > Duration.zero) await seek(at);
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
    final MusicPlayItem? item = _audible;
    final Duration? duration = item?.durationMs == null
        ? (_player.state.duration > Duration.zero
              ? _player.state.duration
              : null)
        : Duration(milliseconds: item!.durationMs!);
    _emit(
      MusicBackendPosition(
        absolute < Duration.zero ? Duration.zero : absolute,
        duration,
      ),
    );
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
      await openPair(audible, pending, play: wasPlaying);
    }
    await _player.seek(position);
  }

  /// mpv 原生 `ab-loop-a` / `ab-loop-b`（秒，相对当前播放项——CUE 曲目的 EDL 段同样
  /// 从 0 起）。`no` = 关。这两个属性跨 loadfile 保留，所以换曲目必须显式关。
  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {
    await _ensureInitialised();
    final NativePlayer? native = _native;
    if (native == null) return;
    String secondsOf(Duration? d) =>
        d == null ? 'no' : (d.inMicroseconds / 1e6).toStringAsFixed(3);
    final bool on = a != null && b != null && b > a;
    await native.setProperty('ab-loop-a', on ? secondsOf(a) : 'no');
    await native.setProperty('ab-loop-b', on ? secondsOf(b) : 'no');
  }

  @override
  Future<void> stop() async {
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
      userFilters: await read('af'),
      androidBitPerfect: _androidBitPerfect,
      iosSampleRate: _iosSampleRate,
    );
  }

  static String? _nonEmpty(String s) => s.isEmpty ? null : s;

  @override
  Future<void> dispose() async {
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

  /// 测试 / 诊断：后端是否处在「已解码下一首、前一首尾巴还在出声」的切换期。
  @visibleForTesting
  bool get debugAdvancePending => _pending != null;
}
