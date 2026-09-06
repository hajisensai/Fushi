/// 语音段切分（流式、有状态）：可插拔的「窗口打分器」+ 统一的切分状态机。
///
/// 每 512 个样本（32 ms）一个窗口，打分器给出该窗口是语音的概率 [0, 1]：
/// - [EnergyVadScorer]（默认）：纯 Dart 自适应能量门限，零模型调用。有声书是
///   干净的朗读录音，句间静默与人声的能量差 30 dB 以上，不需要神经网络来分辨；
///   2026-09-05 Windows 真机分阶段计时里 silero 每窗口约 2.8 ms（78 s 音频 6.8 s，
///   占整条流水线七成），能量打分器把这一项降到可忽略。
/// - [SileroVadScorer]：k2-fsa 导出的 silero-vad v4（仅 16 kHz 分支，IO 见
///   `asr_types.dart`），每窗口一次前向，携带 LSTM 状态 `h`/`c`（`[2,1,64]`，换文件
///   清零）。对带背景音乐/环境噪声的音源更稳，作为可选高质量路径保留。
///
/// 切分状态机（对齐 sherpa-onnx `SileroVadModel` 的单阈值语义，不用 silero
/// 官方 `neg_threshold` 迟滞）：
/// - 概率 ≥ [threshold] 的窗口算语音，首个语音窗口开启一段；
/// - 语音中出现低于阈值的窗口先记「静音起点」，连续静音累计到 [minSilenceMs]
///   才落段（段尾 = 静音起点），中间又出现语音则静音清零（短停顿合并进同一段）；
/// - 落段时未加 pad 的长度 < [minSpeechMs] 直接丢弃；
/// - 首尾外扩 [speechPadMs]：段首 pad 不越过上一段的 pad 尾 / 文件起点；段尾 pad
///   不越过 `minSilenceMs / 2`（下一段最早只能在 minSilence 之后开始，因此相邻段
///   永不重叠）也不越过文件末尾；
/// - 一段持续超过 [maxSegmentMs] 时强制切分：在最近 `[max-5000, max]` ms 窗口内
///   概率最低的窗口起点切开，两半之间不加 pad（样本连续无缝）。
///
/// 内存：只保留「当前段起点 − pad」之后的样本（空闲时只留最近 pad 长度），
/// 7 小时的文件也只占一个段（≤ maxSegment + pad）的样本。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart' show AsrSegmenter;
import 'package:fushi/src/onnx/onnx_inference.dart';

/// 窗口打分器：给一批连续的 512 样本窗口各打一个「是语音」的概率。
///
/// 有状态（silero 的 LSTM、能量门限的噪声底历史），[reset] 在换文件 / 断点续跑
/// 重喂时清零。窗口按时间顺序传入，返回值与输入等长同序。
abstract interface class AsrVadScorer {
  Future<Float64List> score(List<Float32List> windows);
  void reset();
}

/// silero-vad v4 打分器：每窗口一次 ORT 前向，携带 LSTM 状态。
class SileroVadScorer implements AsrVadScorer {
  SileroVadScorer(this._session);

  /// silero-vad LSTM 状态形状 `[2, 1, 64]`。
  static const List<int> stateShape = <int>[2, 1, 64];
  static const int _stateLength = 2 * 1 * 64;

  final OnnxSession _session;
  Float32List _h = Float32List(_stateLength);
  Float32List _c = Float32List(_stateLength);

  @override
  Future<Float64List> score(List<Float32List> windows) async {
    final Float64List out = Float64List(windows.length);
    for (int i = 0; i < windows.length; i++) {
      out[i] = await _runModel(windows[i]);
    }
    return out;
  }

  @override
  void reset() {
    _h = Float32List(_stateLength);
    _c = Float32List(_stateLength);
  }

