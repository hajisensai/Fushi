/// 不经对话框、直接用**用户设置的引擎**开跑一卷 OCR。
///
/// 阅读器里「点一下对话框就查词」要的就是这条路：用户已经在设置里选过引擎了，
/// 再让他在弹窗里选第二遍，就是把一次点击变成三次点击。导入向导那条路（选文件夹
/// → 选引擎 → 跑）依然保留，它解决的是另一个问题。
///
/// 这里刻意**不**替用户改引擎：偏好是什么就用什么，不可用就说清楚为什么不可用，
/// 绝不「悄悄换一个能跑的」——那会让 Google Lens 的上传边界在用户不知情时被跨过去。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/utils.dart';

/// 一次「按偏好引擎开跑」的结果。
///
/// 三种结局分得很开，因为它们对用户意味着完全不同的事：任务起来了 / 用户自己
/// 取消了 / 这个引擎现在跑不了（要给出原因）。把后两者混成一个 null，UI 就只能
/// 在「什么都不说」和「乱报错」之间二选一。
class MangaOcrAutoStartResult {
  const MangaOcrAutoStartResult.started(this.job, this.engine)
      : cancelled = false,
        unavailableReason = null;

  const MangaOcrAutoStartResult.cancelled()
      : job = null,
        engine = null,
        cancelled = true,
        unavailableReason = null;

  const MangaOcrAutoStartResult.unavailable(String reason, this.engine)
      : job = null,
        cancelled = false,
        unavailableReason = reason;

  final MangaOcrBackgroundJob? job;

  /// 实际选中的引擎；unavailable 时是「本想用但用不了」的那个。
  final MangaOcrEngineId? engine;

  /// 用户在 Lens 上传告知里点了取消。
  final bool cancelled;

  /// 引擎不可用的人话原因（已本地化，可直接 toast）。
  final String? unavailableReason;

  bool get started => job != null;
}

/// 探测四个引擎的当前可用性。
///
/// 与向导里的探测是同一套判据，但这里不做 UI 态：调用方只需要「能不能跑」。
Future<List<MangaOcrEngineCapability>> probeMangaOcrCapabilities(
  MangaOcrWizardEngines engines,
) async {
  bool builtin = false;
  if (engines.service.isSupportedPlatform) {
    try {
      builtin = (await engines.service.modelStatus()).allReady;
    } catch (_) {
      builtin = false;
    }
  }
  bool external = false;
  if (engines.externalRunner != null) {
    try {
      external = (await engines.externalRunner!.probe()) != null;
    } catch (_) {
      external = false;
    }
  }
  bool system = false;
  if (engines.systemOcrRunner != null) {
    try {
      system = await engines.systemOcrRunner!.isAvailable();
    } catch (_) {
      system = false;
    }
  }
  MangaOcrRemoteTarget? remote;
  if (engines.remoteRunner != null) {
    try {
      remote = await engines.remoteRunner!.probe();
    } catch (_) {
      remote = null;
    }
  }
  return <MangaOcrEngineCapability>[
    MangaOcrEngineCapability(
      id: MangaOcrEngineId.localOnnx,
      supported: engines.service.isSupportedPlatform,
      ready: builtin,
      requiresNetwork: false,
      uploadsImages: false,
      supportsIncremental: true,
    ),
    MangaOcrEngineCapability(
      id: MangaOcrEngineId.systemOcr,
      supported: engines.systemOcrRunner != null,
      // supported 只说明代码路径在；ready 才是「这台设备真有系统 OCR」。原生侧
      // 未实现的平台上 isAvailable() 回 false，选项因此不会假装可用。
      ready: system,
      requiresNetwork: false,
      uploadsImages: false,
      supportsIncremental: true,
    ),
    MangaOcrEngineCapability(
      id: MangaOcrEngineId.googleLens,
      supported: engines.lensRunner != null,
      ready: engines.lensRunner != null,
      requiresNetwork: true,
      uploadsImages: true,
      supportsIncremental: true,
    ),
    MangaOcrEngineCapability(
      id: MangaOcrEngineId.externalMokuro,
      supported: engines.externalRunner != null,
      ready: external,
      requiresNetwork: false,
      uploadsImages: false,
      supportsIncremental: false,
    ),
    MangaOcrEngineCapability(
      id: MangaOcrEngineId.pairedHost,
      supported: engines.remoteRunner != null,
      ready: remote?.capability.usable ?? false,
      requiresNetwork: true,
      uploadsImages: true,
      supportsIncremental: false,
    ),
  ];
}

