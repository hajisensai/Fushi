import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';

/// 互联「服务端代跑 OCR」客户端的唯一装配点：点名的服务端模型每次探测现读偏好。
/// 向导与三处 OCR 设置区共用，别各自 new 一个漏掉模型偏好。
MangaOcrRemoteRunner createInterconnectMangaOcrRunner(
  AppModel appModel,
  FushiDatabase db,
) =>
    InterconnectMangaOcrClient(
      repo: SyncRepository(db),
      preferredModel: () => appModel.mangaOcrPairedHostModel,
    );

/// 漫画 OCR 大模型识别器的唯一装配点：档位关、没指派（也没默认）提供商、指派的
/// 那家没配全，都回 null——此时整条链路与没有 AI 完全一致，不发任何请求。
///
/// 每次任务开跑时现读偏好（[MangaOcrWizardEngines.aiRefinerFactory]），设置里
/// 改了档位不必重开阅读器。
MangaAiOcrRefiner? createMangaAiOcrRefiner(AppModel appModel) {
  final MangaAiOcrMode mode =
      MangaAiOcrMode.fromStorageKey(appModel.mangaOcrAiMode);
  if (mode == MangaAiOcrMode.off) return null;
  final AiProviderConfig? provider = appModel.prefsRepo.aiFeatureAssignments
      .resolve(AiFeature.mangaOcr, appModel.prefsRepo.aiProviders);
  if (provider == null) return null;
  return MangaAiOcrRefiner(provider: provider, mode: mode);
}

/// 「设置 › AI」里给漫画 OCR 解析到了能用的提供商（不看档位）。设置页用它提示
/// 「档位开了但没人接」。
bool mangaAiOcrProviderReady(AppModel appModel) =>
    appModel.prefsRepo.aiFeatureAssignments.resolve(
      AiFeature.mangaOcr,
      appModel.prefsRepo.aiProviders,
    ) !=
    null;

/// `MangaOcrWizardDialog` 的**整套引擎依赖**（四个引擎的 runner + 默认引擎偏好）。
///
/// 存在的唯一理由是消除一类结构性遗漏：向导有多个入口（导入向导 / 已入库整卷
/// OCR / 将来第三个），而每个引擎在 UI 上出不出现完全由「有没有传对应 runner」
/// 决定。此前每个入口各自手抄一份构造参数表，阅读器入口（`openBookOcr`）抄漏了
/// `remoteRunner`，「配对主机」引擎便在该入口永久不可见（BUG-1418）——这种遗漏
/// 编译期无痕，运行期只表现为「选项少一个」，最受伤的是本地 OCR 引擎不可用、
/// 只能靠配对主机兜底的形态（BUG-1418 当时的安卓正是如此；BUG-1780 后安卓已开本地
/// ONNX，但「少一个选项且没人发现」这个结构性风险与平台无关，依然要靠本类堵住）。
///
/// 收成一个**必填**对象后：① 向导只收 `engines` 一个必填参数，漏传直接编译不过；
/// ② 生产依赖集只在 [MangaOcrWizardEngines.resolve] 里出现一次，新增入口无从抄漏，
/// 新增引擎也只改这一处。
@immutable
class MangaOcrWizardEngines {
  /// 直接装配（widget 测试用：只给需要的引擎，其余 null = 该引擎不出现）。
  const MangaOcrWizardEngines({
    required this.service,
    this.externalRunner,
    this.remoteRunner,
    this.lensRunner,
    this.systemOcrRunner,
    this.initialEnginePreference,
    this.initialLensLanguage,
    this.lensLanguageSetter,
    this.localModel,
    this.localModelSetter,
    this.modelServiceFor,
    this.aiRefinerFactory,
  });

