/// MOSS（audio.cpp CLI + MOSS-Transcribe-Diarize 权重）的后端判定、就绪状态与下载
/// （spec `2026-10-19-video-asr-llm-subtitle-pipeline` 第 4 节平台矩阵）。
///
/// 后端判定（[decideMossBackend]）：
///
/// | 偏好 | Windows x64 | Linux x64 | 其它平台 |
/// |---|---|---|---|
/// | auto | `nvidia-smi` 达 CUDA 13 门槛 → cuda，否则不用 MOSS | 探到任何 GPU → vulkan，否则不用 | 不用 |
/// | cuda | 同 auto 的 CUDA 门槛 | **不可用**：audio.cpp v0.9.2 没发布 Linux CUDA CLI | 不用 |
/// | vulkan / cpu | 直接用 | 直接用 | 不用 |
///
/// Linux 的 auto 走 Vulkan 不走 CUDA 是清单决定的（见上游 `audiocpp_manifest.dart`）；
/// 本机实测同一段 286 s 音频 Vulkan 与 CUDA 的转写 2847 字只差 2 字、耗时约 2 倍。
///
/// 就绪判定只看磁盘（运行库已解压且标记一致、权重摘要已校验），**不在判定时下载**；
/// 下载由 [ensureMossProvisioned] 显式触发。下载走上游 `ModelFileDownloader` 的默认
/// 客户端 `createAsrHttpClient()`，即宿主装进 `asrHttpClientFactory` 的出站工厂——app
/// 与 fushi_server 都在启动时装成 `createAppHttpClient`（代理策略 + 局域网直连闸门），
/// 所以这里不需要再传 client；测试 / 特殊场景可传 `downloader`。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart'
    show MossBackendPreference;
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:path/path.dart' as p;

/// 引擎默认的子进程启动器：经 [HelperProcessRegistry] 登记（退出时统一清理，与
/// ffmpeg 同一套）。宿主不传 `startProcess` 时用它。
Future<Process> engineAsrProcessStarter(
  String executable,
  List<String> arguments,
) => HelperProcessRegistry.instance.start(executable, arguments);

/// MOSS 用不上的原因分类（UI 按它出文案；[MossBackendDecision.reason] 是排查原文）。
enum MossUnavailableCode {
  /// 不是 Windows / Linux x64。
  unsupportedPlatform,

  /// Windows：没有达 CUDA 13 门槛的 NVIDIA 显卡 / 驱动。
  cudaUnavailable,

  /// Linux auto：没探到 GPU。
  noGpu,

  /// 该平台 × 后端 audio.cpp v0.9.2 没发布 CLI（Linux + CUDA）。
  noRuntimeForBackend,

  /// 运行库没下载 / 没装完。
  runtimeMissing,

  /// 权重没下载 / 没校验。
  modelMissing,
}

/// 后端判定结果。
class MossBackendDecision {
  const MossBackendDecision.use(this.platform, this.backend)
    : code = null,
      reason = null;

  const MossBackendDecision.unavailable(
    MossUnavailableCode this.code,
    String this.reason, {
    this.platform,
  }) : backend = null;

  final asr.AudioCppPlatform? platform;

  /// 能用时的后端；不能用为 null。
  final asr.AudioCppBackend? backend;
  final MossUnavailableCode? code;
  final String? reason;

  bool get ok => backend != null;

  /// 能用时对应的运行库清单项。
  asr.AudioCppRuntimePack? get pack => ok && platform != null
      ? asr.audioCppRuntimePackFor(platform!, backend!)
      : null;
}

/// Linux 上「有没有可给 Vulkan 用的 GPU」的探测结果。
class MossLinuxGpuProbe {
  const MossLinuxGpuProbe({required this.found, required this.detail});

  final bool found;

  /// 探到了什么 / 为什么判没有（排查用原文）。
  final String detail;
}

/// 判定用到的环境探测；测试替换成固定结果。
class MossHostProbes {
  const MossHostProbes({
    required this.platform,
    required this.cuda,
    required this.linuxGpu,
  });