/// 引擎不可用时的人话原因。
String mangaOcrEngineUnavailableReason(MangaOcrEngineId engine) {
  switch (engine) {
    case MangaOcrEngineId.localOnnx:
      return t.manga_ocr_model_status_missing;
    case MangaOcrEngineId.systemOcr:
      return t.manga_ocr_engine_system_unavailable;
    case MangaOcrEngineId.googleLens:
      return t.manga_ocr_engine_none;
    case MangaOcrEngineId.externalMokuro:
      return t.manga_ocr_external_not_found;
    case MangaOcrEngineId.pairedHost:
      return t.manga_remote_ocr_no_host;
  }
}

/// 用用户设置的引擎开跑，不弹引擎选择。
///
/// [startPage] 是「当前页优先」的起点：Lens 从这里扫到末页再绕回开头，用户点的
/// 那一页最先出结果。
Future<MangaOcrAutoStartResult> startMangaOcrWithPreferredEngine({
  required BuildContext context,
  required String bookKey,
  required String imageDirPath,
  required int startPage,
  required String lensLanguage,
  /// 只有走真实装配（[enginesOverride] 为空）时才需要——[MangaOcrWizardEngines.resolve]
  /// 要用它构造互联客户端。测试注入 engines 时不必给。
  FushiDatabase? db,
  MangaOcrWizardEngines? enginesOverride,
  GoogleLensDisclosureGate? lensDisclosureGate,
  MangaOcrRemoteRunner? remoteRunnerOverride,
}) async {
  final MangaOcrWizardEngines engines = enginesOverride ??
      MangaOcrWizardEngines.resolve(
        context: context,
        db: db!,
        remoteRunnerOverride: remoteRunnerOverride,
      );
  final List<MangaOcrEngineCapability> capabilities =
      await probeMangaOcrCapabilities(engines);

  final MangaOcrEnginePreference preference =
      MangaOcrEnginePreferenceKey.fromKey(
    engines.initialEnginePreference ?? kDefaultMangaOcrEnginePreference.key,
  );
  final MangaOcrEngineId? engine = resolveMangaOcrEngine(
    preference: preference,
    hasExistingMetadata: false,
    capabilities: capabilities,
  );
  if (engine == null) {
    // `auto` 下一个离线引擎都没就绪。刻意不回退到 Lens——auto 的契约就是
    // 「不自作主张上传」。
    return MangaOcrAutoStartResult.unavailable(t.manga_ocr_engine_none, null);
  }

  // 显式偏好会被 resolveMangaOcrEngine 原样返回（那是它的契约：用户选了什么就是
  // 什么）。可用性因此必须在这里自己查一遍，否则会启动一个注定失败的任务，用户
  // 看到的是一句没头没脑的报错。
  final MangaOcrEngineCapability? capability = capabilities
      .where((MangaOcrEngineCapability c) => c.id == engine)
      .firstOrNull;
  if (capability == null || !capability.available) {
    return MangaOcrAutoStartResult.unavailable(
      mangaOcrEngineUnavailableReason(engine),
      engine,
    );
  }

  if (engine == MangaOcrEngineId.googleLens) {
    // 能力探测里有 await（模型状态 / 外部 CLI / 远程 probe），页面可能已经关了。
    // 拿一个已死的 context 去弹上传告知，用户什么都看不到却会被当成「已同意」。
    if (!context.mounted) {
      return const MangaOcrAutoStartResult.cancelled();
    }
    final GoogleLensDisclosureGate gate =
        lensDisclosureGate ?? ensureGoogleLensDisclosure;
    if (!await gate(context)) {
      return const MangaOcrAutoStartResult.cancelled();
    }
  }

  MangaOcrRemoteTarget? remoteTarget;
  if (engine == MangaOcrEngineId.pairedHost) {
    try {
      remoteTarget = await engines.remoteRunner!.probe();
    } catch (_) {
      remoteTarget = null;
    }
    if (remoteTarget == null) {
      return MangaOcrAutoStartResult.unavailable(
        t.manga_remote_ocr_no_host,
        engine,
      );
    }
  }

  return MangaOcrAutoStartResult.started(
    MangaOcrBackgroundJob(
      bookKey: bookKey,
      managedDirectory: imageDirPath,
      engine: engine,
      events: mangaOcrBackgroundEvents(
        MangaOcrJobSpec(
          engine: engine,
          engines: engines,
          imageDirPath: imageDirPath,
          lensLanguage: lensLanguage,
          startPage: startPage,
          remoteTarget: remoteTarget,
        ),
      ),
    ),
    engine,
  );
}
