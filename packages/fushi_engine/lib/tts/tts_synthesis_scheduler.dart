/// 按播放位置调度逐句合成：当前句 + 往后 [lookahead] 句预取，播放器要哪句就先合成哪句。
///
/// 失败策略（不靠重试掩盖）：任一句失败 → 调度整体停下并报 [failure]，等待中的请求
/// **保持挂起**（播放器表现为缓冲中，而不是跳到下一句）；调用方提示用户后 [resume]
/// 重新合成。被取消的请求（换位置移出窗口 / 关闭）以 [TtsFailureCode.cancelled]
/// 结束，不算失败。
library;

import 'dart:async';

import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 一句合成好了 / 失败了。
sealed class TtsSegmentEvent {
  const TtsSegmentEvent(this.index);
  final int index;
}

class TtsSegmentReady extends TtsSegmentEvent {
  const TtsSegmentReady(super.index, this.audio);
  final TtsCachedAudio audio;
}

class TtsSegmentFailed extends TtsSegmentEvent {
  const TtsSegmentFailed(super.index, this.failure);
  final TtsFailure failure;
}

class TtsSynthesisScheduler {
  TtsSynthesisScheduler({
    required TtsProvider provider,
    required TtsAudioCache cache,
    required List<String> texts,
    required Map<String, Object?> audioIdentity,
    int lookahead = 3,
    this.keepPinned = 8,
    int? concurrency,
  }) : _provider = provider,
       _cache = cache,
       _texts = texts,
       _keys = <String>[
         for (final String text in texts)
           TtsAudioCache.keyFor(audioIdentity, text),
       ],
       _lookahead = lookahead,
       _concurrency = concurrency ?? provider.capabilities.maxConcurrency;

  final TtsProvider _provider;
  final TtsAudioCache _cache;
  final List<String> _texts;
  final List<String> _keys;
  final int _concurrency;
  int _lookahead;

  /// 往后预取多少句。倍速播放时由调用方调大（消耗得快，缓冲要按播放时长而不是句数算）。
  int get lookahead => _lookahead;

  void setLookahead(int value) {
    final int next = value < 1 ? 1 : value;
    if (next == _lookahead) return;
    _lookahead = next;
    _pump();
  }

  /// 当前句前后多少句的音频保持 pin（播放器可能还开着、或马上要回听）。
  final int keepPinned;

  final Map<int, TtsCachedAudio> _ready = <int, TtsCachedAudio>{};
  final Map<int, Completer<TtsCachedAudio>> _waiters =
      <int, Completer<TtsCachedAudio>>{};
  final Map<int, TtsCancelToken> _inFlight = <int, TtsCancelToken>{};

  /// 每一路合成的整条收尾（含写缓存）。[dispose] 取消后等它们全部落定，之后才
  /// 允许调用方释放引擎 / 清缓存目录：引擎不一定能立刻中止（系统 TTS 的整句合成、
  /// 已经在写盘的结果），关掉之后还在后台写文件会撞上删目录 / 换引擎。
  final Set<Future<void>> _running = <Future<void>>{};
  final Set<int> _demanded = <int>{};
  final Set<int> _pinned = <int>{};
  final StreamController<TtsSegmentEvent> _events =
      StreamController<TtsSegmentEvent>.broadcast();

  int _cursor = 0;
  TtsFailure? _failure;
  int? _failedIndex;
  bool _disposed = false;

  int get length => _texts.length;
  int get cursor => _cursor;
  Stream<TtsSegmentEvent> get events => _events.stream;

  /// 调度因失败而停下（非 null 时不再发起新合成）。
  TtsFailure? get failure => _failure;
  int? get failedIndex => _failedIndex;

  String keyOf(int index) => _keys[index];

  /// 这一句音频（合成后）所在的固定路径。
  String audioPathOf(int index) => _cache.audioPathFor(_keys[index]);
  TtsCachedAudio? readyAudio(int index) => _ready[index];
  bool isInFlight(int index) => _inFlight.containsKey(index);

  /// 播放器要这一句的音频：已就绪立即返回，否则优先合成并等待。
  Future<TtsCachedAudio> ensure(int index) {
    if (_disposed) {
      return Future<TtsCachedAudio>.error(
        const TtsFailure(TtsFailureCode.cancelled),
      );
    }
    final TtsCachedAudio? ready = _ready[index];
    if (ready != null) return Future<TtsCachedAudio>.value(ready);
    _demanded.add(index);
    final Future<TtsCachedAudio> future = _waiters
        .putIfAbsent(index, Completer<TtsCachedAudio>.new)
        .future;
    _pump();
    return future;
  }

