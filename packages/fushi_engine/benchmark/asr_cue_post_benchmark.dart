// 有声书转录 cue 能量吸附 + 修边的基准：迁移前的纯 Dart 实现（原样复制在本文件下半部分）vs
// 上游 fushi-subtitles 的 AsrCuePostProcessor（Rust，编进 fushi_compute 原生库）。两条路径
// 的起止与 token 偏移逐条比对，不一致直接退出 1。
//
// 用法（在 packages/fushi_engine 下；AOT 更接近 app）：
//   dart compile exe benchmark/asr_cue_post_benchmark.dart -o <out>.exe && <out>.exe
//
// 规模：7 小时整本 = 1,260,000 帧 @20 ms。每项先预热一次，再跑 [_runs] 次取中位数。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_compute/fushi_compute.dart';

const int _runs = 5;

int _medianUs(String label, void Function() body) {
  body();
  final List<int> us = <int>[];
  for (int i = 0; i < _runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    us.add(sw.elapsedMicroseconds);
  }
  us.sort();
  final int median = us[us.length ~/ 2];
  stdout.writeln(
    '  ${label.padRight(58)} ${(median / 1000).toStringAsFixed(3).padLeft(10)} ms',
  );
  return median;
}

void _ratio(int oldUs, int newUs) {
  stdout.writeln(
    '  ${'=> speedup'.padRight(58)} ${(oldUs / newUs).toStringAsFixed(1).padLeft(10)} x',
  );
}

/// splitmix64。
final class _Rng {
  _Rng(this._s);
  int _s;
  int next() {
    _s = _s + 0x9E3779B97F4A7C15;
    int z = _s;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  double nextDouble() => (next() >>> 11) / 9007199254740992.0;
  int nextInt(int bound) => (next() >>> 1) % bound;
}

void main() {
  FushiCompute.require();
  stdout.writeln(
    '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
  );
  final _Rng rng = _Rng(20261018);

  // ── 有声书 cue 能量吸附 ────────────────────────────────────────────────────
  stdout.writeln('audiobook cue energy snap (7 h book, 1,260,000 frames)');
  const int bookFrames = 7 * 3600 * 50;
  final Int8List energy = Int8List(bookFrames);
  final List<(int, int, List<int>?)> spec = <(int, int, List<int>?)>[];
  for (int f = 0; f < bookFrames;) {
    final int on = 60 + rng.nextInt(300);
    for (int k = f; k < f + on && k < bookFrames; k++) {
      energy[k] = -30 + rng.nextInt(23);
    }
    final int startMs = f * 20 + rng.nextInt(300) - 150;
    f += on;
    final int off = rng.nextInt(4) == 0
        ? 2 + rng.nextInt(4)
        : 8 + rng.nextInt(30);
    for (int k = f; k < f + off && k < bookFrames; k++) {
      energy[k] = -70 + rng.nextInt(12);
    }
    final int endMs =
        (f + (rng.nextInt(2) == 0 ? off ~/ 2 : 0)) * 20 +
        rng.nextInt(200) -
        100;
    spec.add((
      startMs,
      endMs,
      rng.nextInt(3) == 0
          ? null
          : <int>[rng.nextInt(120), (endMs - startMs) ~/ 2],
    ));
    f += off;
  }
  // 让一半的 cue 紧挨下一条（切点在停顿里）。
  for (int i = 0; i + 1 < spec.length; i += 2) {
    spec[i] = (spec[i].$1, spec[i + 1].$1 - rng.nextInt(80), spec[i].$3);
  }
  stdout.writeln('  (${spec.length} cues)');
  List<AudioCue> cues() => <AudioCue>[
    for (final (int, int, List<int>?) s in spec)
      AudioCue()
        ..bookKey = 'b'
        ..chapterHref = ''
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = 'x'
        ..startMs = s.$1
        ..endMs = s.$2 > s.$1 ? s.$2 : s.$1 + 400
        ..audioFileIndex = 0
        ..tokenTiming = s.$3 == null
            ? null
            : CueTokenTiming(
                tokens: const <String>['a', 'b'],
                offsetsMs: s.$3!,
              ),
  ];
  late List<AudioCue> sa;
  late List<AudioCue> sb;
  final int sOld = _medianUs('Dart CueEnergySnapper snap + refineEdges', () {
    sa = cues();
    const OldCueEnergySnapper s = OldCueEnergySnapper();
    s.snap(sa, energy);
    s.refineEdges(sa, energy);
  });
  // 新路径端到端：AudioCue → 上游打包 → 一次 FFI（fcp_cue_post_process，编在 fushi_compute
  // 里）→ 分组写回 AudioCue，含全部拷贝。默认参数里 tokenGuardMs / cutBiasMs 与旧副本不同，
  // 按旧副本的取值传，结果才可比。
  final AsrCuePostProcessor post = AsrCuePostProcessor(
    library: AsrCuePostLibrary.fromDynamicLibrary(
      FushiCompute.require().library,
    ),
    snap: const AsrEnergySnapOptions(tokenGuardMs: 200, cutBiasMs: 0),
  );
  final int sNew = _medianUs(
    'fcp_cue_post_process snap + refineEdges (end to end)',
    () {
      sb = cues();
      final AsrCuePostResult r = post.process(
        <AsrPostCue>[
          for (final AudioCue c in sb)
            AsrPostCue(
              startMs: c.startMs,
              endMs: c.endMs,
              audioFileIndex: c.audioFileIndex,
              text: c.text,
              tokenOffsetsMs: c.tokenTiming?.offsetsMs,
            ),
        ],
        energy,
        stages: const <AsrCuePostStage>{
          AsrCuePostStage.snap,
          AsrCuePostStage.refineEdges,
        },
      );
      for (final AsrPostCueGroup g in r.groups) {
        final AudioCue c = sb[g.firstIndex];
        c.startMs = g.startMs;
        c.endMs = g.endMs;
        final List<int>? o = g.tokenOffsetsMs;
        if (o != null && c.tokenTiming != null) {
          c.tokenTiming = CueTokenTiming(
            tokens: c.tokenTiming!.tokens,
            offsetsMs: o,
          );
        }
      }
    },
  );
  _ratio(sOld, sNew);
  for (int i = 0; i < sa.length; i++) {
    if (sa[i].startMs != sb[i].startMs ||
        sa[i].endMs != sb[i].endMs ||
        '${sa[i].tokenTiming?.offsetsMs}' !=
            '${sb[i].tokenTiming?.offsetsMs}') {
      stderr.writeln('MISMATCH: snap cue $i');
      exit(1);
    }
  }
  stdout.writeln('all outputs identical');
}

// ======== 原样复制：packages/fushi_audio/lib/src/matching/cue_energy_snapper.dart（删除前）========
class OldCueEnergySnapper {
  const OldCueEnergySnapper({
    this.frameMs = 20,
    this.maxGapMs = 400,
    this.windowMs = 600,
    this.minValleyMs = 120,
    this.distancePenalty = 0.5,
    this.tailMs = 80,
    this.leadMs = 40,
    this.minDurationMs = 500,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.tokenGuardMs = 200,
    this.edgeMaxShiftMs = 600,
    this.edgeMinVoiceMs = 60,
    this.edgeLeadMs = 150,
    this.edgeTailMs = 80,
  });

