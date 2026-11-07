/// 漫画朗读的编排：按页、按阅读顺序逐句合成并播放，读到哪句高亮哪句，读完
/// 当前 spread 由宿主翻页，读到章末停下。
///
/// 宿主（阅读器页面）只提供「这页的文字」「显示这一句」两类能力
/// （[MangaReadAloudHost]）；合成走 [MangaReadAloudVoiceRig]（生产 = 当前朗读声音 +
/// 全应用共用的 `TtsAudioCache`），播放走注入的 [MangaReadAloudPlayToEnd]（生产 =
/// `DesktopAudioPlayback`）。
///
/// 关键约定：
/// - **每页一个调度器**：`TtsSynthesisScheduler` 的文本在构造时固定，而 OCR 逐页
///   到达，所以只保留「当前页 + 下一页」两个调度器，其余一律释放。缓存键只由
///   「声音身份 + 文本」决定，换调度器不丢已合成的音频。
/// - **中断判定**：`playToEnd` 返回 false 有三种来源——外部播放打断（查词发音等）、
///   本控制器自己 stop、切句 / 跳页。本控制器每次自己打断前先递增
///   [_playGeneration]；返回 false 时只有代数没变才算外部打断（转 [paused]，不前进）。
/// - **自己翻页 vs 用户翻页**：[MangaReadAloudHost.show] 前记下 [_expectedPage]；
///   页变化回调里落在同一 spread 的忽略，否则重新定位到新页第一句。
/// - **全局播放器只在自己持有时才 stop**：`DesktopAudioPlayback.stop` 是全局的，
///   没在播自己的句子时不去掐别人的发音。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/src/media/manga/reader/manga_read_aloud_plan.dart';

enum MangaReadAloudState {
  /// 没在朗读（未开始 / 已停止）。
  idle,

  /// 等这页的文字（OCR 中）。
  preparingText,

  /// 等这句的音频合成。
  synthesizing,
  playing,

  /// 用户暂停或被外部播放打断；继续时从当前句开头重读。
  paused,

  /// 读到章末（或整章没有可读的文字）。
  finished,

  /// 阻塞性失败（文字拿不到 / 合成失败），停在当前句等重试。
  failed,
}

/// 一页文字拿不到的原因。
enum MangaPageTextUnavailableReason {
  /// 没有可用的 OCR 引擎。
  noEngine,

  /// 用户拒绝了 Google Lens 上传。
  lensDeclined,

  /// 本章不能识别（未下载）。
  chapterOcrDisabled,

  /// 识别任务被取消 / 页面已离开。
  cancelled,

  /// 识别失败。
  failed,
}

/// [MangaReadAloudHost.ensurePageText] 的结果。
sealed class MangaPageTextResult {
  const MangaPageTextResult();
}

final class MangaPageTextReady extends MangaPageTextResult {
  const MangaPageTextReady(this.page);
  final MokuroImage page;
}

final class MangaPageTextUnavailable extends MangaPageTextResult {
  const MangaPageTextUnavailable(this.reason);
  final MangaPageTextUnavailableReason reason;
}

/// [MangaReadAloudState.failed] 的原因。
sealed class MangaReadAloudProblem {
  const MangaReadAloudProblem();
}

final class MangaReadAloudTextProblem extends MangaReadAloudProblem {
  const MangaReadAloudTextProblem(this.reason);
  final MangaPageTextUnavailableReason reason;
}

final class MangaReadAloudSynthesisProblem extends MangaReadAloudProblem {
  const MangaReadAloudSynthesisProblem(this.failure);
  final TtsFailure failure;
}

/// [MangaReadAloudState.finished] 的原因。
enum MangaReadAloudFinish {
  /// 读到章末。
  chapterEnd,

  /// 从起点到章末没有一句可读。
  noText,
}

/// 阅读器页面为朗读提供的能力。
abstract interface class MangaReadAloudHost {
  int get pageCount;

  /// 本卷翻页方向是否右到左（决定一页内的阅读顺序）。
  bool get rightToLeft;

  /// 读者当前看到的页（0-based；spread 取首页）。
  int get visiblePage;

  /// [a] 与 [b] 是否同屏（同一个 spread；webtoon 下只有同一页）。
  bool isSameSpread(int a, int b);

