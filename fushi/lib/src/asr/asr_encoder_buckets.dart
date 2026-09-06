/// GPU 上的**静态 shape 编码器桶**。
///
/// 2026-09-06 真机（RTX 4070 Ti，ORT 1.22 DirectML，与随包版本一致）实测：同一个
/// zipformer 编码器，动态 shape 下每次 `Run` 有 ~400 ms 的固定开销且随 T² 恶化
/// （N=32/T=500 → 19k 帧/s，N=32/T=2000 → 14k 帧/s），GPU 利用率只有 11%——
/// 图里四千多个节点每次 run 都要在 CPU 侧重新规划、形状算术节点还落在 CPU 上。
/// 用 `AddFreeDimensionOverrideByName` 把 `N` / `T` 钉死后 ORT 能把整图融合成一个
/// DML 图：N=32/T=500 每次 130 ms → **123k 帧/s**，N=64/T=500 → **147k 帧/s**
/// （5~7 倍），且输出与动态会话逐元素一致。代价：一个桶一份权重（fp32 编码器
/// 260~592 MB 显存）、每个桶建会话 3~8 s，所以按需惰性建、失败即回退动态会话。
///
/// 桶按 fbank 帧数（10 ms/帧）分档；一批必须**恰好**填成 `[batch, frames, 80]`，
/// 不足的行用 fbank pad 值补、输出丢弃。**每批至少留一行哨兵填充行、其
/// `x_lens = frames`**：导出图用 `x_lens.max()` 造注意力掩码，静态图把 T 钉死后
/// 一旦批内最长段短于 T，掩码形状就与编译时不符，DML 的 Where 直接报
/// E_INVALIDARG（2026-09-06 真机复现：`max(x_lens)=T-10` 失败、任一行 `=T` 即过）。
/// 所以真实行封顶 `batch - 1`（[batchCapFor]），填充行一律 `x_lens = frames`。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/onnx/onnx_inference.dart';

/// 编码器输入的符号维度名（两个模型包的导出都是 `x[N, T, 80]`，已核实）。
const String kAsrEncoderBatchDim = 'N';
const String kAsrEncoderTimeDim = 'T';

/// 一个静态 shape 桶：能装下 ≤ [frames] 帧的段，一批恰好 [batch] 行，其中
/// 真实行最多 [realRows]（末尾至少一行哨兵，见文件头）。
@immutable
class AsrEncoderBucket {
  const AsrEncoderBucket({required this.frames, required this.batch})
    : assert(frames > 0),
      assert(batch > 1);

  final int frames;
  final int batch;

  int get realRows => batch - 1;

  @override
  String toString() => 'Bucket(N=$batch, T=$frames)';
}

/// 静态桶模式下 VAD 的单段上限（毫秒）。融合后的静态图会把全部中间张量一起
/// 分配在主机可见内存里，注意力项 ∝ N×T²：T=2100 的桶跑一次主机 RSS 涨 8 GB、
/// T=1000/N=32 涨 2.5 GB（2026-09-06 实测，见 [kAsrGpuEncoderBuckets]），所以静态
/// 模式把段切短到 10 s，让最大桶停在 T≈1100。切点仍由 VAD 在段尾 5 s 窗内取
/// 能量最低处，不是硬切。
const int kAsrStaticMaxSegmentMs = 10000;

/// GPU 默认桶表：两档覆盖静态模式的段上限（10 s + 两侧 0.5 s pad + 帧数取整）。
/// 取值依据（RTX 4070 Ti，ORT 1.22 DML，独占 GPU）见 `docs/agent/` 与本文件头。
///
/// 单会话独占 GPU 实测（帧/s 越高越好；主机 RSS 增量是建会话 + 跑一次）：
///
/// | 桶 | 英语 fp32 | 日语 fp32 | RSS+ |
/// |---|---|---|---|
/// | N=32 T=550 | 129k | 100k | 111 / 151 MB |
/// | N=16 T=1100 | 117k | 100k | 175 / 227 MB |
/// | N=64 T=550 | 149k | 110k | 489 / 503 MB |
/// | N=32 T=1100 | 141k | 112k | 70 / 94 MB（但多桶共存时 VRAM 溢出到主机内存） |
///
/// 动态 shape 同一台机器只有 20~35k 帧/s。取 32×550 + 16×1100：吞吐已到平台
/// 的 8 成，而融合图会把全部中间张量一次分配、各桶池子常驻——桶越大、桶越多，
/// VRAM 就越容易溢出到系统内存（三桶 64/32/16 × 550/1100/2100 曾把测试进程撑到
/// 8 GB 被系统杀掉）。
/// 哪些执行后端真的实现了 free-dimension override —— 也就是静态桶**唯一**能带来
/// 收益的那批。白名单不是黑名单：`freeDimensionOverrides` 只有 vendored
/// flutter_onnxruntime 的 Windows 插件读（`third_party/flutter_onnxruntime/
/// PATCHES.md` delta #8），其它平台插件收到这个 key 直接忽略。写成「不是 CPU」
/// 会让以后新开的任何 EP（BUG-1613 的 CoreML 就在路上）自动拿到一个
/// 「桶建得成、run 也不失败、零收益、且永远不触发回退」的池子。
const Set<OnnxExecutionProvider> kAsrStaticBucketProviders =
    <OnnxExecutionProvider>{OnnxExecutionProvider.directml};