  Future<double> _runModel(Float32List window) async {
    final Map<String, OnnxTensor> outputs = await _session.run(
      <String, OnnxTensor>{
        AsrModelIo.vadInputX: OnnxTensor.float32(window, <int>[
          1,
          kAsrVadWindowSamples,
        ]),
        AsrModelIo.vadInputH: OnnxTensor.float32(_h, stateShape),
        AsrModelIo.vadInputC: OnnxTensor.float32(_c, stateShape),
      },
    );
    final OnnxTensor? prob = outputs[AsrModelIo.vadOutputProb];
    final OnnxTensor? newH = outputs[AsrModelIo.vadOutputH];
    final OnnxTensor? newC = outputs[AsrModelIo.vadOutputC];
    if (prob == null || newH == null || newC == null) {
      throw StateError('VAD 输出缺失：${outputs.keys.toList()}');
    }
    final Float32List? probData = prob.floatData;
    final Float32List? hData = newH.floatData;
    final Float32List? cData = newC.floatData;
    if (probData == null || probData.isEmpty) {
      throw StateError('VAD prob 输出为空');
    }
    if (hData == null ||
        hData.length != _stateLength ||
        cData == null ||
        cData.length != _stateLength) {
      throw StateError('VAD 状态形状异常：new_h=${newH.shape} new_c=${newC.shape}');
    }
    _h = hData;
    _c = cData;
    return probData[0];
  }
}

/// 自适应能量门限打分器（纯 Dart，无模型）。
///
/// 每窗口算 RMS 电平（dBFS），门限 = 最近 [historySeconds] 秒窗口电平的第
/// [floorPercentile] 百分位（噪声底）+ [marginDb]，再夹到 [minThresholdDb,
/// maxThresholdDb]；输出 `sigmoid((dB − 门限) / softnessDb)`：正好在门限处 0.5，
/// 高出 4 dB 约 0.88、低 4 dB 约 0.12。时间上的迟滞由状态机的 minSilence /
/// minSpeech 提供，强制切分取「概率最低」即「最安静」的窗口，语义自然。
///
/// 数字静音（全零）按 [silenceFloorDb] 计，避免 log(0)。
class EnergyVadScorer implements AsrVadScorer {
  EnergyVadScorer({
    this.historySeconds = 30,
    this.floorPercentile = 10,
    this.marginDb = 12,
    this.minThresholdDb = -55,
    this.maxThresholdDb = -30,
    this.softnessDb = 2,
  }) : assert(historySeconds > 0),
       assert(floorPercentile >= 0 && floorPercentile <= 100),
       _historyWindows =
           historySeconds * kAsrSampleRate ~/ kAsrVadWindowSamples;

  static const double silenceFloorDb = -100;

  final int historySeconds;
  final int floorPercentile;
  final double marginDb;
  final double minThresholdDb;
  final double maxThresholdDb;
  final double softnessDb;

  final int _historyWindows;
  final List<double> _history = <double>[];

  /// 最近一次 [score] 用的门限（dBFS），供诊断与测试。
  double? lastThresholdDb;

  static double windowDb(Float32List window) {
    double acc = 0;
    for (int i = 0; i < window.length; i++) {
      final double v = window[i];
      acc += v * v;
    }
    if (acc <= 0 || window.isEmpty) return silenceFloorDb;
    final double rms = math.sqrt(acc / window.length);
    final double db = 20 * math.log(rms) / math.ln10;
    return db < silenceFloorDb ? silenceFloorDb : db;
  }

  @override
  Future<Float64List> score(List<Float32List> windows) async {
    final Float64List dbs = Float64List(windows.length);
    for (int i = 0; i < windows.length; i++) {
      dbs[i] = windowDb(windows[i]);
      _history.add(dbs[i]);
    }
    if (_history.length > _historyWindows) {
      _history.removeRange(0, _history.length - _historyWindows);
    }
    final double threshold = _thresholdDb();
    lastThresholdDb = threshold;
    final Float64List out = Float64List(windows.length);
    for (int i = 0; i < windows.length; i++) {
      out[i] = 1 / (1 + math.exp(-(dbs[i] - threshold) / softnessDb));
    }
    return out;
  }