  /// 生产依赖集的**唯一**装配点。所有入口都必须经此，不得再手抄参数表。
  ///
  /// [remoteRunnerOverride] / [desktopOverride] 只是测试缝：前者替换互联客户端，
  /// 后者覆盖「是否桌面平台」（外部 mokuro CLI 只在桌面存在）。
  factory MangaOcrWizardEngines.resolve({
    required BuildContext context,
    required FushiDatabase db,
    MangaOcrRemoteRunner? remoteRunnerOverride,
    bool? desktopOverride,
  }) {
    final ProviderContainer container =
        ProviderScope.containerOf(context, listen: false);
    final AppModel appModel = container.read(appProvider);
    final bool desktop = desktopOverride ?? isDesktopPlatform;
    final String configured = appModel.mangaExternalMokuroPath.trim();
    return MangaOcrWizardEngines(
      service: container.read(mangaOcrServiceProvider),
      externalRunner: desktop
          ? ExternalMokuroRunner(
              configuredPath: configured.isEmpty ? null : configured,
            )
          : null,
      remoteRunner: remoteRunnerOverride ??
          createInterconnectMangaOcrRunner(appModel, db),
      lensRunner: GoogleLensMangaOcrService(),
      systemOcrRunner: SystemOcrMangaService(),
      initialEnginePreference: appModel.mangaOcrEnginePreference,
      initialLensLanguage: appModel.mangaOcrLensLanguage,
      lensLanguageSetter: appModel.setMangaOcrLensLanguage,
      localModel: MangaOcrLocalModel.forPlatform(appModel.mangaOcrLocalModel),
      localModelSetter: appModel.setMangaOcrLocalModel,
      modelServiceFor: (MangaOcrLocalModel model) =>
          createMangaOcrService(localModel: model),
      aiRefinerFactory: () => createMangaAiOcrRefiner(appModel),
    );
  }

  /// 换一个本机模型后的依赖集：[service] 换成该模型的服务，其余不变。
  /// [modelServiceFor] 为 null（测试直连）时原样返回。
  MangaOcrWizardEngines withLocalModel(MangaOcrLocalModel model) {
    final MangaOcrService Function(MangaOcrLocalModel)? serviceFor =
        modelServiceFor;
    if (serviceFor == null) return this;
    return MangaOcrWizardEngines(
      service: serviceFor(model),
      externalRunner: externalRunner,
      remoteRunner: remoteRunner,
      lensRunner: lensRunner,
      systemOcrRunner: systemOcrRunner,
      initialEnginePreference: initialEnginePreference,
      initialLensLanguage: initialLensLanguage,
      lensLanguageSetter: lensLanguageSetter,
      localModel: model,
      localModelSetter: localModelSetter,
      modelServiceFor: modelServiceFor,
      aiRefinerFactory: aiRefinerFactory,
    );
  }

  /// 内置 OCR 服务（接口；真实现由 provider 注入，测试注 fake）。
  final MangaOcrService service;

  /// 外部 mokuro CLI 后备；null = 不提供外部引擎选项（非桌面平台本就没有）。
  final ExternalMokuroRunner? externalRunner;

  /// 漫画 P3：互联「已配对主机代跑 OCR」；null = 不提供远程引擎选项。仅当探测
  /// （probe）到具备 `mangaOcr.supported` 能力的已配对 host 时选项才真正显示。
  final MangaOcrRemoteRunner? remoteRunner;

  /// Google Lens whole-page runner. Null keeps Lens absent in isolated tests.
  final GoogleLensMangaOcrRunner? lensRunner;

  /// 设备自带 OCR；null = 该引擎不出现（隔离测试 / 尚未实现原生侧的平台）。
  /// 注意「runner 非空」只表示代码路径在，能不能真跑要问
  /// [SystemOcrMangaRunner.isAvailable]——原生侧没实现时它回 false。
  final SystemOcrMangaRunner? systemOcrRunner;

  /// 默认引擎偏好键；null 时向导按 `auto` 解析。
  final String? initialEnginePreference;

  /// Lens 识别语言初值（偏好）；null = `ja`。
  final String? initialLensLanguage;

  /// 用户在向导里改语言时回写偏好；null（测试）= 不持久化。
  final void Function(String value)? lensLanguageSetter;

  /// [service] 对应的本机模型；null = 不在向导里提供模型选择（测试直连）。
  ///
  /// 「重新识别本卷」就是为了换引擎 / 换模型重跑，而模型以前只能去设置页改——
  /// 向导里只有一个「本地 ONNX」段，选不了用哪个模型。
  final MangaOcrLocalModel? localModel;

  /// 用户在向导里换模型时回写全局模型偏好（与设置页引擎下拉同一份）。
  final Future<void> Function(String value)? localModelSetter;

  /// 按模型取服务；与 [localModel] 一起非空时向导显示模型选择。
  final MangaOcrService Function(MangaOcrLocalModel model)? modelServiceFor;

  /// 每个任务开跑时取一个大模型识别器（[createMangaAiOcrRefiner]）；工厂为 null
  /// 或返回 null = 不经大模型。工厂而非实例：识别器带「本卷鉴权已失败」的状态，
  /// 不能跨任务共用，也要跟着设置的最新值走。
  final MangaAiOcrRefiner? Function()? aiRefinerFactory;
}
