import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_vad.dart';

/// 静态桶模式下，**最长可能的 VAD 段必须仍装得进最大的桶**。
///
/// 这几个常量分别住在三个文件里（`kAsrStaticMaxSegmentMs` 在 buckets、
/// `speechPadMs`/`minSilenceMs` 在 VAD、`kAsrGpuEncoderBuckets` 在 buckets），
/// 当前余量 42 帧（最长段 10782 ms = 1078 帧，最大桶 1120 帧）。帧数是
/// `(worstMs + 5) ~/ 10`，而 `worstMs = 10032 + speechPad + min(speechPad, minSilence/2)`,
/// 所以 `speechPadMs` 一旦超过 913 就会让**每一个顶格段**掉出最大桶，
/// `bucketFor` 返回 null，于是全程退回动态会话：不崩、不报错、没有日志，
/// 只是 GPU 上 5~7 倍的收益无声消失。这条守卫就是那个余量的账本。
/// 变异实测：`speechPadMs` 改成 950 → 本用例报 `11232ms = 1123 帧 > 1120 帧`。
void main() {
  test('最长 VAD 段的帧数仍落在最大桶内（静态桶模式）', () {
    final AsrVadSegmenter vad = AsrVadSegmenter();

    // VAD 的强制切分发生在「本段已累计 >= maxSegment」的那个窗口结束时，
    // 所以未加 pad 的段最长是 maxSegment + 一个窗口。
    const int windowMs = kAsrVadWindowSamples * 1000 ~/ kAsrSampleRate;
    // 段首 pad 完整；段尾 pad 被 minSilence/2 夹住（相邻段不许互相吃）。
    final int headPadMs = vad.speechPadMs;
    final int tailPadMs = vad.speechPadMs < vad.minSilenceMs ~/ 2
        ? vad.speechPadMs
        : vad.minSilenceMs ~/ 2;

    final int worstMs =
        kAsrStaticMaxSegmentMs + windowMs + headPadMs + tailPadMs;
    final int worstSamples = worstMs * kAsrSampleRate ~/ 1000;
    final int worstFrames = AsrFbank.frameCount(worstSamples);

    final int largestBucketFrames = kAsrGpuEncoderBuckets
        .map((AsrEncoderBucket b) => b.frames)
        .reduce((int a, int b) => a > b ? a : b);

    expect(
      worstFrames,
      lessThanOrEqualTo(largestBucketFrames),
      reason:
          '最长段 ${worstMs}ms = $worstFrames 帧 > 最大桶 $largestBucketFrames 帧：'
          '顶格段会全部掉出桶、静默退回动态会话。要么调小 '
          'kAsrStaticMaxSegmentMs / speechPadMs / minSilenceMs，'
          '要么把最大桶开大（注意桶越大越容易把显存顶到溢出主机内存）',
    );

    // 余量也别太夸张：桶开得远大于实际需要 = 每批都在为不存在的帧付注意力代价
    // （注意力项 ∝ N×T²，这正是三桶方案被砍掉的原因）。
    expect(
      largestBucketFrames - worstFrames,
      lessThan(400),
      reason: '最大桶比最长段富余 ${largestBucketFrames - worstFrames} 帧，白付算力',
    );
  });

  test('每个桶都装得下「刚好用到它」的段，桶表按帧数升序', () {
    int prev = 0;
    for (final AsrEncoderBucket b in kAsrGpuEncoderBuckets) {
      expect(
        b.frames,
        greaterThan(prev),
        reason: '桶表必须按帧数升序：prewarmSmallest 取的是 buckets.first，'
            '乱序会让它预热出最大的那个（显存正是要省的东西）',
      );
      prev = b.frames;
      expect(b.batch, greaterThan(1), reason: '哨兵行不变式要求每桶至少留一行填充');
    }
  });
}
