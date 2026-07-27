library;

enum MangaOcrEngineId {
  localOnnx,
  googleLens,
  externalMokuro,
  pairedHost,
}

enum MangaOcrEnginePreference {
  auto,
  localOnnx,
  googleLens,
  externalMokuro,
}

extension MangaOcrEnginePreferenceKey on MangaOcrEnginePreference {
  String get key {
    switch (this) {
      case MangaOcrEnginePreference.auto:
        return 'auto';
      case MangaOcrEnginePreference.localOnnx:
        return 'local_onnx';
      case MangaOcrEnginePreference.googleLens:
        return 'google_lens';
      case MangaOcrEnginePreference.externalMokuro:
        return 'external_mokuro';
    }
  }

  MangaOcrEngineId? get explicitEngine {
    switch (this) {
      case MangaOcrEnginePreference.auto:
        return null;
      case MangaOcrEnginePreference.localOnnx:
        return MangaOcrEngineId.localOnnx;
      case MangaOcrEnginePreference.googleLens:
        return MangaOcrEngineId.googleLens;
      case MangaOcrEnginePreference.externalMokuro:
        return MangaOcrEngineId.externalMokuro;
    }
  }

  static MangaOcrEnginePreference fromKey(String raw) {
    switch (raw) {
      case 'local_onnx':
        return MangaOcrEnginePreference.localOnnx;
      case 'google_lens':
        return MangaOcrEnginePreference.googleLens;
      case 'external_mokuro':
        return MangaOcrEnginePreference.externalMokuro;
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
  for (final MangaOcrEngineId candidate in const <MangaOcrEngineId>[
    MangaOcrEngineId.localOnnx,
    MangaOcrEngineId.externalMokuro,
    MangaOcrEngineId.pairedHost,
  ]) {
    if (byId[candidate]?.available == true) {
      return candidate;
    }
  }
  return null;
}