  double _thresholdDb() {
    if (_history.isEmpty) return minThresholdDb;
    final List<double> sorted = List<double>.of(_history)..sort();
    final int idx = ((sorted.length - 1) * floorPercentile / 100).round();
    final double floor = sorted[idx];
    final double raw = floor + marginDb;
    if (raw < minThresholdDb) return minThresholdDb;
    if (raw > maxThresholdDb) return maxThresholdDb;
    return raw;
  }

  @override
  void reset() {
    _history.clear();
    lastThresholdDb = null;
  }
}

/// 段首/段尾默认外扩（毫秒）。
///
/// 2026-09-05 Windows 真机（RTX 5090，`integration_test/asr_transcribe_e2e_itest.dart`）：
/// 200 ms 时 2.5 s 的 TTS 样本「今日はいい天気ですね」被识别成「いい天気ですね」——
/// silero-vad 在语音起始处要积累 3~5 个 32 ms 窗口才越过阈值，文件开头 LSTM 冷启动
/// 更慢，触发点落在约 0.5 s，200 ms 回补不够，首字直接被切掉。有声书里每个句首
/// （长停顿之后）都是同一形态，首字被吃会让匹配率与 cue 起点一起坏。500 ms 覆盖
/// 实测最坏触发延迟并留余量；多出来的静默对 RNN-T 是无害的（不会发射 token）。
const int kAsrVadDefaultSpeechPadMs = 500;

/// VAD 单段上限缺省值（毫秒）；GPU 静态桶模式另有更短的上限，见
/// `asr_encoder_buckets.dart` 的 `kAsrStaticMaxSegmentMs`。
const int kAsrDefaultMaxSegmentMs = 20000;

class AsrVadSegmenter implements AsrSegmenter {
  /// [scorer] 与 [session] 二选一：给 [session] 即 silero-vad v4；都不给用
  /// [EnergyVadScorer] 默认参数。
  AsrVadSegmenter({
    OnnxSession? session,
    AsrVadScorer? scorer,
    this.threshold = 0.5,
    this.minSilenceMs = 500,
    this.minSpeechMs = 250,
    this.speechPadMs = kAsrVadDefaultSpeechPadMs,
    this.maxSegmentMs = kAsrDefaultMaxSegmentMs,
  }) : _scorer = _resolveScorer(session, scorer),
       _minSilenceSamples = _msToSamples(minSilenceMs),
       _minSpeechSamples = _msToSamples(minSpeechMs),
       _speechPadSamples = _msToSamples(speechPadMs),
       _maxSegmentSamples = _msToSamples(maxSegmentMs),
       _forceSplitLookbackSamples = _msToSamples(_forceSplitLookbackMs) {
    if (threshold <= 0 || threshold >= 1) {
      throw ArgumentError.value(threshold, 'threshold', '必须在 (0, 1) 内');
    }
    if (minSilenceMs < 0 || minSpeechMs < 0 || speechPadMs < 0) {
      throw ArgumentError('minSilenceMs / minSpeechMs / speechPadMs 不能为负');
    }
    if (maxSegmentMs <= _forceSplitLookbackMs) {
      throw ArgumentError.value(
        maxSegmentMs,
        'maxSegmentMs',
        '必须大于强制切分回看窗口 $_forceSplitLookbackMs ms',
      );
    }
  }

  /// 强制切分时在段尾多长的窗口内找概率最低点。
  static const int _forceSplitLookbackMs = 5000;

  static AsrVadScorer _resolveScorer(
    OnnxSession? session,
    AsrVadScorer? scorer,
  ) {
    if (session != null && scorer != null) {
      throw ArgumentError('session 与 scorer 只能给一个');
    }
    if (scorer != null) return scorer;
    if (session != null) return SileroVadScorer(session);
    return EnergyVadScorer();
  }

  final AsrVadScorer _scorer;
  final double threshold;
  final int minSilenceMs;
  final int minSpeechMs;
  final int speechPadMs;
  final int maxSegmentMs;

