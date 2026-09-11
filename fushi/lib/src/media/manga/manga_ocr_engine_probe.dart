/// 探测四个 OCR 引擎的可用性并解析默认引擎——与任何 UI 无关。
///
/// 这段逻辑以前只住在 `MangaOcrWizardDialog._refreshEngines` 里，于是「不弹向导
/// 就想知道该用哪个引擎」在结构上做不到。下载完成钩子的自动 OCR（设计稿
/// 2026-09-12 §4）需要在后台做同样的判断，所以把探测和解析收到这里：向导与钩子
/// 读同一份判据，不会出现「向导说本地模型可用、后台钩子却跳过」的分叉。
library;

import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 一次探测的结果。
class MangaOcrEngineAvailability {
  const MangaOcrEngineAvailability({
    required this.builtinSupported,
    required this.builtinReady,
    required this.externalOffered,
    required this.externalReady,
    required this.lensOffered,
    required this.remoteOffered,
    required this.remoteTarget,
  });

  /// 内置 ONNX：平台支持 / 模型齐全。
  final bool builtinSupported;
  final bool builtinReady;

  /// 外部 mokuro CLI：入口给了 runner / probe 到了可执行文件。
  final bool externalOffered;
  final bool externalReady;

  /// Google Lens：入口给了 runner 即可用（它不需要本机资源）。
  final bool lensOffered;

  /// 已配对主机：入口给了 runner / probe 到的目标（null = 没有可用 host）。
  final bool remoteOffered;
  final MangaOcrRemoteTarget? remoteTarget;

  bool get remoteUsable => remoteTarget?.capability.usable ?? false;
  bool get remoteModelsMissing =>
      remoteTarget?.capability.modelsMissing ?? false;

  /// 交给 [resolveMangaOcrEngine] 的能力表。
  List<MangaOcrEngineCapability> get capabilities => <MangaOcrEngineCapability>[
        MangaOcrEngineCapability(
          id: MangaOcrEngineId.localOnnx,
          supported: builtinSupported,
          ready: builtinReady,
          requiresNetwork: false,
          uploadsImages: false,
          supportsIncremental: true,
        ),
        MangaOcrEngineCapability(
          id: MangaOcrEngineId.googleLens,
          supported: lensOffered,
          ready: lensOffered,
          requiresNetwork: true,
          uploadsImages: true,
          supportsIncremental: true,
        ),
        MangaOcrEngineCapability(
          id: MangaOcrEngineId.externalMokuro,
          supported: externalOffered,
          ready: externalReady,
          requiresNetwork: false,
          uploadsImages: false,
          supportsIncremental: false,
        ),
        MangaOcrEngineCapability(
          id: MangaOcrEngineId.pairedHost,
          supported: remoteOffered,
          // 模型没下载的 host 不算 ready，auto 解析不得落到它上面。
          ready: remoteUsable,
          requiresNetwork: true,
          uploadsImages: true,
          supportsIncremental: true,
        ),
      ];

  /// 某个引擎现在能不能真跑（向导里选项的 enabled、钩子里的最终校验共用）。
  bool isUsable(MangaOcrEngineId engine) {
    switch (engine) {
      case MangaOcrEngineId.localOnnx:
        return builtinSupported && builtinReady;
      case MangaOcrEngineId.systemOcr:
        // 系统 OCR 的可用性由原生侧异步回答，向导单独探测；这里不替它作答。
        return true;
      case MangaOcrEngineId.googleLens:
        return lensOffered;
      case MangaOcrEngineId.externalMokuro:
        return externalOffered && externalReady;
      case MangaOcrEngineId.pairedHost:
        return remoteUsable;
    }
  }
}

/// 探测内置模型 / 外部 CLI / 已配对主机三个引擎的可用性。
///
/// 每个探测都各自吞异常成「不可用」：任何一个引擎探测失败都不该让整次判断失败。
Future<MangaOcrEngineAvailability> probeMangaOcrEngines(
  MangaOcrWizardEngines engines,
) async {
  bool builtin = false;
  if (engines.service.isSupportedPlatform) {
    try {
      final MangaOcrModelStatus status = await engines.service.modelStatus();
      builtin = status.allReady;
    } on Object {
      builtin = false;
    }
  }
  bool external = false;
  if (engines.externalRunner != null) {
    try {
      external = (await engines.externalRunner!.probe()) != null;
    } on Object {
      external = false;
    }
  }
  // 漫画 P3：探测已配对 host 的远程 OCR 能力（老 host 无 capabilities 字段 →
  // probe 回 null → 选项隐藏，零破坏）。host 报了「支持但模型未下载」时 probe
  // 仍返回 target，UI 据此置灰 + 说明原因（TODO-2635）。
  MangaOcrRemoteTarget? remote;
  if (engines.remoteRunner != null) {
    try {
      remote = await engines.remoteRunner!.probe();
    } on Object {
      remote = null;
    }
  }
  return MangaOcrEngineAvailability(
    builtinSupported: engines.service.isSupportedPlatform,
    builtinReady: builtin,
    externalOffered: engines.externalRunner != null,
    externalReady: external,
    lensOffered: engines.lensRunner != null,
    remoteOffered: engines.remoteRunner != null,
    remoteTarget: remote,
  );
}

/// 按用户偏好解析出**后台可用**的引擎；解析不到返回 null。
///
/// 与向导的区别只有一条：向导在解析失败时会退到「偏好的显式引擎 / 本地 ONNX」
/// 让用户看到一个置灰的默认项，而后台没有用户在场，解析不到就是不跑。Lens 也
/// 一样：它要用户逐次同意上传，后台不能替用户点，即便偏好显式选了它也跳过。
MangaOcrEngineId? resolveBackgroundMangaOcrEngine({
  required MangaOcrEnginePreference preference,
  required MangaOcrEngineAvailability availability,
}) {
  final MangaOcrEngineId? engine = resolveMangaOcrEngine(
    preference: preference,
    hasExistingMetadata: false,
    capabilities: availability.capabilities,
  );
  if (engine == null || engine == MangaOcrEngineId.googleLens) return null;
  // 显式偏好不经 capabilities 校验（resolveMangaOcrEngine 直接返回它）；后台
  // 必须再确认一次真能跑，否则任务起来就立刻失败、日志里多一条噪声。
  if (!availability.isUsable(engine)) return null;
  return engine;
}