  /// 播放位置移动：调整预取窗口，取消窗口外的在途合成，释放远处的 pin。
  ///
  /// 窗口外的等待者以「已取消」结束：游标跟着播放器走，播放器已经离开那一句，
  /// 它对旧句的 `request()` 不会再有人消费；不结束的话每次拖远都留一个挂到
  /// [dispose] 的 Future（连同 just_audio 本机代理里那条请求）。之后真有人再要
  /// 那一句，[ensure] 会重新登记、重新合成。
  void setCursor(int index) {
    if (_disposed) return;
    _cursor = index.clamp(0, _texts.isEmpty ? 0 : _texts.length - 1);
    _demanded.removeWhere((int i) => !_inWindow(i, slack: 1));
    for (final int i in _waiters.keys.toList()) {
      if (_inWindow(i, slack: 1)) continue;
      final Completer<TtsCachedAudio> waiter = _waiters.remove(i)!;
      if (!waiter.isCompleted) {
        waiter.completeError(const TtsFailure(TtsFailureCode.cancelled));
      }
    }
    for (final MapEntry<int, TtsCancelToken> e in _inFlight.entries.toList()) {
      if (!_demanded.contains(e.key) && !_inWindow(e.key, slack: 1)) {
        e.value.cancel();
      }
    }
    for (final int i in _pinned.toList()) {
      if ((i - _cursor).abs() > keepPinned + lookahead) {
        _pinned.remove(i);
        _cache.unpin(_keys[i]);
        _ready.remove(i);
      }
    }
    _pump();
  }

  /// 用户确认后从失败处继续。
  void resume() {
    if (_disposed || _failure == null) return;
    _failure = null;
    _failedIndex = null;
    _pump();
  }

  bool _inWindow(int index, {int slack = 0}) =>
      index >= _cursor - slack && index <= _cursor + lookahead + slack;

  int? _nextIndex() {
    int? best;
    for (final int i in _demanded) {
      if (_ready.containsKey(i) || _inFlight.containsKey(i)) continue;
      if (best == null || (i - _cursor).abs() < (best - _cursor).abs()) {
        best = i;
      }
    }
    if (best != null) return best;
    for (int i = _cursor; i <= _cursor + lookahead && i < _texts.length; i++) {
      if (!_ready.containsKey(i) && !_inFlight.containsKey(i)) return i;
    }
    return null;
  }

  void _pump() {
    if (_disposed || _failure != null) return;
    while (_inFlight.length < _concurrency) {
      final int? index = _nextIndex();
      if (index == null) return;
      final Future<void> run = _run(index);
      _running.add(run);
      unawaited(run.whenComplete(() => _running.remove(run)));
    }
  }

  Future<void> _run(int index) async {
    final TtsCancelToken token = TtsCancelToken();
    _inFlight[index] = token;
    try {
      final TtsCachedAudio audio = await _cache.obtain(
        _keys[index],
        (String outputPath) => _provider.synthesize(
          _texts[index],
          outputPath: outputPath,
          cancel: token,
        ),
      );
      if (_disposed) return;
      if (token.isCancelled && !_demanded.contains(index)) return;
      _ready[index] = audio;
      if (_pinned.add(index)) _cache.pin(_keys[index]);
      _demanded.remove(index);
      _waiters.remove(index)?.complete(audio);
      _events.add(TtsSegmentReady(index, audio));
    } on TtsFailure catch (failure) {
      if (_disposed || failure.code == TtsFailureCode.cancelled) return;
      _failure ??= failure;
      _failedIndex ??= index;
      _events.add(TtsSegmentFailed(index, failure));
    } catch (error) {
      if (_disposed) return;
      final TtsFailure failure = TtsFailure(
        TtsFailureCode.badResponse,
        error.runtimeType.toString(),
      );
      _failure ??= failure;
      _failedIndex ??= index;
      _events.add(TtsSegmentFailed(index, failure));
    } finally {
      if (identical(_inFlight[index], token)) _inFlight.remove(index);
      _pump();
    }
  }

  /// 停止调度：取消在途合成、让等待者以「已取消」失败、解除 pin，并**等在途合成
  /// 全部收尾**后才返回（返回后本调度器不会再向缓存目录写任何东西，引擎可以释放）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final TtsCancelToken token in _inFlight.values) {
      token.cancel();
    }
    _inFlight.clear();
    for (final Completer<TtsCachedAudio> waiter in _waiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(const TtsFailure(TtsFailureCode.cancelled));
      }
    }
    _waiters.clear();
    for (final int i in _pinned) {
      _cache.unpin(_keys[i]);
    }
    _pinned.clear();
    await Future.wait(_running.toList());
    await _events.close();
  }
}