  final int _minSilenceSamples;
  final int _minSpeechSamples;
  final int _speechPadSamples;
  final int _maxSegmentSamples;
  final int _forceSplitLookbackSamples;

  /// 不足一个窗口的尾样本，等下一块补齐。
  final List<double> _pending = <double>[];

  /// 已收到样本的绝对末尾（= 下一块必须的 startSample）。
  /// reset 后为 -1：首块可以从任意偏移开始（断点续跑从 `resumeSample` 重新喂）。
  int _totalSamples = -1;

  /// 已经过 VAD 的绝对样本末尾（512 的整数倍）。
  int _vadSamples = 0;

  /// 首块起点到首个 512 网格点之间还需跳过的样本数。
  int _skipRemaining = 0;

  /// 保留的样本窗口（按绝对样本偏移寻址）。
  final _SampleWindow _retained = _SampleWindow();

  /// 当前段：起点（-1 表示空闲）、当前静音起点（-1 表示无）、逐窗口概率。
  int _speechStart = -1;
  int _silenceStart = -1;
  final List<double> _probs = <double>[];

  /// 上一段带 pad 的终点（本段 pad 不越过它）。
  int _lastPaddedEnd = 0;

  static int _msToSamples(int ms) => ms * kAsrSampleRate ~/ 1000;

  /// 断点续跑检查点：正处于「语音中」（已越过阈值、尚未因静默封段）时返回这段
  /// 语音**含首部 pad** 的起始样本（相对文件起点，不小于上一段 pad 尾 / 首块起点）；
  /// 静默时返回 null。调用方在每块处理完后记
  /// `resumeSample = inProgressSpeechStartSample ?? chunk.endSample`，恢复时
  /// `reset()` 后从该样本重新喂即可得到相同的段边界。
  @override
  int? get inProgressSpeechStartSample {
    if (_speechStart < 0) return null;
    return math.max(_lastPaddedEnd, _speechStart - _speechPadSamples);
  }