const List<AsrEncoderBucket> kAsrGpuEncoderBuckets = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 560, batch: 32),
  AsrEncoderBucket(frames: 1120, batch: 16),
];

/// 显存吃紧时的半桶（行数减半，融合图常驻的中间张量随之减半）。
const List<AsrEncoderBucket> kAsrGpuEncoderBucketsSmall = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 560, batch: 16),
  AsrEncoderBucket(frames: 1120, batch: 8),
];

const int _kGiB = 1024 * 1024 * 1024;

/// 按显存预算（字节，DXGI 本进程可分配上限；null = 查不到）选桶表：
/// - ≥ 10 GiB：[kAsrGpuEncoderBuckets]（12 GB 卡上 E2E 峰值 6.6~7.6 GB，含动态
///   会话与贪心图）；
/// - 6~10 GiB：[kAsrGpuEncoderBucketsSmall]；
/// - < 6 GiB：空表——静态图溢出到系统内存后比动态会话还慢，不如不建；
/// - null：按默认表试，建失败自会回退（非 Windows 走不到 GPU 桶）。
List<AsrEncoderBucket> asrEncoderBucketsForBudget(int? budgetBytes) {
  if (budgetBytes == null) return kAsrGpuEncoderBuckets;
  if (budgetBytes >= 10 * _kGiB) return kAsrGpuEncoderBuckets;
  if (budgetBytes >= 6 * _kGiB) return kAsrGpuEncoderBucketsSmall;
  return const <AsrEncoderBucket>[];
}

/// 一个已建好的静态桶会话。
class AsrStaticEncoderSession {
  const AsrStaticEncoderSession({required this.bucket, required this.session});

  final AsrEncoderBucket bucket;
  final OnnxSession session;
}

/// 惰性建桶的会话池。建失败（显存不够、EP 不支持静态融合等）的桶记为不可用，
/// 调用方回退动态会话；失败原因留在 [unavailableReasons] 供日志/诊断。
class AsrStaticEncoderPool {
  AsrStaticEncoderPool({
    required OnnxSessionFactory factory,
    required this.modelPath,
    required this.providers,
    this.buckets = kAsrGpuEncoderBuckets,
    this.logName = 'hibiki.asr',
  }) : _factory = factory {
    if (buckets.isEmpty) {
      throw ArgumentError.value(buckets, 'buckets', '至少一个桶');
    }
    for (int i = 1; i < buckets.length; i++) {
      if (buckets[i].frames <= buckets[i - 1].frames) {
        throw ArgumentError.value(buckets, 'buckets', '必须按 frames 递增');
      }
    }
  }

  final OnnxSessionFactory _factory;
  final String modelPath;

  /// 建桶用的 EP 列表——**不带 CPU 兜底**：静态桶只在 GPU 上有意义，GPU 建不出
  /// 来就该回退到已有的动态会话，而不是在 CPU 上再建一份静态图。
  final List<OnnxExecutionProvider> providers;
  final List<AsrEncoderBucket> buckets;
  final String logName;

  final Map<AsrEncoderBucket, AsrStaticEncoderSession> _sessions =
      <AsrEncoderBucket, AsrStaticEncoderSession>{};
  final Map<AsrEncoderBucket, Future<AsrStaticEncoderSession?>> _pending =
      <AsrEncoderBucket, Future<AsrStaticEncoderSession?>>{};
  final Map<AsrEncoderBucket, String> _unavailableReasons =
      <AsrEncoderBucket, String>{};

