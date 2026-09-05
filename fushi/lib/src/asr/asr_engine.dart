/// 有声书 ASR 引擎装载：执行后端（EP）选择策略 + 四个 ONNX 会话的创建与释放。
///
/// 策略是纯函数（[selectAsrEncoderProviders] / [recommendAsrEncoderVariant]），
/// IO 只在 [AsrEngineLoader]。会话抽象来自共享层 `onnx_inference.dart`，真实现是
/// `onnx_inference_ort.dart` 的 [OrtOnnxSessionFactory]（与漫画 OCR 同一份）。
library;

import 'dart:developer' as developer;
import 'dart:io';

import 'package:fushi/src/asr/asr_greedy_graph.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';

/// 本子系统的 `dart:developer` 日志通道名（整本转录跑在后台 isolate，理由同
/// `kOnnxLogName`）。
const String kAsrLogName = 'hibiki.asr';

/// 用户对加速的偏好：自动（按平台策略挑 GPU EP）或强制 CPU。
enum AsrAccelerationPreference { auto, cpuOnly }

/// 平台（纯枚举入参，保持策略函数可测纯函数）。
enum AsrPlatform { windows, macos, ios, linux, android }

/// 当前进程所在平台。Fushi 只出这五端，其余（fuchsia 等）直接抛——静默映射到
/// 某一端会让策略在没验证过的平台上装作有依据。
AsrPlatform currentAsrPlatform() {
  if (Platform.isWindows) return AsrPlatform.windows;
  if (Platform.isMacOS) return AsrPlatform.macos;
  if (Platform.isIOS) return AsrPlatform.ios;
  if (Platform.isLinux) return AsrPlatform.linux;
  if (Platform.isAndroid) return AsrPlatform.android;
  throw UnsupportedError(
    'ASR has no execution provider policy for ${Platform.operatingSystem}',
  );
}

/// 编码器的 EP 列表（首项为首选，末项永远是 CPU 兜底）。
///
/// 策略依据是 `ocr_inference.dart` 里 BUG-2050 / BUG-1613 的本机实测（同一个
/// ORT 运行时、同一批 EP），ASR 编码器是单次前向的大模型，与 OCR 检测器同型：
///
/// | 平台 | fp32 编码器 | int8 编码器 |
/// |---|---|---|
/// | Windows | cuda（若 available）→ directml（若 available）→ 否则 CPU | CPU |
/// | macOS / iOS | CPU（CoreML 默认不开，见下） | CPU |
/// | Linux / Android | CPU | CPU |
///
/// - **GPU EP 只给 fp32 编码器**。BUG-2050 实测：int8 量化模型在 ORT 1.22.0 的
///   DirectML EP 上根本建不出会话（`MLOperatorAuthorImpl.cpp(2851)`
///   `E_INVALIDARG`），而同架构 fp32 档建得起来且比 CPU 快 19.4 倍。请求一个注定
///   失败的 EP 只是白付一次建会话再退 CPU，所以 int8 直接 CPU。
/// - **Windows：DirectML 若 available 就用**。这与 OCR 的「一个加速 EP 都不要」
///   不矛盾——OCR 排除 DirectML 的两条理由（int8 检测器建不出会话 / 自回归识别
///   负优化）在这里分别由「只给 fp32」和「decoder/joiner 恒 CPU」（见
///   [AsrEngineLoader.load]）消掉；592 MB 的 fp32 编码器一次前向吃整段音频，正是
///   fp32 检测器那 19.4 倍加速的形态。CUDA 在我们出的 ORT NuGet 里不存在
///   （`microsoft.ml.onnxruntime.directml`，见 `ocr_inference.dart`），但若
///   available 集合里真有它——将来换了带 CUDA EP 的包——就优先于 DirectML。
/// - **macOS / iOS：默认不启用 CoreML，返回 CPU**。BUG-1613：CoreML 对 int8
///   检测器在 iOS 上静默算出空结果、不抛异常不触发回退，可观测性照不到；对
///   fp32 编码器**未实测**。没有真机数据前不开——要开先在真机上拿数
///   （`recommendAsrEncoderVariant` 因此在 Apple 上恒推荐 int8）。
/// - Linux / Android：CPU。
/// - [AsrAccelerationPreference.cpuOnly] 恒 CPU。
/// - 任何加速 EP 后面永远缀 CPU 兜底：运行期建不出会话由
///   `createOnnxSessionWithProviderFallback` 退到 CPU（BUG-2034）。
List<OnnxExecutionProvider> selectAsrEncoderProviders({
  required AsrPlatform platform,
  required Set<OnnxExecutionProvider> available,
  required AsrAccelerationPreference preference,
  required AsrEncoderVariant variant,
}) {
  const List<OnnxExecutionProvider> cpuOnly = <OnnxExecutionProvider>[
    OnnxExecutionProvider.cpu,
  ];
  if (preference == AsrAccelerationPreference.cpuOnly) return cpuOnly;
  if (variant != AsrEncoderVariant.fp32) return cpuOnly;
  final List<OnnxExecutionProvider> preferenceOrder = switch (platform) {
    AsrPlatform.windows => const <OnnxExecutionProvider>[
      OnnxExecutionProvider.cuda,
      OnnxExecutionProvider.directml,
    ],
    // BUG-1613：CoreML 待真机拿数后再开。
    AsrPlatform.macos ||
    AsrPlatform.ios ||
    AsrPlatform.linux ||
    AsrPlatform.android => const <OnnxExecutionProvider>[],
  };
  for (final OnnxExecutionProvider candidate in preferenceOrder) {
    if (!available.contains(candidate)) continue;
    return <OnnxExecutionProvider>[candidate, OnnxExecutionProvider.cpu];
  }
  return cpuOnly;
}

