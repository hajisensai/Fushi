/// Pure-Dart persisted plan for galgame text lookup surfaces.
library;

const String kGalLookupSurfaceProfilePreferencePrefix =
    'gal_lookup_surface_v1::';

enum GalLookupSurfaceMode {
  auto('auto'),
  nativeOnly('nativeOnly'),
  attachedOnly('attachedOnly'),
  off('off');

  const GalLookupSurfaceMode(this.wireName);

  final String wireName;

  static GalLookupSurfaceMode? fromWireName(Object? value) {
    for (final GalLookupSurfaceMode mode in values) {
      if (mode.wireName == value) return mode;
    }
    return null;
  }
}

class GalLookupNormalizedRectV1 {
  const GalLookupNormalizedRectV1({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  bool get isValid =>
      left.isFinite &&
      top.isFinite &&
      width.isFinite &&
      height.isFinite &&
      left >= 0 &&
      top >= 0 &&
      width > 0 &&
      height > 0 &&
      right <= 1 &&
      bottom <= 1;

  Map<String, Object?> toJson() => <String, Object?>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  static GalLookupNormalizedRectV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{'left', 'top', 'width', 'height'})) {
      return null;
    }
    final GalLookupNormalizedRectV1 rect = GalLookupNormalizedRectV1(
      left: _finiteDouble(map['left']) ?? double.nan,
      top: _finiteDouble(map['top']) ?? double.nan,
      width: _finiteDouble(map['width']) ?? double.nan,
      height: _finiteDouble(map['height']) ?? double.nan,
    );
    return rect.isValid ? rect : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupNormalizedRectV1 &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

class GalLookupReferenceClientV1 {
  const GalLookupReferenceClientV1({
    required this.widthPx,
    required this.heightPx,
    required this.dpi,
  });

  final int widthPx;
  final int heightPx;
  final double dpi;

  bool get isValid => widthPx > 0 && heightPx > 0 && dpi.isFinite && dpi > 0;
  double get aspectRatio => widthPx / heightPx;

  Map<String, Object?> toJson() => <String, Object?>{
    'widthPx': widthPx,
    'heightPx': heightPx,
    'dpi': dpi,
  };

  static GalLookupReferenceClientV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{'widthPx', 'heightPx', 'dpi'})) {
      return null;
    }
    final GalLookupReferenceClientV1 client = GalLookupReferenceClientV1(
      widthPx: _exactInt(map['widthPx']) ?? 0,
      heightPx: _exactInt(map['heightPx']) ?? 0,
      dpi: _finiteDouble(map['dpi']) ?? double.nan,
    );
    return client.isValid ? client : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupReferenceClientV1 &&
      other.widthPx == widthPx &&
      other.heightPx == heightPx &&
      other.dpi == dpi;

  @override
  int get hashCode => Object.hash(widthPx, heightPx, dpi);
}

class GalLookupTextLayoutV1 {
  const GalLookupTextLayoutV1({
    this.fontFamily = '',
    this.fontSizePerClientHeight = 0.045,
    this.letterSpacingPerClientHeight = 0,
    this.lineHeight = 1,
    this.textAlign = 'left',
    this.verticalAlign = 'top',
    this.paddingPerClientHeight = 0,
  });

  final String fontFamily;
  final double fontSizePerClientHeight;
  final double letterSpacingPerClientHeight;
  final double lineHeight;
  final String textAlign;
  final String verticalAlign;
  final double paddingPerClientHeight;

  bool get isValid =>
      fontSizePerClientHeight.isFinite &&
      fontSizePerClientHeight > 0 &&
      fontSizePerClientHeight <= 0.25 &&
      letterSpacingPerClientHeight.isFinite &&
      letterSpacingPerClientHeight >= -0.05 &&
      letterSpacingPerClientHeight <= 0.1 &&
      lineHeight.isFinite &&
      lineHeight >= 0.5 &&
      lineHeight <= 4 &&
      const <String>{'left', 'center', 'right'}.contains(textAlign) &&
      const <String>{'top', 'center', 'bottom'}.contains(verticalAlign) &&
      paddingPerClientHeight.isFinite &&
      paddingPerClientHeight >= 0 &&
      paddingPerClientHeight <= 0.25;

  Map<String, Object?> toJson() => <String, Object?>{
    'fontFamily': fontFamily,
    'fontSizePerClientHeight': fontSizePerClientHeight,
    'letterSpacingPerClientHeight': letterSpacingPerClientHeight,
    'lineHeight': lineHeight,
    'textAlign': textAlign,
    'verticalAlign': verticalAlign,
    'paddingPerClientHeight': paddingPerClientHeight,
  };