  /// [refineEdges]：终点留到收声后多少。春物卷 2 扫过 80 / 150：150 起点延迟
  /// p90 从 88 涨回 110~124 ms、尾挂变多，只换来提前截断少 3~9 条。
  final int edgeTailMs;

  /// [refineEdges]：起点挪到开口前多少。比 [leadMs] 宽——轻声开口（气声、清辅音）
  /// 常在门限下，40 ms 时字头被切（晚起 > 150 ms）11~16 条，150 ms 降到 7~8 条，
  /// 提前开始几乎不变（春物卷 2 扫 40 / 100 / 150）。
  final int edgeLeadMs;

  /// [refineEdges]：起止点最多往 cue 内收多远。
  final int edgeMaxShiftMs;

  /// [refineEdges]：多长的连续有声才算真开口 / 真收声（滤掉单帧噪声）。
  final int edgeMinVoiceMs;

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 两条 cue 之间空隙超过此值就不算「紧挨着」（那是 VAD 已经切开的停顿）。
  final int maxGapMs;

  /// 在原切点前后多远内找谷。
  final int windowMs;

  /// 谷的最短长度：塞音闭塞只有几十毫秒，不算句间停顿。
  final int minValleyMs;

  /// 选谷打分 = 谷长 − 此系数 × 谷中心离原切点的距离（都按毫秒）。
  final double distancePenalty;

  /// 前句终点在谷起点之后留的余韵。
  final int tailMs;