  /// 真实探测：平台取当前进程，CUDA 与 GPU 经 [startProcess] 跑 `nvidia-smi`。
  factory MossHostProbes.system({asr.AsrProcessStarter? startProcess}) {
    final asr.AsrProcessStarter starter =
        startProcess ?? engineAsrProcessStarter;
    return MossHostProbes(
      platform: asr.currentAudioCppPlatform,
      cuda: (asr.AudioCppPlatform platform) => asr.probeMossCudaAvailability(
        startProcess: starter,
        platform: platform,
      ),
      linuxGpu: () => probeLinuxGpuForVulkan(startProcess: starter),
    );
  }

  final asr.AudioCppPlatform? Function() platform;
  final Future<asr.MossCudaAvailability> Function(asr.AudioCppPlatform platform)
  cuda;
  final Future<MossLinuxGpuProbe> Function() linuxGpu;
}

/// 系统 Vulkan ICD 清单目录（Khronos loader 的标准搜索路径）。
const List<String> kLinuxVulkanIcdDirs = <String>[
  '/usr/share/vulkan/icd.d',
  '/usr/local/share/vulkan/icd.d',
  '/etc/vulkan/icd.d',
];

/// Linux 有没有 GPU 能跑 audio.cpp 的 Vulkan 后端：
///
/// 1. `nvidia-smi` 列出任何一块卡（不管驱动版本——Vulkan 不受 CUDA 门槛约束）；
/// 2. 否则：有 DRM 渲染节点（`/dev/dri/renderD*`，AMD / Intel / nouveau）**并且**
///    装了一个不是 lavapipe（`lvp_icd`，Mesa 的 CPU 软渲染）的 Vulkan ICD 清单。
///    只有渲染节点没有 ICD = Vulkan 加载器找不到驱动，照样跑不起来。
///
/// 不调 `vulkaninfo`：它是另一个包（vulkan-tools），服务器上多半没装。
Future<MossLinuxGpuProbe> probeLinuxGpuForVulkan({
  asr.AsrProcessStarter? startProcess,
  Directory? devDri,
  List<String> icdDirs = kLinuxVulkanIcdDirs,
}) async {
  final asr.MossCudaAvailability nvidia = await asr.probeMossCudaAvailability(
    startProcess: startProcess ?? engineAsrProcessStarter,
    platform: asr.AudioCppPlatform.linuxX64,
  );
  if (nvidia.gpus.isNotEmpty) {
    return MossLinuxGpuProbe(
      found: true,
      detail: 'nvidia-smi: ${nvidia.gpus.length} GPU(s)',
    );
  }
  final Directory dri = devDri ?? Directory('/dev/dri');
  final List<String> renderNodes = dri.existsSync()
      ? <String>[
          for (final FileSystemEntity e in dri.listSync())
            if (p.basename(e.path).startsWith('renderD')) p.basename(e.path),
        ]
      : const <String>[];
  if (renderNodes.isEmpty) {
    return MossLinuxGpuProbe(
      found: false,
      detail: 'no NVIDIA GPU (${nvidia.reason}) and no /dev/dri/renderD* node',
    );
  }
  final List<String> icds = <String>[
    for (final String dir in icdDirs)
      if (Directory(dir).existsSync())
        for (final FileSystemEntity e in Directory(dir).listSync())
          if (e is File &&
              e.path.endsWith('.json') &&
              !p.basename(e.path).startsWith('lvp_'))
            p.basename(e.path),
  ];
  if (icds.isEmpty) {
    return MossLinuxGpuProbe(
      found: false,
      detail:
          'render node ${renderNodes.join(',')} but no hardware Vulkan ICD '
          'in ${icdDirs.join(', ')}',
    );
  }
  return MossLinuxGpuProbe(
    found: true,
    detail:
        'render node ${renderNodes.join(',')}, Vulkan ICD ${icds.join(',')}',
  );
}

