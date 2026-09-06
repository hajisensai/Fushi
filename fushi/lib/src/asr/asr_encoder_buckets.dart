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
  const AsrEncoderBucket({
    required this.frames,
    required this.batch,
    this.sentinel = true,
  }) : assert(frames > 0),
       assert(batch > (sentinel ? 1 : 0));

  /// 时间轴长度：zipformer 桶是 fbank 帧数，CTC（原始波形）桶是样本数。
  final int frames;
  final int batch;

  /// 是否留一行哨兵填充行（zipformer 的 `x_lens.max()` 掩码需要，见文件头）；
  /// 没有长度输入的 CTC 模型不需要，整批都是真实行。
  final bool sentinel;

  int get realRows => sentinel ? batch - 1 : batch;

  /// 行数乘 [factor] 的同帧数桶（fp16 桶表由 fp32 表按 2 倍派生，见
  /// [asrEncoderBucketsForBudget]）。
  AsrEncoderBucket scaledRows(int factor) =>
      AsrEncoderBucket(frames: frames, batch: batch * factor, sentinel: sentinel);

  @override
  bool operator ==(Object other) =>
      other is AsrEncoderBucket &&
      other.frames == frames &&
      other.batch == batch &&
      other.sentinel == sentinel;

  @override
  int get hashCode => Object.hash(frames, batch, sentinel);

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
///
/// **为什么不加更细的短桶**（2026-09-06 A/B，同机、桶预热后、`ASR_BUCKETS` 覆盖）：
/// 段长分布确实偏短——英语 30 分钟 71% 的段 ≤ 5 s，日语 10 分钟 99% ≤ 5 s 且大头
/// 在 1~3 s，560 帧桶被 1~3 s 的段填得很空（日语 padding 3.25x）。但加一档 280 帧：
///
/// | 桶表 | 英语 30 min wall / padding | 日语 10 min wall / padding | 峰值显存（含桌面基线） |
/// |---|---|---|---|
/// | 560×32 + 1120×16 | 6.4 s / 2.19x | 5.2 s / 3.25x | 10.2 / 11.4 GB |
/// | 280×64 + 560×32 + 1120×16 | 11.8 s / 2.19x | 11.1 s / 2.53x | 11.9 / 11.6 GB |
/// | 280×48 + 560×32 + 1120×16 | 6.6 s / 2.11x | 12.2 s / 2.53x | 10.0 / 11.6 GB |
///
/// 英语的 padding 几乎不动：成批按最长段选桶、从最长往下取，短段在到达 280 桶之前
/// 就被 560 桶的批顺手带走了；日语 padding 有降，但第三份常驻权重 + 中间张量把
/// 12 GB 卡顶到溢出，wall 翻倍（280 帧桶单会话吞吐本身正常：64×280 两个模型都
/// 120k 帧/s 以上）。桌面基线本身占 4.5 GB，两桶时本进程约 5.7 GB（英语）/
/// 6.9 GB（日语）；padding 剩下的空间只能靠更多显存换，本机没有。
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

/// 显存宽裕（≥ 16 GiB 预算）时多一档 280 帧桶。上面 A/B 里 280 桶「加了也没用」
/// 有两个前提在 2026-09-06 之后都变了：任务侧改成**按桶分组成批**（短段不再被
/// 560 桶的批顺手带走）、并**跨块攒批**（块末不再冲半批）；剩下的代价只有第三份
/// 常驻权重 + 中间张量，12 GB 卡上会溢出，所以只给 16 GiB 以上的卡。
const List<AsrEncoderBucket> kAsrGpuEncoderBucketsLarge = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 280, batch: 64),
  AsrEncoderBucket(frames: 560, batch: 32),
  AsrEncoderBucket(frames: 1120, batch: 16),
];

/// 显存吃紧时的半桶（行数减半，融合图常驻的中间张量随之减半）。
const List<AsrEncoderBucket> kAsrGpuEncoderBucketsSmall = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 560, batch: 16),
  AsrEncoderBucket(frames: 1120, batch: 8),
];

const int _kGiB = 1024 * 1024 * 1024;