  /// 后句起点在谷终点之前提前的量。
  final int leadMs;

  /// 吸附后两侧 cue 都不得短于此值，否则不动。
  final int minDurationMs;

  /// 门限 = 附近 ±15 s 电平第 10 百分位（底噪）+ 此值，夹到
  /// [[minThresholdDb], [maxThresholdDb]]。下限比能量 VAD（−55）高：−45 ~ −55 dB
  /// 的气声/混响尾巴听感上已是静音，按 −55 判会把前句终点推迟进停顿里。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 后句新起点不晚于它首 token 发射时刻 + 此值（RNN-T 首 token 一般早于开口，
  /// 比它还晚很多就是吸错了谷、会吃掉字头）。
  final int tokenGuardMs;

  static const int _floorBlockFrames = 250;
  static const int _floorSpanFrames = 750;

  /// [energyDb]：从时间 0 起每 [frameMs] 一帧的电平（整数 dBFS，0 = 未知，按有声
  /// 处理）。就地修改 [cues] 的起止时间，返回挪动的切点数。
  int snap(List<AudioCue> cues, Int8List energyDb) {
    final int n = energyDb.length;
    if (n == 0 || cues.length < 2) return 0;
    final Float64List threshold = _thresholds(energyDb);
    bool quiet(int f) {
      final int v = energyDb[f];
      return v != 0 && v < threshold[f];
    }

    final int minValley = (minValleyMs / frameMs).ceil();
    int moved = 0;
    for (int i = 0; i + 1 < cues.length; i++) {
      final AudioCue cur = cues[i];
      final AudioCue next = cues[i + 1];
      if (cur.audioFileIndex != next.audioFileIndex) continue;
      final int gap = next.startMs - cur.endMs;
      if (gap < 0 || gap > maxGapMs) continue;
      final int b = (cur.endMs + next.startMs) ~/ 2;
      final int f0 = math.max(0, (b - windowMs) ~/ frameMs);
      final int f1 = math.min(n, (b + windowMs) ~/ frameMs);
      int best = -1;
      int bestLen = 0;
      double bestScore = 0;
      int f = f0;
      while (f < f1) {
        if (!quiet(f)) {
          f++;
          continue;
        }
        // 窗口只限定谷落在哪，谷本身量到真实的两端（不被窗口边截断）。
        int s = f;
        while (s > 0 && quiet(s - 1)) {
          s--;
        }
        while (f < n && quiet(f)) {
          f++;
        }
        final int len = f - s;
        if (len < minValley) continue;
        final double center = (s + f) * frameMs / 2;
        final double score =
            len * frameMs - distancePenalty * (center - b).abs();
        if (best < 0 || score > bestScore) {
          best = s;
          bestLen = len;
          bestScore = score;
        }
      }
      if (best < 0) continue;
      final int valleyStart = best * frameMs;
      final int valleyEnd = (best + bestLen) * frameMs;
      final int end = math.min(valleyStart + tailMs, valleyEnd);
      final int start = math.max(
        math.max(valleyEnd - leadMs, valleyStart),
        end,
      );
      if (end - cur.startMs < minDurationMs ||
          next.endMs - start < minDurationMs) {
        continue;
      }
      final int? firstToken = _firstTokenMs(next);
      if (firstToken != null && start > firstToken + tokenGuardMs) continue;
      _shiftStart(next, start);
      cur.endMs = end;
      moved++;
    }
    return moved;
  }