/// 推荐下载 / 加载哪个编码器变体：会选到 GPU EP 就 fp32，否则 int8。
///
/// fp32 比 int8 大 437 MB，只有 GPU 能把这笔磁盘换成速度；CPU 上 int8 反而更快
/// （BUG-2050 对照：int8 CPU 81.5 ms vs fp32 CPU 419.4 ms）。
AsrEncoderVariant recommendAsrEncoderVariant({
  required AsrPlatform platform,
  required Set<OnnxExecutionProvider> available,
  required AsrAccelerationPreference preference,
}) {
  final List<OnnxExecutionProvider> providers = selectAsrEncoderProviders(
    platform: platform,
    available: available,
    preference: preference,
    variant: AsrEncoderVariant.fp32,
  );
  return providers.first == OnnxExecutionProvider.cpu
      ? AsrEncoderVariant.int8
      : AsrEncoderVariant.fp32;
}

/// 一套已装载的 ASR 会话。
class AsrEngineSessions {
  AsrEngineSessions({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.vad,
    required this.tokens,
    required this.variant,
    required this.encoderResolution,
    this.greedy,
    this.greedyUnavailableReason,
  });

  final OnnxSession encoder;
  final OnnxSession decoder;
  final OnnxSession joiner;
  final OnnxSession vad;
  final AsrTokenTable tokens;
  final AsrEncoderVariant variant;

  /// 派生的贪心 Loop 图会话（CPU）；null 表示拼装/建会话失败，解码器回退到
  /// Dart 逐帧循环（结果等价，只是慢）。回退不静默：原因在
  /// [greedyUnavailableReason]，UI/日志据此提示。
  final OnnxSession? greedy;
  final String? greedyUnavailableReason;

  /// 编码器实际落到的 EP 与（若有）降级原因——降级必须可观测（BUG-1163）。
  final OnnxProviderResolution encoderResolution;

  Future<void> close() async {
    await encoder.close();
    await decoder.close();
    await joiner.close();
    await vad.close();
    await greedy?.close();
  }
}

/// 贪心 Loop 图会话的 intra-op 线程数默认值。图里每帧都是 N×512 级别的小矩阵，
/// ORT 默认把全部核心都拉起来做线程同步反而拖慢（Python 侧 int8 N8T250：默认
/// 全核 111 ms，2~4 线程 45 ms）；具体取值以真机扫描为准，见
/// `integration_test/asr_directml_session_lifecycle_itest.dart`。
const int kAsrGreedyGraphIntraOpThreads = 4;

/// 从 [AsrModelStore] 装载四个会话 + 词表。
class AsrEngineLoader {
  AsrEngineLoader({OrtOnnxSessionFactory? factory})
    : _factory = factory ?? OrtOnnxSessionFactory(logName: kAsrLogName);

  final OrtOnnxSessionFactory _factory;

  /// 本机 ORT 运行时编译进来的加速 EP（语义边界见
  /// [OrtOnnxSessionFactory.availableAcceleratedProviders]；不吞异常）。
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() =>
      _factory.availableAcceleratedProviders();