/// fp16 编码器（`asr_fp16_graph.dart`）下每桶行数相对 fp32 表的倍数。
///
/// 一个静态桶的显存 ≈ 权重 + 融合图一次分配的全部中间张量，后者 ∝ N × T 且与元素
/// 字节数成正比：2026-09-07 RTX 5090 实测 fp16 下 560×64 / 1120×32 / 280×128
/// 三种同批面积的桶各占 3.0~3.2 GB，正好是 fp32 同帧数桶的一半——所以同一档
/// 显存预算下 fp16 可以把每桶行数翻倍而占用不变。而吞吐随 N 近乎线性涨到 N=128
/// （560 帧桶：N=32 40 万帧/s → N=64 58 万 → N=128 72 万），fp16 的收益主要靠
/// 这一倍行数拿到（单换精度不换桶只有 1.1×，见 `asr_fp16_graph.dart`）。
const int kAsrFp16BucketRowFactor = 2;

/// 按显存预算（字节，DXGI 本进程可分配上限；null = 查不到）选桶表：
/// - ≥ 16 GiB：[kAsrGpuEncoderBucketsLarge]（多一档 280 帧桶）；
/// - ≥ 10 GiB：[kAsrGpuEncoderBuckets]（12 GB 卡上 E2E 峰值 6.6~7.6 GB，含动态
///   会话与贪心图）；
/// - 6~10 GiB：[kAsrGpuEncoderBucketsSmall]；
/// - < 6 GiB：空表——静态图溢出到系统内存后比动态会话还慢，不如不建；
/// - null：按默认表试，建失败自会回退（非 Windows 走不到 GPU 桶）。
///
/// [fp16] 时每桶行数乘 [kAsrFp16BucketRowFactor]，各档显存占用不变。
List<AsrEncoderBucket> asrEncoderBucketsForBudget(
  int? budgetBytes, {
  bool fp16 = false,
}) {
  final List<AsrEncoderBucket> fp32Table;
  if (budgetBytes == null) {
    fp32Table = kAsrGpuEncoderBuckets;
  } else if (budgetBytes >= 16 * _kGiB) {
    fp32Table = kAsrGpuEncoderBucketsLarge;
  } else if (budgetBytes >= 10 * _kGiB) {
    fp32Table = kAsrGpuEncoderBuckets;
  } else if (budgetBytes >= 6 * _kGiB) {
    fp32Table = kAsrGpuEncoderBucketsSmall;
  } else {
    return const <AsrEncoderBucket>[];
  }
  if (!fp16) return fp32Table;
  return List<AsrEncoderBucket>.unmodifiable(
    fp32Table.map(
      (AsrEncoderBucket b) => b.scaledRows(kAsrFp16BucketRowFactor),
    ),
  );
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
    this.batchDimName = kAsrEncoderBatchDim,
    this.timeDimName = kAsrEncoderTimeDim,
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

  /// 模型输入上要钉死的两个符号维名（zipformer `N` / `T`，Omnilingual
  /// `N` / `num_samples`）。
  final String batchDimName;
  final String timeDimName;
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
          batchDimName: bucket.batch,
          timeDimName: bucket.frames,
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

  /// 把全部桶建起来并等建完。只在显存预算已知且够放整张桶表时用（见
  /// `asr_engine.dart` 的预热策略）；建失败的桶各自记原因、不抛。
  Future<void> prewarmAll() async {
    await Future.wait<AsrStaticEncoderSession?>(
      <Future<AsrStaticEncoderSession?>>[
        for (final AsrEncoderBucket b in buckets) sessionFor(b.frames),
      ],
    );
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

  /// 关闭已建成的桶会话。**不等**还在建的桶：建一个桶 3~8 s，用户在转录刚开始
  /// 点取消不该干等；[_create] 见到 `_closed` 会在建成的那一刻自己把会话关掉。
  Future<void> close() async {
    _closed = true;
    final List<AsrStaticEncoderSession> ready = _sessions.values.toList();
    _sessions.clear();
    for (final AsrStaticEncoderSession s in ready) {
      await s.session.close();
    }
  }
}