  /// 这一页的 OCR 文字；还没识别就触发识别并等它（不设超时：本地模型一页几十秒
  /// 是常态）。拿不到时返回 [MangaPageTextUnavailable]，不抛。
  Future<MangaPageTextResult> ensurePageText(int pageIndex);

  /// 高亮第 [pageIndex] 页的句子分组 [group]；不在当前屏时先翻过去。
  Future<void> show(int pageIndex, int group);

  Future<void> clearHighlight();

  /// 朗读中用户不操作也在学习：每开始读一句喂一次学习时钟的空闲门。
  void markStudyActivity();
}

/// 一份朗读声音：引擎单次输入上限 + 按文本建调度器。
abstract interface class MangaReadAloudVoiceRig {
  int get maxInputLength;
  TtsSynthesisScheduler createScheduler(List<String> texts);

  /// 释放引擎。调用前它建出的调度器都已 dispose 完毕。
  Future<void> dispose();
}

/// 播放到结束：true = 自然播完，false = 没开播 / 被打断。
typedef MangaReadAloudPlayToEnd =
    Future<bool> Function(String path, double speed);

typedef MangaReadAloudStopPlayback = Future<void> Function();

/// 一页的朗读计划 + 它的调度器（全页文本按句展平，句 i 的块从 [chunkStart][i] 起）。
class _PagePlan {
  _PagePlan({
    required this.page,
    required this.utterances,
    required this.scheduler,
    required this.chunkStart,
  });

  final int page;
  final List<MangaReadAloudUtterance> utterances;
  final TtsSynthesisScheduler? scheduler;
  final List<int> chunkStart;
}

enum _SpeakOutcome { done, interrupted, aborted, failed }

class MangaReadAloudController extends ChangeNotifier {
  MangaReadAloudController({
    required MangaReadAloudHost host,
    required MangaReadAloudVoiceRig rig,
    required List<TtsPronunciationRule> pronunciation,
    required MangaReadAloudPlayToEnd playToEnd,
    required MangaReadAloudStopPlayback stopPlayback,
    required double Function() readSpeed,
    required Future<void> Function(double speed) writeSpeed,
  }) : _host = host,
       _rig = rig,
       _pronunciation = pronunciation,
       _playToEnd = playToEnd,
       _stopPlayback = stopPlayback,
       _readSpeed = readSpeed,
       _writeSpeed = writeSpeed;

  final MangaReadAloudHost _host;
  MangaReadAloudVoiceRig _rig;
  final List<TtsPronunciationRule> _pronunciation;
  final MangaReadAloudPlayToEnd _playToEnd;
  final MangaReadAloudStopPlayback _stopPlayback;
  final double Function() _readSpeed;
  final Future<void> Function(double speed) _writeSpeed;

  /// 「上一句」跨页时的占位：到了那页再换成最后一句的下标。
  static const int _kLastOfPage = -1;

  MangaReadAloudState _state = MangaReadAloudState.idle;
  MangaReadAloudProblem? _problem;
  MangaReadAloudFinish? _finish;
  int _page = 0;
  int _index = 0;

  /// 「上一句」跨页往回找：遇到没有可读句的页继续往前。
  bool _backward = false;
  bool _spokeAny = false;

  /// 本控制器自己发起的打断（stop / 切句 / 跳页 / 暂停）每次 +1。
  int _playGeneration = 0;

  /// [MangaReadAloudHost.show] 前记下的目标页：这一 spread 内的页变化是自己翻的。
  int? _expectedPage;

  /// 全局播放器此刻在播本控制器的句子。
  bool _ownsPlayback = false;

  final Map<int, Future<MangaPageTextResult>> _texts =
      <int, Future<MangaPageTextResult>>{};
  final Map<int, _PagePlan> _plans = <int, _PagePlan>{};
  final Set<Future<void>> _disposing = <Future<void>>{};
  bool _disposed = false;

  MangaReadAloudState get state => _state;
  MangaReadAloudProblem? get problem => _problem;
  MangaReadAloudFinish? get finish => _finish;
  int get page => _page;
  double get speed => _readSpeed();