  /// 装载。编码器按 [selectAsrEncoderProviders] 选出的 EP 建（经共享的
  /// provider 回退，resolution 记入 [AsrEngineSessions.encoderResolution]）；
  /// decoder / joiner / vad **恒 CPU**——自回归小 batch 逐帧调用，GPU 往返是负
  /// 优化（OCR 识别器实测同理，见 `ocr_inference.dart`）。
  ///
  /// EP 探测本身抛错时按 CPU 装载，但把探测错误写进 `encoderResolution.
  /// fallbackReason`——有 N 卡也会退到 CPU 是一条真实降级，不允许静默
  /// （BUG-1163）。[AsrAccelerationPreference.cpuOnly] 不探测。
  ///
  /// 中途任一会话建失败时已建成的会话全部关闭再抛，不留 native 泄漏。
  Future<AsrEngineSessions> load({
    required AsrModelStore store,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    bool useGreedyGraph = true,
    int? greedyIntraOpThreads = kAsrGreedyGraphIntraOpThreads,
  }) async {
    Set<OnnxExecutionProvider> available = const <OnnxExecutionProvider>{};
    Object? probeError;
    if (preference != AsrAccelerationPreference.cpuOnly) {
      try {
        available = await _factory.availableAcceleratedProviders();
      } catch (error) {
        probeError = error;
        developer.log(
          'ASR accelerated provider probe failed; assuming CPU only',
          name: kAsrLogName,
          error: error,
        );
      }
    }
    final List<OnnxExecutionProvider> encoderProviders =
        selectAsrEncoderProviders(
          platform: currentAsrPlatform(),
          available: available,
          preference: preference,
          variant: variant,
        );
    const List<OnnxExecutionProvider> cpu = <OnnxExecutionProvider>[
      OnnxExecutionProvider.cpu,
    ];
    final AsrModelRole encoderRole = asrEncoderRole(variant);

    final List<OnnxSession> opened = <OnnxSession>[];
    Future<void> closeOpened() async {
      for (final OnnxSession session in opened) {
        await session.close();
      }
    }

    try {
      OnnxProviderResolution? resolution;
      final OnnxSession encoder = await _factory.createSession(
        store.fileFor(encoderRole).path,
        providers: encoderProviders,
        onProviderResolved: (OnnxProviderResolution r) => resolution = r,
      );
      opened.add(encoder);
      final OnnxProviderResolution encoderResolution = _withProbeError(
        resolution ??
            OnnxProviderResolution(
              requested: encoderProviders,
              effective: encoderProviders.first,
            ),
        probeError,
      );
      final OnnxSession decoder = await _factory.createSession(
        store.fileFor(asrDecoderRole(variant)).path,
        providers: cpu,
      );
      opened.add(decoder);
      final OnnxSession joiner = await _factory.createSession(
        store.fileFor(asrJoinerRole(variant)).path,
        providers: cpu,
      );
      opened.add(joiner);
      final OnnxSession vad = await _factory.createSession(
        store.fileFor(AsrModelRole.vad).path,
        providers: cpu,
      );
      opened.add(vad);
      final AsrTokenTable tokens = AsrTokenTable.parse(
        await store.fileFor(AsrModelRole.tokens).readAsString(),
      );
      // 贪心 Loop 图：拼装或建会话失败都不致命——逐帧路径永远在，但要把原因
      // 留下来（速度差一个量级，用户看到慢要能知道为什么）。
      OnnxSession? greedy;
      String? greedyUnavailableReason;
      if (useGreedyGraph) {
        try {
          final File graphFile = await store.ensureGreedyGraph(
            variant,
            build: buildAsrGreedyGraph,
            blankId: tokens.blankId,
            unkId: tokens.unkId,
          );
          greedy = await _factory.createSession(
            graphFile.path,
            providers: cpu,
            intraOpNumThreads: greedyIntraOpThreads,
          );
          opened.add(greedy);
        } catch (error, stack) {
          greedyUnavailableReason = '$error';
          developer.log(
            'ASR greedy graph unavailable; falling back to per-frame decoding',
            name: kAsrLogName,
            error: error,
            stackTrace: stack,
          );
        }
      }
      developer.log(
        'ASR engine loaded (${variant.name} encoder): $encoderResolution '
        'greedyGraph=${greedy != null}',
        name: kAsrLogName,
      );
      return AsrEngineSessions(
        greedy: greedy,
        greedyUnavailableReason: greedyUnavailableReason,
        encoder: encoder,
        decoder: decoder,
        joiner: joiner,
        vad: vad,
        tokens: tokens,
        variant: variant,
        encoderResolution: encoderResolution,
      );
    } catch (_) {
      await closeOpened();
      rethrow;
    }
  }

  /// 探测失败时把原因并进 resolution：编码器落在 CPU 是探测失败的**后果**，
  /// 不是策略选择，必须以 `fallbackReason` 的形态浮出来。
  static OnnxProviderResolution _withProbeError(
    OnnxProviderResolution resolution,
    Object? probeError,
  ) {
    if (probeError == null) return resolution;
    return OnnxProviderResolution(
      requested: resolution.requested,
      effective: resolution.effective,
      fallbackReason: resolution.fallbackReason == null
          ? 'accelerated provider probe failed: $probeError'
          : '${resolution.fallbackReason}; '
                'accelerated provider probe failed: $probeError',
    );
  }
}
