/// 按播放位置调度逐句合成：当前句 + 往后 [lookahead] 句预取，播放器要哪句就先合成哪句。
///
/// 失败策略：
/// - **临时失败先有限次重试**（`ttsWithRetry`，全部引擎共用一处）：在线语音跑在
///   第三方服务与用户网络上，偶发的断连 / 超时 / 429 / 5xx 是外部系统常态、本机
///   无法消除；零重试时一本书几千个请求里任一次抖动都会让朗读停下（BUG：微软、
///   谷歌语音「经常会断」）。只重试可判定为临时的失败，次数有上限，用尽后照常按
///   下面的规则上报——不吞失败、不跳句。影响范围：仅单句合成请求；清理条件见
///   `tts_retry.dart`。
/// - **播放器要的句子（[ensure] 登记过）失败** → 调度整体停下并报 [failure]，等待
///   中的请求**保持挂起**（播放器表现为缓冲中，而不是跳到下一句）；调用方提示用户后
///   [resume] 重新合成。事件里 [TtsSegmentFailed.blocking] 为真。
/// - **后台预取的句子失败**（播放器还没要它）不打断播放：记下这一句、暂停继续往后
///   预取（避免断网 / 限流时把整个窗口打一遍），播放器要的句子照常合成；任一句合成
///   成功、播放前进到别的句子或 [resume] 即恢复预取（失败句本身仍跳过）。等播放器
///   真要到失败句时 [ensure] 重新请求它，再失败才按上一条停下——失败句不会被静默
///   跳过。事件里 [TtsSegmentFailed.blocking] 为假。
/// - 被取消的请求（换位置移出窗口 / 关闭）以 [TtsFailureCode.cancelled] 结束，不算
///   失败。
library;

import 'dart:async';

import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
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
  const TtsSegmentFailed(super.index, this.failure, {this.blocking = true});
  final TtsFailure failure;

  /// 这一句是播放器要的（调度已停在它上面，[TtsSynthesisScheduler.failure] 非空）。
  /// 为假 = 后台预取失败，播放不受影响，播放器要到它时会重新请求。
  final bool blocking;
}

/// 一份声音：合成实例 + 进缓存键的音色身份 + 同时在途的请求上限。
///
/// 多声优朗读时一本书用好几份声音，每句指定一份（[TtsSynthesisScheduler.voices]）；
/// 并发按声音分别计（同一份预设共用一个上限，与制作台同口径），不同声音互不占名额。
class TtsSchedulerVoice {
  const TtsSchedulerVoice({
    required this.provider,
    required this.audioIdentity,
    required this.concurrency,
  }) : assert(concurrency > 0);

  final TtsProvider provider;
  final Map<String, Object?> audioIdentity;
  final int concurrency;
}

class TtsSynthesisScheduler {
  /// 单声音：全部句子用 [provider]。
  factory TtsSynthesisScheduler({
    required TtsProvider provider,
    required TtsAudioCache cache,
    required List<String> texts,
    required Map<String, Object?> audioIdentity,
    int lookahead = 3,
    int keepPinned = 8,
    int? concurrency,
    TtsRetryPolicy retryPolicy = const TtsRetryPolicy(),
  }) => TtsSynthesisScheduler.voices(
    voices: <TtsSchedulerVoice>[
      TtsSchedulerVoice(
        provider: provider,
        audioIdentity: audioIdentity,
        concurrency: concurrency ?? provider.capabilities.maxConcurrency,
      ),
    ],
    voiceOf: List<int>.filled(texts.length, 0),
    cache: cache,
    texts: texts,
    lookahead: lookahead,
    keepPinned: keepPinned,
    retryPolicy: retryPolicy,
  );

  /// 多声音：第 i 句用 `voices[voiceOf[i]]`。
  TtsSynthesisScheduler.voices({
    required List<TtsSchedulerVoice> voices,
    required List<int> voiceOf,
    required TtsAudioCache cache,
    required List<String> texts,
    int lookahead = 3,
    this.keepPinned = 8,
    TtsRetryPolicy retryPolicy = const TtsRetryPolicy(),
  }) : assert(voices.isNotEmpty),
       assert(voiceOf.length == texts.length),
       _voices = List<TtsSchedulerVoice>.unmodifiable(voices),
       _voiceOf = List<int>.unmodifiable(voiceOf),
       _voiceInFlight = List<int>.filled(voices.length, 0),
       _retryPolicy = retryPolicy,
       _cache = cache,
       _texts = texts,
       _keys = <String>[
         for (int i = 0; i < texts.length; i++)
           TtsAudioCache.keyFor(voices[voiceOf[i]].audioIdentity, texts[i]),
       ],
       _lookahead = lookahead;

  final List<TtsSchedulerVoice> _voices;
  final List<int> _voiceOf;

