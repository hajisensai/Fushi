/// fbank 的 isolate 池。
///
/// `AsrFbank.compute` 是纯 Dart，一批 64 段（fp16 桶）约 130 ms。在转录 isolate
/// 里同步算它会把事件循环堵住 130 ms：GPU 那批的完成回调进不来、下一批发不出去
/// ——2026-09-07 用 nvidia-smi 实测编码阶段 GPU 只忙约 15%，这是三个原因之一
/// （另两个在 `asr_transcribe_job.dart` 的流水线里）。这里把一批段按样本数均衡
/// 切成 [workers] 份，各交给一个 `Isolate.run` 算，主 isolate 只等结果。
///
/// 跨 isolate 的数据走 [TransferableTypedData]：发送侧把一组段拼成一块连续缓冲
/// （一次 memcpy），传输本身零拷贝；结果同样拼成一块回来，再按帧数切成视图。
/// 每段的帧数由样本数决定（[AsrFbank.frameCount]），两侧不必传形状。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// 默认 worker 数：每 4 个逻辑核一个，1~4 个。fbank 一批的活只有 ~130 ms，
/// 再多 worker 摊不到什么，spawn 的固定开销反而占比上去。
int defaultAsrFbankWorkerCount() =>
    (Platform.numberOfProcessors ~/ 4).clamp(1, 4);

class AsrFbankWorkers {
  AsrFbankWorkers({int? workers, this.fbank = const AsrFbank()})
      : workers = workers ?? defaultAsrFbankWorkerCount() {
    if (this.workers < 1) {
      throw ArgumentError.value(workers, 'workers', '至少 1');
    }
  }

  final int workers;
  final AsrFbank fbank;

  /// 逐段算 fbank，结果与逐段调用 [AsrFbank.compute] 逐元素相同、顺序一致。
  Future<List<Float32List>> computeAll(List<Float32List> samples) async {
    if (samples.isEmpty) return const <Float32List>[];
    final List<List<int>> groups = balancedGroups(
      samples.map((Float32List s) => s.length).toList(growable: false),
      workers,
    );
    final List<Float32List> flat = await Future.wait(
      groups.map(
        (List<int> g) => _runGroup(
          g.map((int i) => samples[i]).toList(growable: false),
          fbank,
        ),
      ),
    );
    final List<Float32List> out = List<Float32List>.filled(
      samples.length,
      Float32List(0),
    );
    for (int gi = 0; gi < groups.length; gi++) {
      int offset = 0;
      for (final int i in groups[gi]) {
        final int len = AsrFbank.frameCount(samples[i].length) * kAsrFeatureDim;
        out[i] = Float32List.sublistView(flat[gi], offset, offset + len);
        offset += len;
      }
    }
    return out;
  }

  /// 把 [weights]（每项的工作量）按顺序切成至多 [parts] 段、每段总量尽量接近；
  /// 返回每段的下标列表。项数少于 [parts] 时一项一段。
  static List<List<int>> balancedGroups(List<int> weights, int parts) {
    final int n = math.min(parts, weights.length);
    if (n <= 1) {
      return <List<int>>[List<int>.generate(weights.length, (int i) => i)];
    }
    final int total = weights.fold<int>(0, (int a, int w) => a + w);
    final List<List<int>> groups = <List<int>>[];
    List<int> current = <int>[];
    int acc = 0;
    for (int i = 0; i < weights.length; i++) {
      current.add(i);
      acc += weights[i];
      final int remainingItems = weights.length - i - 1;
      final int remainingGroups = n - groups.length - 1;
      // 目标：本段总量到达 total / n 就切；但要给后面的段各留至少一项。
      if (remainingGroups > 0 &&
          (acc * n >= total * (groups.length + 1) ||
              remainingItems <= remainingGroups)) {
        groups.add(current);
        current = <int>[];
        acc = 0;
      }
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  static Future<Float32List> _runGroup(
    List<Float32List> samples,
    AsrFbank fbank,
  ) async {
    final List<int> lengths =
        samples.map((Float32List s) => s.length).toList(growable: false);
    final TransferableTypedData packed =
        TransferableTypedData.fromList(samples);
    final TransferableTypedData result = await Isolate.run(() {
      final Float32List all = packed.materialize().asFloat32List();
      int offset = 0;
      int outLen = 0;
      for (final int len in lengths) {
        outLen += AsrFbank.frameCount(len) * kAsrFeatureDim;
      }
      final Float32List out = Float32List(outLen);
      int written = 0;
      for (final int len in lengths) {
        final Float32List f = fbank.compute(
          Float32List.sublistView(all, offset, offset + len),
        );
        out.setRange(written, written + f.length, f);
        written += f.length;
        offset += len;
      }
      return TransferableTypedData.fromList(<TypedData>[out]);
    });
    return result.materialize().asFloat32List();
  }
}
