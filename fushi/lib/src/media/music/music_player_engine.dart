/// 音乐播放编排（设计 §7.2）：队列在 Dart，向输出后端只维持「当前 + 下一首」两项；
/// 后端无缝切到下一首时，引擎推进队列并把新的「下一首」补给后端。ReplayGain 按播放
/// 语境选：整张专辑顺序播 = album，随机 / 混排 = track。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 队列从哪来：决定 ReplayGain 模式（专辑语境用 album gain 保留曲间响度差）。
enum MusicQueueContext {
  /// 一张专辑按碟号 / 轨号顺序播。
  album,

  /// 跨专辑的曲目列表（歌曲分区、艺人、歌单）。
  mixed,
}

/// 纯函数：语境 + 是否随机 → ReplayGain 模式（设计 §7.2）。[enabled] 为 false = 关。
MusicReplayGainMode musicReplayGainModeFor({
  required bool enabled,
  required MusicQueueContext context,
  required bool shuffled,
}) {
  if (!enabled) return MusicReplayGainMode.off;
  if (context == MusicQueueContext.album && !shuffled) {
    return MusicReplayGainMode.album;
  }
  return MusicReplayGainMode.track;
}

/// 「上一首」的判据：当前曲目已播超过 [threshold] 时回到本曲开头，否则退到上一首
/// （与主流播放器一致）。返回 true = 退到上一首。
bool musicPreviousGoesBack(
  Duration position, {
  Duration threshold = const Duration(seconds: 3),
}) => position <= threshold;

/// AB 循环区间（相对当前曲目起点，`b > a`）。
@immutable
class MusicAbLoop {
  const MusicAbLoop(this.a, this.b);

  final Duration a;
  final Duration b;

  @override
  bool operator ==(Object other) =>
      other is MusicAbLoop && other.a == a && other.b == b;

  @override
  int get hashCode => Object.hash(a, b);
}

/// 构造输出后端的工厂（真 app 给 libmpv，测试给替身）。
typedef MusicOutputBackendFactory = MusicOutputBackend Function();

class MusicPlayerEngine extends ChangeNotifier {
  MusicPlayerEngine({
    required MusicOutputBackendFactory backendFactory,
    bool Function()? gaplessEnabled,
    bool Function()? replayGainEnabled,
    MusicOutputSettings Function()? baseSettings,
    Random? random,
  }) : _backendFactory = backendFactory,
       _gaplessEnabled = gaplessEnabled ?? (() => true),
       _replayGainEnabled = replayGainEnabled ?? (() => true),
       _baseSettings = baseSettings ?? (() => _kDefaultBaseSettings),
       _random = random ?? Random();

  static const MusicOutputSettings _kDefaultBaseSettings = MusicOutputSettings(
    gapless: true,
    replayGain: MusicReplayGainMode.off,
  );

  final MusicOutputBackendFactory _backendFactory;
  final bool Function() _gaplessEnabled;
  final bool Function() _replayGainEnabled;

  /// 其余输出偏好（独占 / 设备 / 音量 / 变速 / 预放大 / DSD / 交叉淡入），来自设置。
  final MusicOutputSettings Function() _baseSettings;
  final Random _random;

  MusicOutputBackend? _backend;
  StreamSubscription<MusicBackendEvent>? _eventSub;

  /// 播放顺序（随机时是打乱后的顺序）。
  List<MusicPlayItem> _queue = const <MusicPlayItem>[];

  /// 原始顺序（关随机时还原）。
  List<MusicPlayItem> _original = const <MusicPlayItem>[];
  int _index = -1;
  MusicQueueContext _context = MusicQueueContext.mixed;
  bool _shuffled = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  String? _lastError;
  bool _stopAfterCurrent = false;

  /// 队列（或睡眠定时）播完、后端已卸载文件。
  bool _ended = false;
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  MusicBackendOutputFallback? _lastOutputFallback;
  MusicAbLoop? _abLoop;

  /// 输出自动退回（独占 → 共享 / 指定设备 → 默认）时调用：界面弹明确提示。
  void Function(MusicBackendOutputFallback fallback)? onOutputFallback;

  /// 每次真正开始播一首新曲（含无缝推进）时调用：播放流落库、媒体会话刷新。
  void Function(MusicPlayItem item)? onTrackStarted;