  /// 顺序喂 PCM 块（任意长度）；返回本次**新完成**的语音段。
  ///
  /// reset 后的首块可从任意 `startSample` 开始；之后每块必须与上一块无缝衔接
  /// （`chunk.startSample == 上一块 endSample`），否则抛 [ArgumentError]——
  /// 中间丢了样本会让段偏移整体错位，不能静默接受。
  @override
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk) async {
    if (_totalSamples < 0) {
      if (chunk.startSample < 0) {
        throw ArgumentError.value(chunk.startSample, 'chunk.startSample');
      }
      _totalSamples = chunk.startSample;
      // VAD 窗口固定对齐到文件绝对 512 网格：断点续跑从任意偏移重喂时段边界
      // 与整文件一次跑完一致。网格前的零头样本不过 VAD，只作 pad 素材
      // （检查点恒 ≤ 段起点，而段起点总在网格上，因此不会漏掉语音）。
      _vadSamples =
          (chunk.startSample + kAsrVadWindowSamples - 1) ~/
          kAsrVadWindowSamples *
          kAsrVadWindowSamples;
      _skipRemaining = _vadSamples - chunk.startSample;
      _lastPaddedEnd = chunk.startSample;
      _retained.resetTo(chunk.startSample);
    } else if (chunk.startSample != _totalSamples) {
      throw ArgumentError(
        'AsrPcmChunk 不连续：期望 startSample=$_totalSamples，'
        '实际 ${chunk.startSample}',
      );
    }
    final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
    final Float32List samples = chunk.samples;
    _totalSamples += samples.length;
    _retained.append(samples);

    int offset = 0;
    if (_skipRemaining > 0) {
      offset = math.min(_skipRemaining, samples.length);
      _skipRemaining -= offset;
    }
    // 先切出本块能凑齐的全部窗口，整批打分（打分器可以批量/向量化），再顺序
    // 过切分状态机。
    final List<Float32List> windows = <Float32List>[];
    if (_pending.isNotEmpty) {
      final int need = kAsrVadWindowSamples - _pending.length;
      if (samples.length - offset < need) {
        _pending.addAll(samples.sublist(offset));
        return out;
      }
      _pending.addAll(samples.sublist(offset, offset + need));
      offset += need;
      windows.add(Float32List.fromList(_pending));
      _pending.clear();
    }
    while (offset + kAsrVadWindowSamples <= samples.length) {
      windows.add(
        Float32List.sublistView(samples, offset, offset + kAsrVadWindowSamples),
      );
      offset += kAsrVadWindowSamples;
    }
    if (offset < samples.length) {
      _pending.addAll(samples.sublist(offset));
    }
    if (windows.isEmpty) return out;
    final Float64List probs = await _scorer.score(windows);
    if (probs.length != windows.length) {
      throw StateError('打分器返回 ${probs.length} 个概率，窗口数 ${windows.length}');
    }
    for (int i = 0; i < windows.length; i++) {
      _processWindow(probs[i], out);
    }
    return out;
  }

  /// 文件结束：把进行中的段按已有样本收尾（不足一个窗口的尾样本不再过 VAD，
  /// 只作为尾 pad 素材）。
  @override
  Future<List<AsrSpeechSegment>> flush() async {
    final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
    if (_speechStart >= 0) {
      final int end = _silenceStart >= 0 ? _silenceStart : _vadSamples;
      _finalize(end, out, contiguousNext: false);
    }
    _pending.clear();
    if (_totalSamples >= 0) _retained.dropBefore(_totalSamples);
    return out;
  }

  /// 换文件：清空 LSTM 状态、缓冲与计数。
  @override
  void reset() {
    _scorer.reset();
    _pending.clear();
    _totalSamples = -1;
    _vadSamples = 0;
    _skipRemaining = 0;
    _retained.resetTo(0);
    _speechStart = -1;
    _silenceStart = -1;
    _probs.clear();
    _lastPaddedEnd = 0;
  }

  void _processWindow(double prob, List<AsrSpeechSegment> out) {
    final int windowStart = _vadSamples;
    _vadSamples += kAsrVadWindowSamples;
    final int windowEnd = _vadSamples;

    if (prob >= threshold) {
      if (_speechStart < 0) {
        _speechStart = windowStart;
        _probs.clear();
      }
      _silenceStart = -1;
      _probs.add(prob);
    } else if (_speechStart >= 0) {
      if (_silenceStart < 0) _silenceStart = windowStart;
      _probs.add(prob);
      if (windowEnd - _silenceStart >= _minSilenceSamples) {
        _finalize(_silenceStart, out, contiguousNext: false);
      }
    } else {
      // 空闲：只留最近 pad 长度的样本供下一段回溯。
      _retained.dropBefore(
        math.max(_lastPaddedEnd, windowEnd - _speechPadSamples),
      );
      return;
    }

    if (_speechStart >= 0 && windowEnd - _speechStart >= _maxSegmentSamples) {
      _forceSplit(out);
    }
  }

  /// 落段 `[_speechStart, end)`，附 pad 后写入 [out]；随后回到空闲。
  ///
  /// [contiguousNext] 为 true 表示紧接着还有一段从 [end] 开始（强制切分），
  /// 此时尾部不加 pad。
  void _finalize(
    int end,
    List<AsrSpeechSegment> out, {
    required bool contiguousNext,
  }) {
    final int start = _speechStart;
    if (end - start >= _minSpeechSamples && end > start) {
      final int paddedStart = math.max(
        _lastPaddedEnd,
        start - _speechPadSamples,
      );
      final int endPad = contiguousNext
          ? 0
          : math.min(_speechPadSamples, _minSilenceSamples ~/ 2);
      final int paddedEnd = math.min(_totalSamples, end + endPad);
      out.add(
        AsrSpeechSegment(
          startSample: paddedStart,
          samples: _retained.slice(paddedStart, paddedEnd),
        ),
      );
      _lastPaddedEnd = paddedEnd;
    } else if (contiguousNext) {
      // 被丢弃的前半段也要挡住后半段的 pad 回溯，保持样本不重复。
      _lastPaddedEnd = math.max(_lastPaddedEnd, end);
    }
    _speechStart = -1;
    _silenceStart = -1;
    _probs.clear();
    if (!contiguousNext) {
      _retained.dropBefore(
        math.max(_lastPaddedEnd, _vadSamples - _speechPadSamples),
      );
    }
  }

  /// 超长段：在最近 [_forceSplitLookbackMs] 内概率最低的窗口起点切开。
  void _forceSplit(List<AsrSpeechSegment> out) {
    final int windowCount = _probs.length;
    final int lookbackWindows = math.min(
      windowCount,
      _forceSplitLookbackSamples ~/ kAsrVadWindowSamples,
    );
    int bestIndex = windowCount - lookbackWindows;
    for (int i = bestIndex; i < windowCount; i++) {
      if (_probs[i] < _probs[bestIndex]) bestIndex = i;
    }
    if (bestIndex == 0) {
      // 回看窗口覆盖整段且首窗最低：不能切出空段，改在第二个窗口切。
      bestIndex = 1;
    }
    final int cut = _speechStart + bestIndex * kAsrVadWindowSamples;
    final List<double> tail = _probs.sublist(bestIndex);
    _finalize(cut, out, contiguousNext: true);

    // 后半段从 cut 起，重建静音起点：尾部连续低于阈值的窗口。
    _speechStart = cut;
    _probs.addAll(tail);
    int silenceFrom = tail.length;
    while (silenceFrom > 0 && tail[silenceFrom - 1] < threshold) {
      silenceFrom--;
    }
    _silenceStart = silenceFrom == tail.length
        ? -1
        : cut + silenceFrom * kAsrVadWindowSamples;
    _lastPaddedEnd = math.max(_lastPaddedEnd, cut);
    // 后半段从 cut 起且无首部 pad：cut 之前的样本不再需要。
    _retained.dropBefore(cut);
  }
}

