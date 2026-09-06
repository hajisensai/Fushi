/// kaldi 兼容的 80 维 log-mel fbank（纯 Dart，无 IO）。
///
/// 目标是与 sherpa-onnx 喂给 ReazonSpeech k2-v2 的特征**逐值一致**。
/// sherpa-onnx `features.cc` 把 `FeatureExtractorConfig` 映射到 kaldi-native-fbank
/// 的选项如下（默认值），本类把这些选项写死：
///
/// ```text
/// frame_opts: samp_freq=16000, frame_length_ms=25, frame_shift_ms=10,
///             dither=0, preemph_coeff=0.97, remove_dc_offset=true,
///             window_type="povey", round_to_power_of_two=true (FFT 512),
///             snip_edges=false
/// mel_opts  : num_bins=80, low_freq=20, high_freq=-400 (= nyquist-400),
///             is_librosa=false, htk_mode=false
/// fbank     : use_energy=false, use_log_fbank=true, use_power=true
/// 输入      : normalize_samples=true —— [-1, 1] 浮点直接喂，不乘 32768
/// ```
///
/// 算法逐步对齐 kaldi-native-fbank（`feature-window.cc` / `mel-computations.cc` /
/// `feature-fbank.cc`）：
/// 1. 帧数 = `(numSamples + shift ~/ 2) ~/ shift`（`snip_edges=false` + flush）；
/// 2. 帧 i 的首样本 = `i*shift + shift/2 - length/2`，越界样本反射填充；
/// 3. 去直流（减帧均值）→ 预加重 → povey 窗 → 零填充到 512；
/// 4. 512 点实 FFT → 功率谱（257 点，mel 只用前 256 个 bin）；
/// 5. 三角 mel 滤波（mel = 1127·ln(1 + f/700)，权重按 FFT bin 中心频率取值）；
/// 6. `log(max(x, float epsilon))`。
///
/// FFT 与累加用 double，输出转 float32；与 knf 的 float 实现相比差异在 1e-4 量级
/// （黄金数据测试阈值 1e-3，见 `test/asr/asr_fbank_test.dart`）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/asr/asr_types.dart';

class AsrFbank {
  const AsrFbank();

  /// 25 ms 帧长 / 10 ms 帧移（16 kHz 下 400 / 160 样本）。
  static const int frameLength = kAsrSampleRate * 25 ~/ 1000;
  static const int frameShift = kAsrSampleRate * kAsrFrameShiftMs ~/ 1000;

  /// `round_to_power_of_two=true`：400 → 512。
  static const int paddedLength = 512;

  static const int numBins = kAsrFeatureDim;
  static const double _preemphCoeff = 0.97;
  static const double _lowFreq = 20.0;

  /// `high_freq=-400` 表示 nyquist − 400 = 7600 Hz。
  static const double _highFreq = kAsrSampleRate / 2 - 400.0;

  /// `std::numeric_limits<float>::epsilon()`。
  static const double _floatEpsilon = 1.1920928955078125e-7;

  /// 只依赖常量的预计算表在首次使用时构造一次（povey 窗、mel 权重、FFT 旋转因子）。
  static final Float64List _window = _buildPoveyWindow();
  static final _MelBanks _melBanks = _MelBanks.build();
  static final _RealFft _fft = _RealFft(paddedLength);

  /// `snip_edges=false` 且流已结束（flush）时的帧数，与 kaldi `NumFrames` 一致。
  static int frameCount(int numSamples) {
    if (numSamples <= 0) return 0;
    return (numSamples + frameShift ~/ 2) ~/ frameShift;
  }

  /// [samples] 为 16 kHz 单声道 float32（[-1, 1]）；返回扁平 Float32List，
  /// 长度 `frames * 80`（行主序，一帧 80 维连续）。
  Float32List compute(Float32List samples) {
    final int frames = frameCount(samples.length);
    final Float32List out = Float32List(frames * numBins);
    if (frames == 0) return out;

    final Float64List frame = Float64List(paddedLength);
    final Float64List power = Float64List(paddedLength ~/ 2 + 1);
    final Float64List mel = Float64List(numBins);
    for (int i = 0; i < frames; i++) {
      _extractWindow(samples, i, frame);
      _fft.powerSpectrum(frame, power);
      _melBanks.apply(power, mel);
      final int base = i * numBins;
      for (int b = 0; b < numBins; b++) {
        out[base + b] = math.log(math.max(mel[b], _floatEpsilon));
      }
    }
    return out;
  }

  /// 取第 [frameIndex] 帧：反射填充 → 去直流 → 预加重 → 加窗 → 零填充。
  static void _extractWindow(
    Float32List samples,
    int frameIndex,
    Float64List frame,
  ) {
    final int numSamples = samples.length;
    final int start =
        frameIndex * frameShift + frameShift ~/ 2 - frameLength ~/ 2;
    double sum = 0;
    for (int n = 0; n < frameLength; n++) {
      int s = start + n;
      while (s < 0 || s >= numSamples) {
        s = s < 0 ? -s - 1 : 2 * numSamples - 1 - s;
      }
      final double v = samples[s];
      frame[n] = v;
      sum += v;
    }
    final double mean = sum / frameLength;
    for (int n = 0; n < frameLength; n++) {
      frame[n] -= mean;
    }
    // kaldi Preemphasize：从尾往头，w[0] 用自身。
    for (int n = frameLength - 1; n > 0; n--) {
      frame[n] -= _preemphCoeff * frame[n - 1];
    }
    frame[0] -= _preemphCoeff * frame[0];
    for (int n = 0; n < frameLength; n++) {
      frame[n] *= _window[n];
    }
    for (int n = frameLength; n < paddedLength; n++) {
      frame[n] = 0;
    }
  }