  /// 每份声音当前在途的请求数（按 [TtsSchedulerVoice.concurrency] 限流）。
  final List<int> _voiceInFlight;
  final TtsRetryPolicy _retryPolicy;
  final TtsAudioCache _cache;
  final List<String> _texts;
  final List<String> _keys;
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

  /// 后台预取失败、播放器还没要过的句子（预取跳过它们；[ensure] 时重新请求）。
  final Map<int, TtsFailure> _prefetchFailed = <int, TtsFailure>{};

  /// 有预取失败后暂停继续往后预取，直到任一句合成成功 / [resume] / 换位置。
  bool _prefetchHeld = false;

  int _cursor = 0;
  TtsFailure? _failure;
  int? _failedIndex;
  bool _disposed = false;

  int get length => _texts.length;

  /// 第 [index] 句用哪份声音（[TtsSchedulerVoice] 下标）。
  int voiceIndexOf(int index) => _voiceOf[index];
  int get cursor => _cursor;
  Stream<TtsSegmentEvent> get events => _events.stream;

  /// 调度因失败而停下（非 null 时不再发起新合成）。
  TtsFailure? get failure => _failure;
  int? get failedIndex => _failedIndex;

  /// 这一句后台预取失败过、尚未被重新请求。
  bool prefetchFailed(int index) => _prefetchFailed.containsKey(index);

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
    // 预取失败过的句子：播放器真的要到它了，重新请求（再失败才停下提示）。
    _prefetchFailed.remove(index);
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
    // 窗口外的预取失败记录作废：之后回到那里按新请求重来。换了位置也解除预取暂停。
    _prefetchFailed.removeWhere(
      (int i, TtsFailure _) => !_inWindow(i, slack: 1),
    );
    _prefetchHeld = false;
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
    _prefetchFailed.clear();
    _prefetchHeld = false;
    _pump();
  }

  bool _inWindow(int index, {int slack = 0}) =>
      index >= _cursor - slack && index <= _cursor + lookahead + slack;

  int? _nextIndex() {
    int? best;
    for (final int i in _demanded) {
      if (_ready.containsKey(i) || _inFlight.containsKey(i)) continue;
      if (!_voiceHasRoom(i)) continue;
      if (best == null || (i - _cursor).abs() < (best - _cursor).abs()) {
        best = i;
      }
    }
    if (best != null) return best;
    if (_prefetchHeld) return null;
    for (int i = _cursor; i <= _cursor + lookahead && i < _texts.length; i++) {
      if (_ready.containsKey(i) ||
          _inFlight.containsKey(i) ||
          _prefetchFailed.containsKey(i) ||
          !_voiceHasRoom(i)) {
        continue;
      }
      return i;
    }
    return null;
  }

  bool _voiceHasRoom(int index) {
    final int v = _voiceOf[index];
    return _voiceInFlight[v] < _voices[v].concurrency;
  }

  void _pump() {
    if (_disposed || _failure != null) return;
    while (true) {
      final int? index = _nextIndex();
      if (index == null) return;
      final Future<void> run = _run(index);
      _running.add(run);
      unawaited(run.whenComplete(() => _running.remove(run)));
    }
  }

  Future<void> _run(int index) async {
    final TtsCancelToken token = TtsCancelToken();
    final int voice = _voiceOf[index];
    _inFlight[index] = token;
    _voiceInFlight[voice]++;
    try {
      // 每次尝试走一遍缓存的「写 .part → 校验 → 发布」，失败的半成品由缓存清掉。
      final TtsCachedAudio audio = await ttsWithRetry(
        () => _cache.obtain(
          _keys[index],
          (String outputPath) => _voices[voice].provider.synthesize(
            _texts[index],
            outputPath: outputPath,
            cancel: token,
          ),
        ),
        cancel: token,
        policy: _retryPolicy,
      );
      if (_disposed) return;
      if (token.isCancelled && !_demanded.contains(index)) return;
      _ready[index] = audio;
      _prefetchHeld = false;
      if (_pinned.add(index)) _cache.pin(_keys[index]);
      _demanded.remove(index);
      _waiters.remove(index)?.complete(audio);
      _events.add(TtsSegmentReady(index, audio));
    } on TtsFailure catch (failure) {
      if (_disposed || failure.code == TtsFailureCode.cancelled) return;
      _recordFailure(index, failure);
    } catch (error) {
      if (_disposed) return;
      _recordFailure(
        index,
        TtsFailure(TtsFailureCode.badResponse, error.runtimeType.toString()),
      );
    } finally {
      _voiceInFlight[voice]--;
      if (identical(_inFlight[index], token)) _inFlight.remove(index);
      _pump();
    }
  }

  void _recordFailure(int index, TtsFailure failure) {
    if (_demanded.contains(index)) {
      _failure ??= failure;
      _failedIndex ??= index;
      _events.add(TtsSegmentFailed(index, failure));
      return;
    }
    _prefetchFailed[index] = failure;
    _prefetchHeld = true;
    _events.add(TtsSegmentFailed(index, failure, blocking: false));
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