  /// 播放状态变成「在播」时调用：媒体会话仲裁（暂停有声书、认领通知）。
  VoidCallback? onWillPlay;

  List<MusicPlayItem> get queue => List<MusicPlayItem>.unmodifiable(_queue);
  int get index => _index;
  MusicPlayItem? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  MusicPlayItem? get next =>
      _index + 1 >= 0 && _index + 1 < _queue.length ? _queue[_index + 1] : null;
  bool get isPlaying => _playing;
  bool get isActive => current != null;
  bool get shuffled => _shuffled;
  Duration get position => _position;
  Duration? get duration => _duration;
  String? get lastError => _lastError;

  /// 睡眠定时：播完本曲停。
  bool get stopAfterCurrent => _stopAfterCurrent;

  /// 睡眠定时器的到点时刻（到点后播完正在放的那首停）；null = 没开。
  DateTime? get sleepDeadline => _sleepDeadline;

  /// 最近一次输出退回（面板显示原因）；用户改输出设置后清掉。
  MusicBackendOutputFallback? get lastOutputFallback => _lastOutputFallback;

  /// 当前 AB 循环（相对当前曲目起点）；null = 没开。换曲目自动关。
  MusicAbLoop? get abLoop => _abLoop;

  /// 开 / 改 AB 循环；[loop] 为 null（或区间为空）= 关。没在播时只记状态不下发。
  Future<void> setAbLoop(MusicAbLoop? loop) async {
    final MusicAbLoop? next = loop == null || loop.b <= loop.a ? null : loop;
    if (next == _abLoop) return;
    _abLoop = next;
    notifyListeners();
    await _backend?.setAbLoop(next?.a, next?.b);
  }

  /// 换曲目时关掉循环（后端的循环点跨文件保留，必须显式清）。
  void _dropAbLoopForTrackChange() {
    if (_abLoop == null) return;
    _abLoop = null;
    unawaited(_backend?.setAbLoop(null, null));
  }

  MusicOutputSettings get currentSettings => _baseSettings().copyWith(
    gapless: _gaplessEnabled(),
    replayGain: musicReplayGainModeFor(
      enabled: _replayGainEnabled(),
      context: _context,
      shuffled: _shuffled,
    ),
  );

  /// 当前 → 下一首这一处衔接是否交叉淡入（设计 §7.2）：设置开了、没有「播完本曲停」、
  /// 而且是真边界（专辑连续 / CUE 拆轨默认不淡入，见 [musicTransitionCrossfades]）。
  /// 独占等输出侧的停用由后端判（[musicCrossfadeAvailability]）。
  bool get crossfadeToNext {
    final MusicPlayItem? from = current;
    final MusicPlayItem? to = next;
    if (from == null || to == null || _stopAfterCurrent) return false;
    final MusicOutputSettings s = _baseSettings();
    if (s.crossfade <= Duration.zero) return false;
    return musicTransitionCrossfades(
      from,
      to,
      albumOrder: _context == MusicQueueContext.album && !_shuffled,
      includeContinuous: s.crossfadeContinuous,
    );
  }

  /// 最近一次发给后端的 [crossfadeToNext]（设置变了才重发「下一首」）。
  bool _sentCrossfadeNext = false;

  Future<void> _sendNext(MusicOutputBackend backend) {
    final bool crossfade = crossfadeToNext;
    _sentCrossfadeNext = crossfade;
    return backend.replaceNext(
      _stopAfterCurrent ? null : next,
      crossfadeNext: crossfade,
    );
  }

  /// 正在播放时读信号路径（面板）；没在播为 null。
  Future<MusicSignalPathSnapshot?> readSignalPath() async =>
      _backend?.readSignalPath();

  /// 可选输出设备。没在播时临时建一个后端读完即释放。
  Future<List<MusicAudioDevice>> listAudioDevices() async {
    final MusicOutputBackend? existing = _backend;
    if (existing != null) return existing.listAudioDevices();
    final MusicOutputBackend temp = _backendFactory();
    try {
      return await temp.listAudioDevices();
    } finally {
      await temp.dispose();
    }
  }

  MusicOutputBackend _ensureBackend() {
    final MusicOutputBackend? existing = _backend;
    if (existing != null) return existing;
    final MusicOutputBackend created = _backendFactory();
    _backend = created;
    _eventSub = created.events.listen(_onBackendEvent);
    return created;
  }