  /// 建失败 / 运行期失败的桶及原因（只读；诊断与 UI 用）。
  late final Map<AsrEncoderBucket, String> unavailableReasons =
      UnmodifiableMapView<AsrEncoderBucket, String>(_unavailableReasons);
  bool _closed = false;

  /// 能装下 [frames] 帧的最小桶；超过最大桶返回 null（走动态会话）。
  AsrEncoderBucket? bucketFor(int frames) {
    for (final AsrEncoderBucket b in buckets) {
      if (frames <= b.frames) return b;
    }
    return null;
  }

  /// [frames] 帧的段一批最多几行真实段（给成批规则封顶）；无桶时 null。
  int? batchCapFor(int frames) => bucketFor(frames)?.realRows;

  /// 取（必要时建）能装下 [frames] 帧的桶会话；没有合适的桶或建失败返回 null。
  Future<AsrStaticEncoderSession?> sessionFor(int frames) async {
    if (_closed) return null;
    final AsrEncoderBucket? bucket = bucketFor(frames);
    if (bucket == null) return null;
    final AsrStaticEncoderSession? ready = _sessions[bucket];
    if (ready != null) return ready;
    if (_unavailableReasons.containsKey(bucket)) return null;
    return _pending.putIfAbsent(bucket, () => _create(bucket));
  }

  Future<AsrStaticEncoderSession?> _create(AsrEncoderBucket bucket) async {
    final Stopwatch clock = Stopwatch()..start();
    try {
      final OnnxSession session = await _factory.createSession(
        modelPath,
        providers: providers,
        freeDimensionOverrides: <String, int>{
          kAsrEncoderBatchDim: bucket.batch,
          kAsrEncoderTimeDim: bucket.frames,
        },
      );
      if (_closed) {
        await session.close();
        return null;
      }
      final AsrStaticEncoderSession created = AsrStaticEncoderSession(
        bucket: bucket,
        session: session,
      );
      _sessions[bucket] = created;
      developer.log(
        'ASR static encoder $bucket ready in ${clock.elapsedMilliseconds}ms',
        name: logName,
      );
      return created;
    } catch (error, stack) {
      _unavailableReasons[bucket] = '$error';
      developer.log(
        'ASR static encoder $bucket unavailable; falling back to dynamic '
        'session for this bucket',
        name: logName,
        error: error,
        stackTrace: stack,
      );
      return null;
    } finally {
      _pending.remove(bucket);
    }
  }

  /// 把**最小**桶建起来并等它建完。建一个会话 3~8 s：放到第一批需要时再建会让
  /// 转录卡在那里，而不等它建完就开跑，进度与 ETA 会把建桶的停顿算成转录速度
  /// （2026-09-06 A/B：30 分钟样本 wall 多出 ~4 s，全是第一批在等桶）。
  ///
  /// 只预热最小的那个是有意的。每个桶常驻一份编码器权重 + 融合图一次性分配的
  /// 全部中间张量（实测 E2E 峰值 6.6~7.6 GB），而显存不足时 DirectML **不抛
  /// 异常**——它溢出到主机内存，表现是 RSS 暴涨直到进程被系统杀掉，
  /// [markUnavailable] 这条回退路径根本照不到。全预热等于在任何机器上都先把
  /// 两份都占上；按需建则是「真出现长段才多占一份」。
  /// 短素材（段都不超过最小桶）因此只会建一个会话。建失败记原因、不抛。
  Future<void> prewarmSmallest() async {
    if (buckets.isEmpty) return;
    await sessionFor(buckets.first.frames);
  }

  /// 运行期发现该桶不可用（建得起来、`run` 抛错）：关掉会话、记原因，之后
  /// [sessionFor] 对该桶恒返回 null。
  void markUnavailable(
    AsrEncoderBucket bucket,
    Object error,
    StackTrace stack,
  ) {
    _unavailableReasons[bucket] = '$error';
    final AsrStaticEncoderSession? s = _sessions.remove(bucket);
    developer.log(
      'ASR static encoder $bucket failed at run time; disabled, falling back '
      'to dynamic session',
      name: logName,
      error: error,
      stackTrace: stack,
    );
    if (s != null) {
      // 不等关闭：关闭失败也没什么可补救的，别让解码路径挂在这里。
      s.session.close().catchError((Object _) {});
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final Future<AsrStaticEncoderSession?> p in _pending.values.toList()) {
      await p;
    }
    for (final AsrStaticEncoderSession s in _sessions.values) {
      await s.session.close();
    }
    _sessions.clear();
  }
}