  /// 正在读（或暂停 / 失败停在）的句子；还没定位到句子时为 null。
  MangaReadAloudUtterance? get currentUtterance {
    final _PagePlan? plan = _plans[_page];
    if (plan == null || _index < 0 || _index >= plan.utterances.length) {
      return null;
    }
    return plan.utterances[_index];
  }

  /// 朗读会话进行中（含暂停 / 失败停住）：播放条要显示。
  bool get isActive =>
      _state != MangaReadAloudState.idle &&
      _state != MangaReadAloudState.finished;

  bool get _running =>
      _state == MangaReadAloudState.preparingText ||
      _state == MangaReadAloudState.synthesizing ||
      _state == MangaReadAloudState.playing;

  bool _alive(int generation) => !_disposed && generation == _playGeneration;

  // ── 公开操作 ────────────────────────────────────────────────────────

  /// 从第 [fromPage] 页第一句开始朗读。
  void start({required int fromPage}) {
    if (_disposed) return;
    _interrupt();
    _page = fromPage.clamp(0, math.max(0, _host.pageCount - 1));
    _index = 0;
    _backward = false;
    _spokeAny = false;
    _finish = null;
    _launch();
  }

  void pause() {
    if (!_running) return;
    _interrupt();
    _setState(MangaReadAloudState.paused);
  }

  /// 继续（从当前句开头重读）；失败态下是「重试」。
  void resume() {
    if (_disposed) return;
    if (_state != MangaReadAloudState.paused &&
        _state != MangaReadAloudState.failed) {
      return;
    }
    _interrupt();
    if (_problem is MangaReadAloudSynthesisProblem) {
      _plans[_page]?.scheduler?.resume();
    }
    _launch();
  }

  void next() {
    if (!isActive) return;
    _interrupt();
    _index = _index < 0 ? 0 : _index + 1;
    _backward = false;
    _launch();
  }

  void previous() {
    if (!isActive) return;
    _interrupt();
    if (_index > 0) {
      _index--;
      _backward = false;
    } else if (_page > 0) {
      _page--;
      _index = _kLastOfPage;
      _backward = true;
    } else {
      _index = 0;
      _backward = false;
    }
    _launch();
  }

  /// 改倍速（写回全局朗读倍速；下一段音频起生效）。
  Future<void> setSpeed(double value) async {
    await _writeSpeed(value);
    for (final _PagePlan plan in _plans.values) {
      plan.scheduler?.setLookahead(_lookahead());
    }
    if (!_disposed) notifyListeners();
  }

  /// 换声音：丢掉旧调度器、用新声音从当前句重读（暂停中则保持暂停）。
  Future<void> replaceRig(MangaReadAloudVoiceRig rig) async {
    if (_disposed) {
      await rig.dispose();
      return;
    }
    final bool wasRunning = _running;
    _interrupt();
    final MangaReadAloudVoiceRig old = _rig;
    _rig = rig;
    _dropPlans(keep: const <int>{});
    final List<Future<void>> pending = _disposing.toList();
    unawaited(Future.wait(pending).then((_) => old.dispose()));
    if (wasRunning) {
      _launch();
    } else {
      notifyListeners();
    }
  }

  void stop() {
    if (_state == MangaReadAloudState.idle) return;
    _interrupt();
    _dropPlans(keep: const <int>{});
    _texts.clear();
    _expectedPage = null;
    _problem = null;
    _finish = null;
    unawaited(_host.clearHighlight());
    _setState(MangaReadAloudState.idle);
  }