  /// 换一个队列，从 [startIndex] 开始播。
  Future<void> playQueue(
    List<MusicPlayItem> items, {
    int startIndex = 0,
    MusicQueueContext context = MusicQueueContext.mixed,
    bool shuffle = false,
  }) async {
    if (items.isEmpty) return;
    final int start = startIndex.clamp(0, items.length - 1);
    _original = List<MusicPlayItem>.of(items);
    _context = context;
    _shuffled = shuffle;
    if (shuffle) {
      // 选中的那首排第一，其余打乱。
      final MusicPlayItem first = items[start];
      final List<MusicPlayItem> rest = List<MusicPlayItem>.of(items)
        ..removeAt(start)
        ..shuffle(_random);
      _queue = <MusicPlayItem>[first, ...rest];
      _index = 0;
    } else {
      _queue = List<MusicPlayItem>.of(items);
      _index = start;
    }
    await _openCurrent(play: true);
  }

  Future<void> _openCurrent({required bool play}) async {
    final MusicPlayItem? item = current;
    if (item == null) return;
    final MusicOutputBackend backend = _ensureBackend();
    _dropAbLoopForTrackChange();
    _position = Duration.zero;
    _duration = item.durationMs == null
        ? null
        : Duration(milliseconds: item.durationMs!);
    _lastError = null;
    _ended = false;
    if (play) onWillPlay?.call();
    await backend.applySettings(currentSettings);
    final bool crossfade = crossfadeToNext;
    _sentCrossfadeNext = crossfade;
    await backend.openPair(
      item,
      _stopAfterCurrent ? null : next,
      play: play,
      crossfadeNext: crossfade,
    );
    if (play) {
      _playing = true;
      onTrackStarted?.call(item);
    }
    notifyListeners();
  }

  Future<void> togglePlayPause() => _playing ? pause() : play();

  Future<void> play() async {
    final MusicOutputBackend? backend = _backend;
    if (backend == null || current == null) return;
    if (_ended) {
      // 队列播完后后端已卸载文件、交还设备：从当前曲目开头重开。
      await _openCurrent(play: true);
      return;
    }
    onWillPlay?.call();
    await backend.play();
    _playing = true;
    notifyListeners();
  }

  Future<void> pause() async {
    final MusicOutputBackend? backend = _backend;
    if (backend == null) return;
    await backend.pause();
    _playing = false;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    final MusicOutputBackend? backend = _backend;
    if (backend == null || current == null) return;
    final Duration clamped = position < Duration.zero
        ? Duration.zero
        : (_duration != null && position > _duration! ? _duration! : position);
    if (_ended) await _openCurrent(play: false);
    await backend.seek(clamped);
    _position = clamped;
    notifyListeners();
  }

  Future<void> seekRelative(Duration delta) => seek(_position + delta);