/// 按偏好与本机环境判后端（见文件头的表）。不看运行库 / 权重在不在。
Future<MossBackendDecision> decideMossBackend(
  MossBackendPreference preference, {
  required MossHostProbes probes,
}) async {
  final asr.AudioCppPlatform? platform = probes.platform();
  if (platform == null) {
    return const MossBackendDecision.unavailable(
      MossUnavailableCode.unsupportedPlatform,
      'MOSS (audio.cpp) runs only on Windows / Linux x64',
    );
  }
  Future<MossBackendDecision> cudaOnWindows() async {
    final asr.MossCudaAvailability cuda = await probes.cuda(platform);
    return cuda.available
        ? MossBackendDecision.use(platform, asr.AudioCppBackend.cuda)
        : MossBackendDecision.unavailable(
            MossUnavailableCode.cudaUnavailable,
            cuda.reason ?? 'CUDA unavailable',
            platform: platform,
          );
  }

  switch (preference) {
    case MossBackendPreference.vulkan:
      return MossBackendDecision.use(platform, asr.AudioCppBackend.vulkan);
    case MossBackendPreference.cpu:
      return MossBackendDecision.use(platform, asr.AudioCppBackend.cpu);
    case MossBackendPreference.cuda:
      if (platform == asr.AudioCppPlatform.linuxX64) {
        return MossBackendDecision.unavailable(
          MossUnavailableCode.noRuntimeForBackend,
          'audio.cpp v${asr.kAudioCppVersion} has no Linux CUDA CLI; '
          'use the vulkan backend on NVIDIA GPUs',
          platform: platform,
        );
      }
      return cudaOnWindows();
    case MossBackendPreference.auto:
      if (platform == asr.AudioCppPlatform.windowsX64) return cudaOnWindows();
      final MossLinuxGpuProbe gpu = await probes.linuxGpu();
      return gpu.found
          ? MossBackendDecision.use(platform, asr.AudioCppBackend.vulkan)
          : MossBackendDecision.unavailable(
              MossUnavailableCode.noGpu,
              'no GPU for the Vulkan backend: ${gpu.detail}',
              platform: platform,
            );
  }
}

/// MOSS 的就绪状态：后端判定 + 运行库 + 权重。
class MossProvisionStatus {
  const MossProvisionStatus({
    required this.decision,
    this.runtime,
    this.model,
    this.runtimeDir,
    this.modelPath,
  });

  final MossBackendDecision decision;

  /// 判定能用时才有（不能用时没有要装的运行库）。
  final asr.AudioCppProvisionStatus? runtime;
  final asr.AudioCppProvisionStatus? model;

  /// 运行库目录 / 权重文件的落盘位置（排查与 CLI 显示用）。
  final String? runtimeDir;
  final String? modelPath;

  bool get supported => decision.ok;

  bool get ready =>
      supported && (runtime?.ready ?? false) && (model?.ready ?? false);

  /// 两样合计的下载量 / 还需下载的字节。
  int get totalBytes => (runtime?.totalBytes ?? 0) + (model?.totalBytes ?? 0);
  int get remainingBytes =>
      (runtime?.remainingBytes ?? 0) + (model?.remainingBytes ?? 0);

  /// 朝 [totalBytes] 已拿到的字节（已下完的 + `.part` 残留）。
  int get obtainedBytes =>
      (runtime?.obtainedBytes ?? 0) + (model?.obtainedBytes ?? 0);

  /// 本机用不了 MOSS 的原因（[supported] 为 false 时）；能用为 null。
  String? get unavailableReason => decision.reason;
}