  /// 阅读器页变化（自己翻的和用户翻的都会来）。
  void onPageChanged(int page) {
    if (!isActive) return;
    final int? expected = _expectedPage;
    if (expected != null && _host.isSameSpread(page, expected)) return;
    final bool wasRunning = _running;
    _interrupt();
    _page = page.clamp(0, math.max(0, _host.pageCount - 1));
    _index = 0;
    _backward = false;
    _expectedPage = _page;
    unawaited(_host.clearHighlight());
    if (wasRunning) {
      _launch();
    } else {
      _problem = null;
      _setState(MangaReadAloudState.paused);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _interrupt();
    _disposed = true;
    _dropPlans(keep: const <int>{});
    final MangaReadAloudVoiceRig rig = _rig;
    unawaited(Future.wait(_disposing.toList()).then((_) => rig.dispose()));
    super.dispose();
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 本控制器自己的打断：代数 +1（在途的 playToEnd 返回 false 不再算外部打断），
  /// 只有正在播自己的句子时才停全局播放器。
  void _interrupt() {
    _playGeneration++;
    if (_ownsPlayback) {
      _ownsPlayback = false;
      unawaited(_stopPlayback());
    }
  }

  void _launch() {
    _problem = null;
    final int generation = _playGeneration;
    unawaited(_drive(generation));
  }

  void _setState(MangaReadAloudState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  int _lookahead() => math.max(3, (3 * _readSpeed()).ceil());

  Future<void> _drive(int generation) async {
    while (_alive(generation)) {
      if (_page >= _host.pageCount) {
        _finishChapter();
        return;
      }
      if (!_plans.containsKey(_page)) {
        _setState(MangaReadAloudState.preparingText);
      }
      final Object resolved = await _planFor(_page);
      if (!_alive(generation)) return;
      if (resolved is MangaPageTextUnavailableReason) {
        _problem = MangaReadAloudTextProblem(resolved);
        _setState(MangaReadAloudState.failed);
        return;
      }
      final _PagePlan plan = resolved as _PagePlan;
      _dropPlans(keep: <int>{_page, _page + 1});
      if (_index == _kLastOfPage) _index = plan.utterances.length - 1;
      if (plan.utterances.isEmpty || _index >= plan.utterances.length) {
        if (_backward && _page > 0) {
          // 「上一句」往回找：这页没有可读句，继续往前。
          _page--;
          _index = _kLastOfPage;
          continue;
        }
        // 往后读（往回找到第一页都没有可读句时也从这里往后读）。
        _backward = false;
        _page++;
        _index = 0;
        continue;
      }
      _backward = false;
      // 翻到新页就预取下一页：气泡往往只有一两句，等读到页尾再识别就来不及。
      unawaited(_prefetch(_page + 1, generation));
      final MangaReadAloudUtterance utterance = plan.utterances[_index];
      _expectedPage = utterance.pageIndex;
      await _host.show(utterance.pageIndex, utterance.group);
      if (!_alive(generation)) return;
      _host.markStudyActivity();
      final _SpeakOutcome outcome = await _speak(plan, _index, generation);
      switch (outcome) {
        case _SpeakOutcome.aborted:
        case _SpeakOutcome.failed:
          return;
        case _SpeakOutcome.interrupted:
          _setState(MangaReadAloudState.paused);
          return;
        case _SpeakOutcome.done:
          _spokeAny = true;
          _index++;
      }
    }
  }

  void _finishChapter() {
    _expectedPage = null;
    _finish = _spokeAny
        ? MangaReadAloudFinish.chapterEnd
        : MangaReadAloudFinish.noText;
    unawaited(_host.clearHighlight());
    _setState(MangaReadAloudState.finished);
  }

  Future<_SpeakOutcome> _speak(
    _PagePlan plan,
    int index,
    int generation,
  ) async {
    final TtsSynthesisScheduler scheduler = plan.scheduler!;
    final int first = plan.chunkStart[index];
    final int count = plan.utterances[index].spokenChunks.length;
    scheduler.setLookahead(_lookahead());
    scheduler.setCursor(first);
    for (int chunk = first; chunk < first + count; chunk++) {
      final Object audio = await _awaitAudio(scheduler, chunk, generation);
      if (!_alive(generation)) return _SpeakOutcome.aborted;
      if (audio is TtsFailure) {
        _problem = MangaReadAloudSynthesisProblem(audio);
        _setState(MangaReadAloudState.failed);
        return _SpeakOutcome.failed;
      }
      _setState(MangaReadAloudState.playing);
      _ownsPlayback = true;
      final bool finished = await _playToEnd(
        (audio as TtsCachedAudio).path,
        _readSpeed(),
      );
      if (!_alive(generation)) return _SpeakOutcome.aborted;
      _ownsPlayback = false;
      if (!finished) return _SpeakOutcome.interrupted;
    }
    return _SpeakOutcome.done;
  }

  /// 等一块音频：就绪返回 [TtsCachedAudio]；调度器因这块（或此前的阻塞失败）停下
  /// 时返回 [TtsFailure]——调度器的等待者在阻塞失败时保持挂起，只能从事件里得知。
  Future<Object> _awaitAudio(
    TtsSynthesisScheduler scheduler,
    int chunk,
    int generation,
  ) async {
    final TtsCachedAudio? ready = scheduler.readyAudio(chunk);
    if (ready != null) return ready;
    _setState(MangaReadAloudState.synthesizing);
    final TtsFailure? already = scheduler.failure;
    if (already != null) return already;
    final Completer<Object> result = Completer<Object>();
    final StreamSubscription<TtsSegmentEvent> sub = scheduler.events.listen((
      TtsSegmentEvent event,
    ) {
      if (event is TtsSegmentFailed && event.blocking && !result.isCompleted) {
        result.complete(event.failure);
      }
    });
    unawaited(
      scheduler
          .ensure(chunk)
          .then<void>(
            (TtsCachedAudio audio) {
              if (!result.isCompleted) result.complete(audio);
            },
            onError: (Object error) {
              if (result.isCompleted) return;
              result.complete(
                error is TtsFailure
                    ? error
                    : TtsFailure(
                        TtsFailureCode.badResponse,
                        error.runtimeType.toString(),
                      ),
              );
            },
          ),
    );
    try {
      return await result.future;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _prefetch(int page, int generation) async {
    if (page >= _host.pageCount || _plans.containsKey(page)) return;
    final Object resolved = await _planFor(page);
    if (!_alive(generation) || resolved is! _PagePlan) return;
    // 只推预取窗口（后台失败不阻塞），不登记成播放器要的句子。
    resolved.scheduler?.setCursor(0);
  }

  /// 这一页的计划（文字拿到后建调度器）；拿不到文字返回原因。
  Future<Object> _planFor(int page) async {
    final _PagePlan? existing = _plans[page];
    if (existing != null) return existing;
    final Future<MangaPageTextResult> pending = _texts[page] ??= _host
        .ensurePageText(page);
    final MangaPageTextResult result = await pending;
    if (_disposed) return MangaPageTextUnavailableReason.cancelled;
    switch (result) {
      case MangaPageTextUnavailable(
        :final MangaPageTextUnavailableReason reason,
      ):
        // 不缓存失败：重试 / 重新翻到这页时重新要。
        if (identical(_texts[page], pending)) _texts.remove(page);
        return reason;
      case MangaPageTextReady(page: final MokuroImage image):
        final _PagePlan? raced = _plans[page];
        if (raced != null) return raced;
        final List<MangaReadAloudUtterance> utterances = planMangaPageReadAloud(
          image,
          pageIndex: page,
          rightToLeft: _host.rightToLeft,
          pronunciation: _pronunciation,
          maxInputLength: _rig.maxInputLength,
        );
        final List<int> chunkStart = <int>[];
        final List<String> texts = <String>[];
        for (final MangaReadAloudUtterance u in utterances) {
          chunkStart.add(texts.length);
          texts.addAll(u.spokenChunks);
        }
        final TtsSynthesisScheduler? scheduler = texts.isEmpty
            ? null
            : (_rig.createScheduler(texts)..setLookahead(_lookahead()));
        final _PagePlan plan = _PagePlan(
          page: page,
          utterances: utterances,
          scheduler: scheduler,
          chunkStart: chunkStart,
        );
        _plans[page] = plan;
        return plan;
    }
  }

  /// 释放 [keep] 之外的页的调度器（取消在途合成、解 pin）。
  void _dropPlans({required Set<int> keep}) {
    for (final int page in _plans.keys.toList()) {
      if (keep.contains(page)) continue;
      final TtsSynthesisScheduler? scheduler = _plans.remove(page)!.scheduler;
      if (scheduler == null) continue;
      final Future<void> done = scheduler.dispose();
      _disposing.add(done);
      unawaited(done.whenComplete(() => _disposing.remove(done)));
    }
  }

  @visibleForTesting
  int get debugPlanCount => _plans.length;

  @visibleForTesting
  Set<int> get debugPlannedPages => _plans.keys.toSet();
}