  /// 播完本曲停（再调一次取消）。
  Future<void> setStopAfterCurrent(bool value) async {
    if (_stopAfterCurrent == value) return;
    _stopAfterCurrent = value;
    if (!value) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      _sleepDeadline = null;
    }
    notifyListeners();
    // 后端不再预排下一首，当前曲目播完即 Completed；取消时把下一首补回去。
    final MusicOutputBackend? backend = _backend;
    if (backend != null) await _sendNext(backend);
  }

  /// 睡眠定时：[after] 之后播完当时正在放的那首停；null 取消。
  void setSleepTimer(Duration? after) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    if (after == null) {
      unawaited(setStopAfterCurrent(false));
      return;
    }
    _sleepDeadline = DateTime.now().add(after);
    _sleepTimer = Timer(after, () {
      _sleepTimer = null;
      unawaited(setStopAfterCurrent(true));
    });
    notifyListeners();
  }

  Future<void> skipNext() async {
    if (_index + 1 >= _queue.length) return;
    _index++;
    await _openCurrent(play: true);
  }

  Future<void> skipPrevious() async {
    if (current == null) return;
    if (!musicPreviousGoesBack(_position) || _index == 0) {
      await seek(Duration.zero);
      return;
    }
    _index--;
    await _openCurrent(play: true);
  }

  /// 跳到队列第 [i] 首。
  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    await _openCurrent(play: true);
  }

  /// 开 / 关随机：保持当前曲目不变、不中断，只重排它之后的队列并更新预排的下一首。
  Future<void> setShuffle(bool shuffle) async {
    if (shuffle == _shuffled) return;
    final MusicPlayItem? playing = current;
    _shuffled = shuffle;
    if (playing == null) {
      notifyListeners();
      return;
    }
    if (shuffle) {
      final List<MusicPlayItem> rest = List<MusicPlayItem>.of(_original)
        ..remove(playing)
        ..shuffle(_random);
      _queue = <MusicPlayItem>[playing, ...rest];
      _index = 0;
    } else {
      _queue = List<MusicPlayItem>.of(_original);
      _index = _queue.indexOf(playing);
    }
    final MusicOutputBackend? backend = _backend;
    if (backend != null) {
      await backend.applySettings(currentSettings);
      await _sendNext(backend);
    }
    notifyListeners();
  }

  /// 停止并清空队列（释放后端：音乐不在播时不占一个 mpv 实例）。
  Future<void> stop() async {
    final MusicOutputBackend? backend = _backend;
    _backend = null;
    await _eventSub?.cancel();
    _eventSub = null;
    _queue = const <MusicPlayItem>[];
    _original = const <MusicPlayItem>[];
    _index = -1;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    _stopAfterCurrent = false;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _abLoop = null;
    notifyListeners();
    if (backend != null) {
      await backend.stop();
      await backend.dispose();
    }
  }

  /// 输出设置变了（设置页切无缝 / ReplayGain）：立刻下发给在用的后端。
  Future<void> reapplySettings() async {
    _lastOutputFallback = null;
    final MusicOutputBackend? backend = _backend;
    if (backend != null) {
      await backend.applySettings(currentSettings);
      // 交叉淡入开关 / 「连续曲目也淡入」变了：这一处衔接的方式跟着变（还来得及的话）。
      if (!_ended && current != null && crossfadeToNext != _sentCrossfadeNext) {
        await _sendNext(backend);
      }
    }
    notifyListeners();
  }

  void _onBackendEvent(MusicBackendEvent event) {
    switch (event) {
      case MusicBackendPosition(
        :final Duration position,
        :final Duration? duration,
      ):
        _position = position;
        if (duration != null && duration > Duration.zero) _duration = duration;
        notifyListeners();
      case MusicBackendPlaying(:final bool playing):
        if (_playing == playing) return;
        _playing = playing;
        notifyListeners();
      case MusicBackendAdvanced(:final String? trackUid):
        // 后端已经无缝切到我们预排的下一首（以实际出声为准）：推进队列、补新的下一首。
        // 后端报了曲目就按曲目对位（切换期内队列可能被重排过）。
        final int found = trackUid == null
            ? -1
            : _queue.indexWhere((MusicPlayItem i) => i.trackUid == trackUid);
        if (found >= 0) {
          _index = found;
        } else if (_index + 1 < _queue.length) {
          _index++;
        }
        final MusicPlayItem? item = current;
        _dropAbLoopForTrackChange();
        _position = Duration.zero;
        _duration = item?.durationMs == null
            ? null
            : Duration(milliseconds: item!.durationMs!);
        if (item != null) onTrackStarted?.call(item);
        notifyListeners();
        final MusicOutputBackend? backend = _backend;
        if (backend != null) unawaited(_sendNext(backend));
      case MusicBackendCompleted():
        // 后端播完即卸载文件、交还设备（独占不再占着）；再按播放由 [play] 重开。
        _playing = false;
        _ended = true;
        if (_stopAfterCurrent) {
          // 睡眠定时到点：指到下一首开头，用户再按播放从下一首接着听。
          _stopAfterCurrent = false;
          _sleepDeadline = null;
          if (_index + 1 < _queue.length) {
            _index++;
            final MusicPlayItem? item = current;
            _position = Duration.zero;
            _duration = item?.durationMs == null
                ? null
                : Duration(milliseconds: item!.durationMs!);
          }
        }
        notifyListeners();
      case MusicBackendOutputFallback():
        _lastOutputFallback = event;
        onOutputFallback?.call(event);
        notifyListeners();
      case MusicBackendFailed(:final String message):
        _lastError = message;
        _playing = false;
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    final MusicOutputBackend? backend = _backend;
    _backend = null;
    unawaited(_eventSub?.cancel());
    if (backend != null) unawaited(backend.dispose());
    super.dispose();
  }
}