/// 当前机器上 [backend] 偏好的 MOSS 就绪状态（递归量目录，别放热路径）。
///
/// 依赖宿主已装好 `asrSupportRootResolver`（运行库 / 权重落在数据根下）。
Future<MossProvisionStatus> mossProvisionStatus({
  MossBackendPreference backend = MossBackendPreference.auto,
  asr.AsrProcessStarter? startProcess,
  MossHostProbes? probes,
}) async {
  final MossBackendDecision decision = await decideMossBackend(
    backend,
    probes: probes ?? MossHostProbes.system(startProcess: startProcess),
  );
  final asr.AudioCppRuntimePack? pack = decision.pack;
  if (pack == null) return MossProvisionStatus(decision: decision);
  final asr.AudioCppRuntimeStore runtime = await asr.AudioCppRuntimeStore.open(
    pack,
    startProcess: startProcess ?? engineAsrProcessStarter,
  );
  final asr.MossModelStore model = await asr.MossModelStore.open();
  return MossProvisionStatus(
    decision: decision,
    runtime: await runtime.status(),
    model: await model.status(),
    runtimeDir: runtime.dir.path,
    modelPath: model.modelFile.path,
  );
}

/// 下载并装好 [backend] 偏好的运行库与权重（已就绪的部分一个事件都不发）。
///
/// **以 Stream 结束为准**：上游下载器的 `done` 事件在字节下完时就发出，之后才是
/// sha256 校验、解压、写就绪标记；只有这个 Stream 正常结束，MOSS 才真的可用。
/// 校验不符抛 `AudioCppProvisionCorrupt`（坏档已删，重试会重下）；后端判定不能用
/// 时抛 [StateError]（带原因）。
Stream<asr.ModelDownloadEvent> ensureMossProvisioned({
  MossBackendPreference backend = MossBackendPreference.auto,
  asr.AsrProcessStarter? startProcess,
  MossHostProbes? probes,
  asr.ModelFileDownloader? downloader,
  asr.AsrCancellationToken? cancellation,
}) async* {
  final MossBackendDecision decision = await decideMossBackend(
    backend,
    probes: probes ?? MossHostProbes.system(startProcess: startProcess),
  );
  final asr.AudioCppRuntimePack? pack = decision.pack;
  if (pack == null) {
    throw StateError('MOSS unavailable: ${decision.reason}');
  }
  final asr.AudioCppRuntimeStore runtime = await asr.AudioCppRuntimeStore.open(
    pack,
    startProcess: startProcess ?? engineAsrProcessStarter,
  );
  yield* runtime.ensure(downloader: downloader, cancellation: cancellation);
  cancellation?.throwIfCancelled();
  final asr.MossModelStore model = await asr.MossModelStore.open();
  yield* model.ensure(downloader: downloader);
}

/// 本机已落盘的全部 MOSS 文件（每个平台 × 后端的运行库目录 + 权重目录）占的字节。
///
/// 删除前给用户看「会释放多少」用：用户可能切过后端（CUDA 装了又换 Vulkan），只量
/// 当前后端的那份会少报。
Future<int> mossProvisionedDiskBytes() async {
  int total = 0;
  for (final Directory dir in await _mossProvisionedDirs()) {
    if (dir.existsSync()) total += await asr.measureDirectoryBytes(dir);
  }
  return total;
}

/// 删除本机全部 MOSS 运行库（所有后端）与权重，返回释放的字节数。删除后
/// [mossProvisionStatus] 报未就绪、[ensureMossProvisioned] 会整套重下。
///
/// 正在跑的 MOSS 任务由调用方先停：本函数不判断有没有进程在用这些文件（Windows 上
/// 被占用的文件删不掉，异常原样抛出，已删掉的部分不回滚——重下即恢复）。
Future<int> deleteMossProvisioned() async {
  int freed = 0;
  for (final asr.AudioCppRuntimePack pack in asr.kAudioCppRuntimePacks) {
    freed += await (await asr.AudioCppRuntimeStore.open(pack)).deleteAll();
  }
  freed += await (await asr.MossModelStore.open()).deleteAll();
  return freed;
}

Future<List<Directory>> _mossProvisionedDirs() async => <Directory>[
  for (final asr.AudioCppRuntimePack pack in asr.kAudioCppRuntimePacks)
    (await asr.AudioCppRuntimeStore.open(pack)).dir,
  (await asr.MossModelStore.open()).dir,
];
