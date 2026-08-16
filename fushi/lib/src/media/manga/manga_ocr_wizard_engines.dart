import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// `MangaOcrWizardDialog` 的**整套引擎依赖**（四个引擎的 runner + 默认引擎偏好）。
///
/// 存在的唯一理由是消除一类结构性遗漏：向导有多个入口（导入向导 / 已入库整卷
/// OCR / 将来第三个），而每个引擎在 UI 上出不出现完全由「有没有传对应 runner」
/// 决定。此前每个入口各自手抄一份构造参数表，阅读器入口（`openBookOcr`）抄漏了
/// `remoteRunner`，「配对主机」引擎便在该入口永久不可见（BUG-1418）——这种遗漏
/// 编译期无痕，运行期只表现为「选项少一个」，最受伤的是没有本地 OCR 引擎兜底的
/// Android。
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
    this.initialEnginePreference,
    this.initialLensLanguage,
    this.lensLanguageSetter,
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
          InterconnectMangaOcrClient(repo: SyncRepository(db)),
      lensRunner: GoogleLensMangaOcrService(),
      initialEnginePreference: appModel.mangaOcrEnginePreference,
      initialLensLanguage: appModel.mangaOcrLensLanguage,
      lensLanguageSetter: appModel.setMangaOcrLensLanguage,
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

  /// 默认引擎偏好键；null 时向导按 `auto` 解析。
  final String? initialEnginePreference;

  /// Lens 识别语言初值（偏好）；null = `ja`。
  final String? initialLensLanguage;

  /// 用户在向导里改语言时回写偏好；null（测试）= 不持久化。
  final void Function(String value)? lensLanguageSetter;
}