  /// 起止点落在静音里时收回到真实有声处（[snap] 之后跑）。
  ///
  /// [snap] 只管紧挨着的两条 cue；前面是长停顿的起点、后面是长停顿的终点它不碰，
  /// 而那里恰是 token 时刻粗的模型（Kitsune CTC 80 ms 一帧、多字 token 线性摊开，
  /// 同一字相对 RNN-T ±200 ms 散布）最常把字幕挂进静音的地方：
  /// - 起点所在帧是静音 → 往后 [edgeMaxShiftMs] 内找第一段 ≥ [edgeMinVoiceMs] 的
  ///   有声，起点挪到它 − [leadMs]；
  /// - 终点前一帧是静音 → 往前同样找最后一段有声，终点收到它 + [tailMs]，但不早于
  ///   末 token 发射时刻 − [tokenGuardMs]。
  ///
  /// 只往 cue 内部收，不越界、不动文本；挪完短于 [minDurationMs] 的不动。返回
  /// 挪动的边数。
  int refineEdges(List<AudioCue> cues, Int8List energyDb) {
    final int n = energyDb.length;
    if (n == 0 || cues.isEmpty) return 0;
    final Float64List threshold = _thresholds(energyDb);
    bool quiet(int f) {
      final int v = energyDb[f];
      return v != 0 && v < threshold[f];
    }

    final int maxShift = edgeMaxShiftMs ~/ frameMs;
    final int minVoice = (edgeMinVoiceMs / frameMs).ceil();
    int moved = 0;
    for (final AudioCue cue in cues) {
      final int fs = cue.startMs ~/ frameMs;
      if (fs >= 0 && fs < n && quiet(fs)) {
        int f = fs;
        final int limit = math.min(n, fs + maxShift);
        int onset = -1;
        while (f < limit) {
          if (quiet(f)) {
            f++;
            continue;
          }
          int g = f;
          while (g < n && !quiet(g) && g - f < minVoice) {
            g++;
          }
          if (g - f >= minVoice) {
            onset = f;
            break;
          }
          f = g;
        }
        if (onset >= 0) {
          final int start = math.max(cue.startMs, onset * frameMs - edgeLeadMs);
          if (start > cue.startMs && cue.endMs - start >= minDurationMs) {
            _shiftStart(cue, start);
            moved++;
          }
        }
      }
      final int fe = (cue.endMs - 1) ~/ frameMs;
      if (fe >= 0 && fe < n && quiet(fe)) {
        int f = fe;
        final int limit = math.max(-1, fe - maxShift);
        int offset = -1;
        while (f > limit) {
          if (quiet(f)) {
            f--;
            continue;
          }
          int g = f;
          while (g >= 0 && !quiet(g) && f - g < minVoice) {
            g--;
          }
          if (f - g >= minVoice) {
            offset = f;
            break;
          }
          f = g;
        }
        if (offset >= 0) {
          final int end = math.min(
            cue.endMs,
            (offset + 1) * frameMs + edgeTailMs,
          );
          final int? lastToken = _lastTokenMs(cue);
          if (end < cue.endMs &&
              end - cue.startMs >= minDurationMs &&
              (lastToken == null || end >= lastToken - tokenGuardMs)) {
            cue.endMs = end;
            moved++;
          }
        }
      }
    }
    return moved;
  }

  static int? _lastTokenMs(AudioCue cue) {
    final CueTokenTiming? t = cue.tokenTiming;
    if (t == null || t.isEmpty) return null;
    return cue.startMs + t.offsetsMs.last;
  }

  /// 每帧的门限（按 [_floorBlockFrames] 一块算一次局部底噪）。未知帧不参与。
  Float64List _thresholds(Int8List db) {
    final int n = db.length;
    final Float64List out = Float64List(n);
    final List<int> window = <int>[];
    for (int b0 = 0; b0 < n; b0 += _floorBlockFrames) {
      final int lo = math.max(0, b0 - _floorSpanFrames);
      final int hi = math.min(n, b0 + _floorBlockFrames + _floorSpanFrames);
      window.clear();
      for (int k = lo; k < hi; k++) {
        if (db[k] != 0) window.add(db[k]);
      }
      double t = maxThresholdDb;
      if (window.isNotEmpty) {
        window.sort();
        final double floor = window[((window.length - 1) * 10 / 100).round()]
            .toDouble();
        t = (floor + floorMarginDb).clamp(minThresholdDb, maxThresholdDb);
      }
      final int end = math.min(n, b0 + _floorBlockFrames);
      for (int k = b0; k < end; k++) {
        out[k] = t;
      }
    }
    return out;
  }

  static int? _firstTokenMs(AudioCue cue) {
    final CueTokenTiming? t = cue.tokenTiming;
    if (t == null || t.isEmpty) return null;
    return cue.startMs + t.offsetsMs.first;
  }

  /// 挪起点时 token 偏移（相对起点）一起平移，绝对发射时刻不变。
  static void _shiftStart(AudioCue cue, int start) {
    final CueTokenTiming? t = cue.tokenTiming;
    final int delta = start - cue.startMs;
    cue.startMs = start;
    if (t == null || t.isEmpty || delta == 0) return;
    cue.tokenTiming = CueTokenTiming(
      tokens: t.tokens,
      offsetsMs: List<int>.unmodifiable(
        t.offsetsMs.map((int o) => math.max(0, o - delta)),
      ),
    );
  }
}