/// 以绝对样本偏移寻址的连续样本窗口：尾部追加、头部丢弃、按绝对区间切片。
class _SampleWindow {
  Float32List _buffer = Float32List(kAsrSampleRate * 4);

  /// `_buffer[_head]` 对应的绝对样本偏移。
  int _start = 0;
  int _head = 0;
  int _length = 0;

  int get start => _start;
  int get end => _start + _length;

  void append(Float32List samples) {
    _ensureCapacity(samples.length);
    _buffer.setRange(
      _head + _length,
      _head + _length + samples.length,
      samples,
    );
    _length += samples.length;
  }

  /// 丢弃绝对偏移 [absolute] 之前的样本（超过末尾则清空但保留偏移）。
  void dropBefore(int absolute) {
    if (absolute <= _start) return;
    final int drop = math.min(absolute - _start, _length);
    _head += drop;
    _length -= drop;
    _start += drop;
    if (_length == 0) {
      _head = 0;
      _start = absolute;
    }
  }

  Float32List slice(int from, int to) {
    if (from < _start || to > end || from > to) {
      throw StateError('切片 [$from, $to) 超出保留窗口 [$_start, $end)');
    }
    return Float32List.fromList(
      Float32List.sublistView(
        _buffer,
        _head + from - _start,
        _head + to - _start,
      ),
    );
  }

  /// 清空并把窗口起点定到绝对偏移 [absolute]。
  void resetTo(int absolute) {
    _start = absolute;
    _head = 0;
    _length = 0;
  }

  void _ensureCapacity(int extra) {
    final int needed = _length + extra;
    if (_head + needed <= _buffer.length) return;
    if (needed <= _buffer.length && _head > 0) {
      // 空间够，只是头部有空洞：整体前移。
      _buffer.setRange(0, _length, _buffer, _head);
      _head = 0;
      return;
    }
    int capacity = _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    final Float32List grown = Float32List(capacity);
    grown.setRange(0, _length, _buffer, _head);
    _buffer = grown;
    _head = 0;
  }
}
