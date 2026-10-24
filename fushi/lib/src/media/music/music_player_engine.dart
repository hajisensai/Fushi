/// 音乐播放编排（设计 §7.2）：队列在 Dart，向输出后端只维持「当前 + 下一首」两项；
/// 后端无缝切到下一首时，引擎推进队列并把新的「下一首」补给后端。ReplayGain 按播放
/// 语境选：整张专辑顺序播 = album，随机 / 混排 = track。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';

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

/// 构造输出后端的工厂（真 app 给 libmpv，测试给替身）。
typedef MusicOutputBackendFactory = MusicOutputBackend Function();

class MusicPlayerEngine extends ChangeNotifier {
  MusicPlayerEngine({
    required MusicOutputBackendFactory backendFactory,
    bool Function()? gaplessEnabled,
    bool Function()? replayGainEnabled,
    Random? random,
  }) : _backendFactory = backendFactory,
       _gaplessEnabled = gaplessEnabled ?? (() => true),
       _replayGainEnabled = replayGainEnabled ?? (() => true),
       _random = random ?? Random();

  final MusicOutputBackendFactory _backendFactory;
  final bool Function() _gaplessEnabled;
  final bool Function() _replayGainEnabled;
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

  MusicOutputSettings get currentSettings => MusicOutputSettings(
    gapless: _gaplessEnabled(),
    replayGain: musicReplayGainModeFor(
      enabled: _replayGainEnabled(),
      context: _context,
      shuffled: _shuffled,
    ),
  );

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
    _position = Duration.zero;
    _duration = item.durationMs == null
        ? null
        : Duration(milliseconds: item.durationMs!);
    _lastError = null;
    if (play) onWillPlay?.call();
    await backend.applySettings(currentSettings);
    await backend.openPair(item, next, play: play);
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
    await backend.seek(clamped);
    _position = clamped;
    notifyListeners();
  }

  Future<void> seekRelative(Duration delta) => seek(_position + delta);

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
      await backend.replaceNext(next);
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
    notifyListeners();
    if (backend != null) {
      await backend.stop();
      await backend.dispose();
    }
  }

  /// 输出设置变了（设置页切无缝 / ReplayGain）：立刻下发给在用的后端。
  Future<void> reapplySettings() async {
    await _backend?.applySettings(currentSettings);
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
      case MusicBackendAdvanced():
        // 后端已经无缝切到我们预排的下一首：推进队列、补新的下一首。
        if (_index + 1 < _queue.length) _index++;
        final MusicPlayItem? item = current;
        _position = Duration.zero;
        _duration = item?.durationMs == null
            ? null
            : Duration(milliseconds: item!.durationMs!);
        if (item != null) onTrackStarted?.call(item);
        notifyListeners();
        unawaited(_backend?.replaceNext(next));
      case MusicBackendCompleted():
        _playing = false;
        notifyListeners();
      case MusicBackendFailed(:final String message):
        _lastError = message;
        _playing = false;
        notifyListeners();
    }
  }

  @override
  void dispose() {
    final MusicOutputBackend? backend = _backend;
    _backend = null;
    unawaited(_eventSub?.cancel());
    if (backend != null) unawaited(backend.dispose());
    super.dispose();
  }
}
