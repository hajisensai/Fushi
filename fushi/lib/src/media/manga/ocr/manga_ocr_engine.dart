library;

enum MangaOcrEngineId {
  localOnnx,

  /// 设备自带的文字识别（Android ML Kit 打包模型 / Apple Vision /
  /// Windows.Media.Ocr）。装完即用、完全离线、零上传，但对竖排气泡和手写体
  /// 明显不如 manga-ocr——它是兜底档，不是主力，UI 上必须如实这么说。
  systemOcr,

  googleLens,
  externalMokuro,
  pairedHost,
}

enum MangaOcrEnginePreference {
  auto,
  localOnnx,
  systemOcr,
  googleLens,
  externalMokuro,
  pairedHost,
}

/// 出厂默认引擎偏好——**唯一真相源**。
///
/// BUG-1780：这个默认值曾经有两份。偏好仓库读的是 `'google_lens'`，而设置区
/// `_readEnginePreference()` 在未注入 getter 时回退 `'auto'`。分叉的直接后果不是
/// 显示错乱，而是**守卫恒绿**：UI 测试不注 getter 就走 `auto`，`auto` 算「用得到
/// 本地模型」，于是「出厂默认引擎下模型下载入口整块消失」这个真实回归在测试里
/// 永远复现不出来，一路进了 develop。默认值这种东西只能有一处。
const MangaOcrEnginePreference kDefaultMangaOcrEnginePreference =
    MangaOcrEnginePreference.googleLens;

extension MangaOcrEnginePreferenceKey on MangaOcrEnginePreference {
  String get key {
    switch (this) {
      case MangaOcrEnginePreference.auto:
        return 'auto';
      case MangaOcrEnginePreference.localOnnx:
        return 'local_onnx';
      case MangaOcrEnginePreference.systemOcr:
        return 'system_ocr';
      case MangaOcrEnginePreference.googleLens:
        return 'google_lens';
      case MangaOcrEnginePreference.externalMokuro:
        return 'external_mokuro';
      case MangaOcrEnginePreference.pairedHost:
        return 'paired_host';
    }
  }

  MangaOcrEngineId? get explicitEngine {
    switch (this) {
      case MangaOcrEnginePreference.auto:
        return null;
      case MangaOcrEnginePreference.localOnnx:
        return MangaOcrEngineId.localOnnx;
      case MangaOcrEnginePreference.systemOcr:
        return MangaOcrEngineId.systemOcr;
      case MangaOcrEnginePreference.googleLens:
        return MangaOcrEngineId.googleLens;
      case MangaOcrEnginePreference.externalMokuro:
        return MangaOcrEngineId.externalMokuro;
      case MangaOcrEnginePreference.pairedHost:
        return MangaOcrEngineId.pairedHost;
    }
  }

  static MangaOcrEnginePreference fromKey(String raw) {
    switch (raw) {
      case 'local_onnx':
        return MangaOcrEnginePreference.localOnnx;
      case 'system_ocr':
        return MangaOcrEnginePreference.systemOcr;
      case 'google_lens':
        return MangaOcrEnginePreference.googleLens;
      case 'external_mokuro':
        return MangaOcrEnginePreference.externalMokuro;
      case 'paired_host':
        return MangaOcrEnginePreference.pairedHost;
      case 'auto':
      default:
        return MangaOcrEnginePreference.auto;
    }
  }
}

class MangaOcrEngineCapability {
  const MangaOcrEngineCapability({
    required this.id,
    required this.supported,
    required this.ready,
    required this.requiresNetwork,
    required this.uploadsImages,
    required this.supportsIncremental,
    this.unavailableReason,
  });

  final MangaOcrEngineId id;
  final bool supported;
  final bool ready;
  final bool requiresNetwork;
  final bool uploadsImages;
  final bool supportsIncremental;
  final String? unavailableReason;

  bool get available => supported && ready;
}

/// Resolve automatic OCR without crossing the Google Lens privacy boundary.
///
/// `null` means either no OCR is needed ([hasExistingMetadata]) or no
/// privacy-safe engine is ready. Lens is intentionally absent from this list:
/// it can only be returned by an explicit preference.
MangaOcrEngineId? resolveMangaOcrEngine({
  required MangaOcrEnginePreference preference,
  required bool hasExistingMetadata,
  required Iterable<MangaOcrEngineCapability> capabilities,
}) {
  if (hasExistingMetadata) {
    return null;
  }
  final MangaOcrEngineId? explicit = preference.explicitEngine;
  if (explicit != null) {
    return explicit;
  }
  final Map<MangaOcrEngineId, MangaOcrEngineCapability> byId =
      <MangaOcrEngineId, MangaOcrEngineCapability>{
    for (final MangaOcrEngineCapability capability in capabilities)
      capability.id: capability,
  };
  // 回退顺序 = 质量优先、其次本机可用性。系统 OCR 排在本地模型之后（它识别
  // 竖排气泡明显更差），但排在外部 CLI 和远程主机之前（那两个要么只在桌面存在、
  // 要么要有另一台机器开着）。Lens 依旧刻意缺席：auto 的契约就是不自作主张上传。
  for (final MangaOcrEngineId candidate in const <MangaOcrEngineId>[
    MangaOcrEngineId.localOnnx,
    MangaOcrEngineId.systemOcr,
    MangaOcrEngineId.externalMokuro,
    MangaOcrEngineId.pairedHost,
  ]) {
    if (byId[candidate]?.available == true) {
      return candidate;
    }
  }
  return null;
}