  /// povey 窗：`pow(0.5 - 0.5*cos(2πn/(N-1)), 0.85)`。
  static Float64List _buildPoveyWindow() {
    final Float64List w = Float64List(frameLength);
    const double a = 2 * math.pi / (frameLength - 1);
    for (int n = 0; n < frameLength; n++) {
      w[n] = math.pow(0.5 - 0.5 * math.cos(a * n), 0.85).toDouble();
    }
    return w;
  }

  static double melScale(double freq) => 1127.0 * math.log(1.0 + freq / 700.0);
}

/// kaldi `MelBanks`：每个 mel bin 只在 `[first, first+weights.length)` 的 FFT bin 上非零。
class _MelBanks {
  const _MelBanks(this._firstIndex, this._weights);

  final List<int> _firstIndex;
  final List<Float64List> _weights;

  static _MelBanks build() {
    // knf: num_fft_bins = padded / 2 = 256，Nyquist bin（第 256 个）不参与。
    const int numFftBins = AsrFbank.paddedLength ~/ 2;
    const double fftBinWidth = kAsrSampleRate / AsrFbank.paddedLength;
    final double melLow = AsrFbank.melScale(AsrFbank._lowFreq);
    final double melHigh = AsrFbank.melScale(AsrFbank._highFreq);
    final double melDelta = (melHigh - melLow) / (AsrFbank.numBins + 1);

    final List<int> firstIndex = List<int>.filled(AsrFbank.numBins, 0);
    final List<Float64List> weights = <Float64List>[];
    for (int bin = 0; bin < AsrFbank.numBins; bin++) {
      final double leftMel = melLow + bin * melDelta;
      final double centerMel = melLow + (bin + 1) * melDelta;
      final double rightMel = melLow + (bin + 2) * melDelta;
      final Float64List full = Float64List(numFftBins);
      int first = -1;
      int last = -1;
      for (int i = 0; i < numFftBins; i++) {
        final double mel = AsrFbank.melScale(fftBinWidth * i);
        if (mel > leftMel && mel < rightMel) {
          full[i] = mel <= centerMel
              ? (mel - leftMel) / (centerMel - leftMel)
              : (rightMel - mel) / (rightMel - centerMel);
          if (first == -1) first = i;
          last = i;
        }
      }
      if (first == -1) {
        // 80 bin / 512 点 FFT 下不可能为空；留作契约断言而非静默产生全零特征。
        throw StateError('mel bin $bin 未覆盖任何 FFT bin');
      }
      firstIndex[bin] = first;
      weights.add(Float64List.sublistView(full, first, last + 1));
    }
    return _MelBanks(firstIndex, weights);
  }

  void apply(Float64List power, Float64List out) {
    for (int bin = 0; bin < _weights.length; bin++) {
      final Float64List w = _weights[bin];
      final int first = _firstIndex[bin];
      double acc = 0;
      for (int k = 0; k < w.length; k++) {
        acc += w[k] * power[first + k];
      }
      out[bin] = acc;
    }
  }
}

/// 基 2 迭代复 FFT（Float64），只暴露实输入 → 功率谱。
class _RealFft {
  _RealFft(this.size)
      : _bitReverse = _buildBitReverse(size),
        _cos = Float64List(size ~/ 2),
        _sin = Float64List(size ~/ 2),
        _re = Float64List(size),
        _im = Float64List(size) {
    if (size < 2 || (size & (size - 1)) != 0) {
      throw ArgumentError.value(size, 'size', 'FFT 长度必须是 2 的幂');
    }
    for (int k = 0; k < size ~/ 2; k++) {
      final double angle = -2 * math.pi * k / size;
      _cos[k] = math.cos(angle);
      _sin[k] = math.sin(angle);
    }
  }

  final int size;
  final Int32List _bitReverse;
  final Float64List _cos;
  final Float64List _sin;
  final Float64List _re;
  final Float64List _im;

  static Int32List _buildBitReverse(int n) {
    int bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    final Int32List table = Int32List(n);
    for (int i = 0; i < n; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | ((i >> b) & 1);
      }
      table[i] = r;
    }
    return table;
  }

  /// [input] 长度 [size] 的实信号；[power] 长度 `size/2 + 1`：
  /// `power[k] = |X[k]|²`，k = 0..size/2（与 kaldi `ComputePowerSpectrum` 布局等价）。
  void powerSpectrum(Float64List input, Float64List power) {
    final int n = size;
    for (int i = 0; i < n; i++) {
      _re[_bitReverse[i]] = input[i];
      _im[i] = 0;
    }
    for (int len = 2; len <= n; len <<= 1) {
      final int half = len >> 1;
      final int step = n ~/ len;
      for (int start = 0; start < n; start += len) {
        for (int k = 0; k < half; k++) {
          final int a = start + k;
          final int b = a + half;
          final double wr = _cos[k * step];
          final double wi = _sin[k * step];
          final double tr = _re[b] * wr - _im[b] * wi;
          final double ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    for (int k = 0; k <= n ~/ 2; k++) {
      power[k] = _re[k] * _re[k] + _im[k] * _im[k];
    }
  }
}