  static GalLookupTextLayoutV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{
      'fontFamily',
      'fontSizePerClientHeight',
      'letterSpacingPerClientHeight',
      'lineHeight',
      'textAlign',
      'verticalAlign',
      'paddingPerClientHeight',
    })) {
      return null;
    }
    final Object? fontFamily = map['fontFamily'];
    final Object? textAlign = map['textAlign'];
    final Object? verticalAlign = map['verticalAlign'];
    if (fontFamily is! String ||
        textAlign is! String ||
        verticalAlign is! String) {
      return null;
    }
    final GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
      fontFamily: fontFamily,
      fontSizePerClientHeight:
          _finiteDouble(map['fontSizePerClientHeight']) ?? double.nan,
      letterSpacingPerClientHeight:
          _finiteDouble(map['letterSpacingPerClientHeight']) ?? double.nan,
      lineHeight: _finiteDouble(map['lineHeight']) ?? double.nan,
      textAlign: textAlign,
      verticalAlign: verticalAlign,
      paddingPerClientHeight:
          _finiteDouble(map['paddingPerClientHeight']) ?? double.nan,
    );
    return layout.isValid ? layout : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupTextLayoutV1 &&
      other.fontFamily == fontFamily &&
      other.fontSizePerClientHeight == fontSizePerClientHeight &&
      other.letterSpacingPerClientHeight == letterSpacingPerClientHeight &&
      other.lineHeight == lineHeight &&
      other.textAlign == textAlign &&
      other.verticalAlign == verticalAlign &&
      other.paddingPerClientHeight == paddingPerClientHeight;

  @override
  int get hashCode => Object.hash(
    fontFamily,
    fontSizePerClientHeight,
    letterSpacingPerClientHeight,
    lineHeight,
    textAlign,
    verticalAlign,
    paddingPerClientHeight,
  );
}

class GalLookupSurfaceVariantV1 {
  const GalLookupSurfaceVariantV1({
    required this.aspectRatio,
    required this.referenceClient,
    required this.bodyRect,
    required this.layout,
  });

  final double aspectRatio;
  final GalLookupReferenceClientV1 referenceClient;
  final GalLookupNormalizedRectV1 bodyRect;
  final GalLookupTextLayoutV1 layout;

  bool get isValid =>
      aspectRatio.isFinite &&
      aspectRatio > 0 &&
      referenceClient.isValid &&
      bodyRect.isValid &&
      layout.isValid &&
      ((aspectRatio - referenceClient.aspectRatio).abs() /
              referenceClient.aspectRatio) <=
          0.001;

  double relativeAspectError(double currentAspectRatio) =>
      (currentAspectRatio - aspectRatio).abs() / aspectRatio;

  Map<String, Object?> toJson() => <String, Object?>{
    'aspectRatio': aspectRatio,
    'referenceClient': referenceClient.toJson(),
    'bodyRect': bodyRect.toJson(),
    'layout': layout.toJson(),
  };

  static GalLookupSurfaceVariantV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{
      'aspectRatio',
      'referenceClient',
      'bodyRect',
      'layout',
    })) {
      return null;
    }
    final GalLookupReferenceClientV1? client =
        GalLookupReferenceClientV1.tryFromJson(map['referenceClient']);
    final GalLookupNormalizedRectV1? rect =
        GalLookupNormalizedRectV1.tryFromJson(map['bodyRect']);
    final GalLookupTextLayoutV1? layout = GalLookupTextLayoutV1.tryFromJson(
      map['layout'],
    );
    if (client == null || rect == null || layout == null) return null;
    final GalLookupSurfaceVariantV1 variant = GalLookupSurfaceVariantV1(
      aspectRatio: _finiteDouble(map['aspectRatio']) ?? double.nan,
      referenceClient: client,
      bodyRect: rect,
      layout: layout,
    );
    return variant.isValid ? variant : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupSurfaceVariantV1 &&
      other.aspectRatio == aspectRatio &&
      other.referenceClient == referenceClient &&
      other.bodyRect == bodyRect &&
      other.layout == layout;

  @override
  int get hashCode =>
      Object.hash(aspectRatio, referenceClient, bodyRect, layout);
}

/// Exact v1 schema. Unknown keys and invalid nested values reject the complete
/// profile so a partially decoded click plan can never become active.
class GalLookupSurfaceProfileV1 {
  const GalLookupSurfaceProfileV1({
    required this.exePath,
    required this.exeSha256,
    required this.mode,
    required this.unsafeLeftClickAccepted,
    required this.variants,
  });

  static const int schemaVersion = 1;
  static const String inputMode = 'unsafeLeftClick';
  static const String writingMode = 'horizontal';
  static const double maxRelativeAspectError = 0.01;

  final String exePath;
  final String exeSha256;
  final GalLookupSurfaceMode mode;
  final bool unsafeLeftClickAccepted;
  final List<GalLookupSurfaceVariantV1> variants;

  static String normalizeExePath(String value) {
    String normalized = value.trim().replaceAll('/', r'\').toLowerCase();
    final bool isUnc = normalized.startsWith(r'\\');
    if (isUnc) normalized = normalized.substring(2);
    normalized = normalized.replaceAll(RegExp(r'\\+'), r'\');
    return isUnc ? r'\\' + normalized : normalized;
  }

  static String normalizeSha256(String value) => value.trim().toLowerCase();

  static bool isValidSha256(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizeSha256(value));

  static String preferenceKeyForExePath(String exePath) {
    final String normalized = normalizeExePath(exePath);
    if (normalized.isEmpty) {
      throw FormatException('Invalid executable path', exePath);
    }
    return '$kGalLookupSurfaceProfilePreferencePrefix$normalized';
  }

  bool get isStructurallyValid =>
      normalizeExePath(exePath).isNotEmpty &&
      isValidSha256(exeSha256) &&
      variants.every((GalLookupSurfaceVariantV1 variant) => variant.isValid);

  GalLookupSurfaceVariantV1? bestVariantForClient(
    GalLookupReferenceClientV1 client,
  ) {
    if (!client.isValid) return null;
    GalLookupSurfaceVariantV1? best;
    double bestError = double.infinity;
    for (final GalLookupSurfaceVariantV1 variant in variants) {
      final double error = variant.relativeAspectError(client.aspectRatio);
      if (error <= maxRelativeAspectError && error < bestError) {
        best = variant;
        bestError = error;
      }
    }
    return best;
  }

  GalLookupSurfaceVariantV1? nearestVariantForClient(
    GalLookupReferenceClientV1 client,
  ) {
    if (!client.isValid) return null;
    GalLookupSurfaceVariantV1? nearest;
    double nearestError = double.infinity;
    for (final GalLookupSurfaceVariantV1 variant in variants) {
      final double error = variant.relativeAspectError(client.aspectRatio);
      if (error < nearestError) {
        nearest = variant;
        nearestError = error;
      }
    }
    return nearest;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'exePath': normalizeExePath(exePath),
    'exeSha256': normalizeSha256(exeSha256),
    'mode': mode.wireName,
    'unsafeLeftClickAccepted': unsafeLeftClickAccepted,
    'variants': variants
        .map((GalLookupSurfaceVariantV1 variant) => variant.toJson())
        .toList(growable: false),
  };

  static GalLookupSurfaceProfileV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{
          'schemaVersion',
          'exePath',
          'exeSha256',
          'mode',
          'unsafeLeftClickAccepted',
          'variants',
        }) ||
        _exactInt(map['schemaVersion']) != schemaVersion ||
        map['exePath'] is! String ||
        map['exeSha256'] is! String ||
        map['unsafeLeftClickAccepted'] is! bool ||
        map['variants'] is! List) {
      return null;
    }
    final GalLookupSurfaceMode? mode = GalLookupSurfaceMode.fromWireName(
      map['mode'],
    );
    if (mode == null) return null;
    final List<GalLookupSurfaceVariantV1> variants =
        <GalLookupSurfaceVariantV1>[];
    for (final Object? raw in map['variants']! as List<Object?>) {
      final GalLookupSurfaceVariantV1? variant =
          GalLookupSurfaceVariantV1.tryFromJson(raw);
      if (variant == null) return null;
      variants.add(variant);
    }
    final GalLookupSurfaceProfileV1 profile = GalLookupSurfaceProfileV1(
      exePath: normalizeExePath(map['exePath']! as String),
      exeSha256: normalizeSha256(map['exeSha256']! as String),
      mode: mode,
      unsafeLeftClickAccepted: map['unsafeLeftClickAccepted']! as bool,
      variants: List<GalLookupSurfaceVariantV1>.unmodifiable(variants),
    );
    return profile.isStructurallyValid ? profile : null;
  }

  GalLookupSurfaceProfileV1 copyWith({
    String? exeSha256,
    GalLookupSurfaceMode? mode,
    bool? unsafeLeftClickAccepted,
    List<GalLookupSurfaceVariantV1>? variants,
  }) => GalLookupSurfaceProfileV1(
    exePath: exePath,
    exeSha256: exeSha256 ?? this.exeSha256,
    mode: mode ?? this.mode,
    unsafeLeftClickAccepted:
        unsafeLeftClickAccepted ?? this.unsafeLeftClickAccepted,
    variants: List<GalLookupSurfaceVariantV1>.unmodifiable(
      variants ?? this.variants,
    ),
  );
}

bool _hasExactKeys(Map<Object?, Object?> map, Set<String> expected) =>
    map.length == expected.length &&
    map.keys.every((Object? key) => key is String && expected.contains(key));

int? _exactInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final int integer = value.toInt();
  return value.toDouble() == integer.toDouble() ? integer : null;
}

double? _finiteDouble(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}
