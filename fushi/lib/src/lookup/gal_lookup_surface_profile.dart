/// Pure-Dart persisted plan for galgame text lookup surfaces.
library;

import 'dart:math' as math;

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

/// The two optional calibration slots exposed by the game lookup workbench.
/// A null slot on a stored variant is the legacy shared calibration.
enum GalLookupCalibrationSlotV1 {
  dialogue('dialogue'),
  narration('narration');

  const GalLookupCalibrationSlotV1(this.wireName);

  final String wireName;

  static GalLookupCalibrationSlotV1? fromWireName(Object? value) {
    for (final GalLookupCalibrationSlotV1 slot in values) {
      if (slot.wireName == value) return slot;
    }
    return null;
  }
}

/// Classifies text containing a Japanese dialogue quote. The hook may append
/// line breaks, punctuation, or other text around the visible quote, and some
/// engines may expose only one side while a line is being updated. The user's
/// calibration rule is that any Japanese dialogue quote marker means dialogue.
bool isGalLookupDialogueText(String text) {
  final String value = text.trim();
  if (value.isEmpty) return false;
  return value.contains('「') ||
      value.contains('」') ||
      value.contains('『') ||
      value.contains('』');
}

/// Select the first Japanese dialogue quote for grid fitting without changing
/// the stored Hook text or native hit indexes.
String galLookupGridSourceText(String source, {required bool quotedTextOnly}) {
  if (!quotedTextOnly) return source;
  final int start = source.indexOf('「');
  if (start < 0) return source;
  final int close = source.indexOf('」', start + 1);
  return source.substring(start, close < 0 ? null : close + 1);
}

/// Per-game visible/card text. Keep the captured Hook line unchanged so source
/// matching, audio identity and UTF-16 hit positions remain stable.
({String text, int sourceOffset}) galLookupVisibleHookLineText({
  required String source,
  required bool currentSession,
  required String? sessionExecutable,
  required String? attachedExecutable,
  required String? attachedSha256,
  required GalLookupSurfaceProfileV1? profile,
  required GalLookupReferenceClientV1? client,
}) {
  final ({String text, int sourceOffset}) original = (
    text: source,
    sourceOffset: 0,
  );
  if (!currentSession ||
      sessionExecutable == null ||
      attachedExecutable == null ||
      attachedSha256 == null ||
      profile == null ||
      client == null) {
    return original;
  }
  final String sessionPath = GalLookupSurfaceProfileV1.normalizeExePath(
    sessionExecutable,
  );
  final String attachedPath = GalLookupSurfaceProfileV1.normalizeExePath(
    attachedExecutable,
  );
  if (sessionPath != attachedPath ||
      attachedPath !=
          GalLookupSurfaceProfileV1.normalizeExePath(profile.exePath) ||
      GalLookupSurfaceProfileV1.normalizeSha256(attachedSha256) !=
          GalLookupSurfaceProfileV1.normalizeSha256(profile.exeSha256)) {
    return original;
  }
  final bool quotedTextOnly =
      profile.bestVariantForSourceText(client, source)?.layout.quotedTextOnly ??
      false;
  final String visible = galLookupGridSourceText(
    source,
    quotedTextOnly: quotedTextOnly,
  );
  if (visible == source) return original;
  return (text: visible, sourceOffset: source.indexOf('「'));
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

class GalLookupCellGridV1 {
  const GalLookupCellGridV1({
    required this.advancePerClientHeight,
    required this.lineAdvancePerClientHeight,
    required this.cellHeightPerClientHeight,
    required this.columns,
    required this.continuationIndent,
    required this.quotedContinuationIndent,
    this.hangingPunctuation = false,
    this.trimWrapWhitespace = false,
    this.explicitLineBreaks = false,
    this.lineWidthInCells,
  });

  final double advancePerClientHeight;
  final double lineAdvancePerClientHeight;
  final double cellHeightPerClientHeight;
  final int columns;

  /// Signed shift of later rows relative to the first row. A negative value
  /// places the first row inside the common body and starts later rows at its
  /// left edge. Existing nonnegative profiles retain their original meaning.
  final double continuationIndent;
  final double quotedContinuationIndent;
  final bool hangingPunctuation;
  final bool trimWrapWhitespace;

  /// Calibration proved this game's rows come from Hook line breaks, so the
  /// runtime never wraps at the calibrated width and rows may extend past the
  /// calibrated body to the client edge. Absent in older profiles (false).
  final bool explicitLineBreaks;
  final double? lineWidthInCells;

  GalLookupCellGridV1 copyWith({
    double? advancePerClientHeight,
    double? lineAdvancePerClientHeight,
    double? cellHeightPerClientHeight,
    double? continuationIndent,
    double? quotedContinuationIndent,
  }) => GalLookupCellGridV1(
    advancePerClientHeight:
        advancePerClientHeight ?? this.advancePerClientHeight,
    lineAdvancePerClientHeight:
        lineAdvancePerClientHeight ?? this.lineAdvancePerClientHeight,
    cellHeightPerClientHeight:
        cellHeightPerClientHeight ?? this.cellHeightPerClientHeight,
    columns: columns,
    continuationIndent: continuationIndent ?? this.continuationIndent,
    quotedContinuationIndent:
        quotedContinuationIndent ?? this.quotedContinuationIndent,
    hangingPunctuation: hangingPunctuation,
    trimWrapWhitespace: trimWrapWhitespace,
    explicitLineBreaks: explicitLineBreaks,
    lineWidthInCells: lineWidthInCells,
  );

  /// OCR can measure a fractional last line width while [columns] remains the
  /// legacy integer fallback.
  double get effectiveLineWidthInCells =>
      lineWidthInCells ?? columns.toDouble();

  bool get isValid =>
      advancePerClientHeight.isFinite &&
      advancePerClientHeight >= 0.001 &&
      advancePerClientHeight <= 0.25 &&
      lineAdvancePerClientHeight.isFinite &&
      lineAdvancePerClientHeight >= 0.001 &&
      lineAdvancePerClientHeight <= 0.25 &&
      cellHeightPerClientHeight.isFinite &&
      cellHeightPerClientHeight >= 0.001 &&
      cellHeightPerClientHeight <= 0.25 &&
      lineAdvancePerClientHeight >= cellHeightPerClientHeight &&
      columns >= 2 &&
      columns <= 128 &&
      (lineWidthInCells == null ||
          (lineWidthInCells!.isFinite &&
              lineWidthInCells! >= 2 &&
              lineWidthInCells! <= 128)) &&
      continuationIndent.isFinite &&
      continuationIndent >= -1 &&
      continuationIndent <= _maximumIndent &&
      quotedContinuationIndent.isFinite &&
      quotedContinuationIndent >= -1 &&
      quotedContinuationIndent <= _maximumIndent;

  double get _maximumIndent => math.min(columns - 1, 8).toDouble();

  Map<String, Object?> toJson() {
    final Map<String, Object?> result = <String, Object?>{
      'advancePerClientHeight': advancePerClientHeight,
      'lineAdvancePerClientHeight': lineAdvancePerClientHeight,
      'cellHeightPerClientHeight': cellHeightPerClientHeight,
      'columns': columns,
      'continuationIndent': continuationIndent,
      'quotedContinuationIndent': quotedContinuationIndent,
    };
    if (hangingPunctuation) result['hangingPunctuation'] = true;
    if (trimWrapWhitespace) result['trimWrapWhitespace'] = true;
    if (explicitLineBreaks) result['explicitLineBreaks'] = true;
    if (lineWidthInCells != null) {
      result['lineWidthInCells'] = lineWidthInCells;
    }
    return result;
  }

  static GalLookupCellGridV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    const Set<String> legacyKeys = <String>{
      'advancePerClientHeight',
      'lineAdvancePerClientHeight',
      'cellHeightPerClientHeight',
      'columns',
      'continuationIndent',
      'quotedContinuationIndent',
    };
    // Every legacy key is required; each optional key may appear on its own.
    const Set<String> optionalKeys = <String>{
      'hangingPunctuation',
      'trimWrapWhitespace',
      'explicitLineBreaks',
      'lineWidthInCells',
    };
    if (!legacyKeys.every(map.containsKey) ||
        !map.keys.every(
          (Object? key) =>
              legacyKeys.contains(key) || optionalKeys.contains(key),
        )) {
      return null;
    }
    final Object? hangingPunctuationValue = map['hangingPunctuation'];
    if (map.containsKey('hangingPunctuation') &&
        hangingPunctuationValue is! bool) {
      return null;
    }
    final bool hangingPunctuation = hangingPunctuationValue is bool
        ? hangingPunctuationValue
        : false;
    final Object? trimWrapWhitespaceValue = map['trimWrapWhitespace'];
    if (map.containsKey('trimWrapWhitespace') &&
        trimWrapWhitespaceValue is! bool) {
      return null;
    }
    final bool trimWrapWhitespace = trimWrapWhitespaceValue is bool
        ? trimWrapWhitespaceValue
        : false;
    final Object? explicitLineBreaksValue = map['explicitLineBreaks'];
    if (map.containsKey('explicitLineBreaks') &&
        explicitLineBreaksValue is! bool) {
      return null;
    }
    final bool explicitLineBreaks = explicitLineBreaksValue is bool
        ? explicitLineBreaksValue
        : false;
    final double? lineWidthInCells = map.containsKey('lineWidthInCells')
        ? _finiteDouble(map['lineWidthInCells'])
        : null;
    if (map.containsKey('lineWidthInCells') && lineWidthInCells == null) {
      return null;
    }
    final GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight:
          _finiteDouble(map['advancePerClientHeight']) ?? double.nan,
      lineAdvancePerClientHeight:
          _finiteDouble(map['lineAdvancePerClientHeight']) ?? double.nan,
      cellHeightPerClientHeight:
          _finiteDouble(map['cellHeightPerClientHeight']) ?? double.nan,
      columns: _exactInt(map['columns']) ?? 0,
      continuationIndent:
          _finiteDouble(map['continuationIndent']) ?? double.nan,
      quotedContinuationIndent:
          _finiteDouble(map['quotedContinuationIndent']) ?? double.nan,
      hangingPunctuation: hangingPunctuation,
      trimWrapWhitespace: trimWrapWhitespace,
      explicitLineBreaks: explicitLineBreaks,
      lineWidthInCells: lineWidthInCells,
    );
    return grid.isValid ? grid : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupCellGridV1 &&
      other.advancePerClientHeight == advancePerClientHeight &&
      other.lineAdvancePerClientHeight == lineAdvancePerClientHeight &&
      other.cellHeightPerClientHeight == cellHeightPerClientHeight &&
      other.columns == columns &&
      other.continuationIndent == continuationIndent &&
      other.quotedContinuationIndent == quotedContinuationIndent &&
      other.hangingPunctuation == hangingPunctuation &&
      other.trimWrapWhitespace == trimWrapWhitespace &&
      other.explicitLineBreaks == explicitLineBreaks &&
      other.lineWidthInCells == lineWidthInCells;

  @override
  int get hashCode => Object.hash(
    advancePerClientHeight,
    lineAdvancePerClientHeight,
    cellHeightPerClientHeight,
    columns,
    continuationIndent,
    quotedContinuationIndent,
    hangingPunctuation,
    trimWrapWhitespace,
    explicitLineBreaks,
    lineWidthInCells,
  );
}

/// A screenshot-backed visual box for one punctuation code point.
///
/// The coordinates are fractions of that character's cell.  They only affect
/// paint/anchor geometry; the cell's advance and hit region remain unchanged.
class GalLookupPunctuationVisualBoundV1 {
  const GalLookupPunctuationVisualBoundV1({
    required this.codePoint,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  static const int maxEntriesPerLayout = 32;
  static const double minExtent = 0.02;
  static final RegExp _punctuationOrSymbol = RegExp(
    r'^[\p{P}\p{S}]$',
    unicode: true,
  );

  final int codePoint;
  final double left;
  final double top;
  final double right;
  final double bottom;

  String get character => String.fromCharCode(codePoint);

  bool get isValid {
    if (codePoint < 0x20 ||
        codePoint > 0xffff ||
        (codePoint >= 0xd800 && codePoint <= 0xdfff) ||
        !_punctuationOrSymbol.hasMatch(character)) {
      return false;
    }
    return left.isFinite &&
        top.isFinite &&
        right.isFinite &&
        bottom.isFinite &&
        left >= 0 &&
        top >= 0 &&
        right <= 1 &&
        bottom <= 1 &&
        right - left >= minExtent &&
        bottom - top >= minExtent &&
        right > left &&
        bottom > top;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'codePoint': codePoint,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  static GalLookupPunctuationVisualBoundV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{
      'codePoint',
      'left',
      'top',
      'right',
      'bottom',
    })) {
      return null;
    }
    final GalLookupPunctuationVisualBoundV1 bound =
        GalLookupPunctuationVisualBoundV1(
          codePoint: _exactInt(map['codePoint']) ?? -1,
          left: _finiteDouble(map['left']) ?? double.nan,
          top: _finiteDouble(map['top']) ?? double.nan,
          right: _finiteDouble(map['right']) ?? double.nan,
          bottom: _finiteDouble(map['bottom']) ?? double.nan,
        );
    return bound.isValid ? bound : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupPunctuationVisualBoundV1 &&
      other.codePoint == codePoint &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(codePoint, left, top, right, bottom);
}

/// A per-character advance override measured from the game's actual layout.
/// The cell height remains the shared grid height; only the standard advance
/// and all following hit positions are multiplied by [advanceRatio].
class GalLookupCharacterAdvanceV1 {
  const GalLookupCharacterAdvanceV1({
    required this.codePoint,
    required this.advanceRatio,
  });

  static const int maxEntriesPerLayout = 64;
  static const double minAdvanceRatio = 0.15;
  static const double maxAdvanceRatio = 2.0;
  static final RegExp _controlOrFormat = RegExp(
    r'^[\p{Cc}\p{Cf}]$',
    unicode: true,
  );

  final int codePoint;
  final double advanceRatio;

  String get character => String.fromCharCode(codePoint);

  bool get isValid {
    if (codePoint < 0 ||
        codePoint > 0x10ffff ||
        (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
      return false;
    }
    final String value = character;
    return (value == ' ' || value.trim().isNotEmpty) &&
        !_controlOrFormat.hasMatch(value) &&
        advanceRatio.isFinite &&
        advanceRatio >= minAdvanceRatio &&
        advanceRatio <= maxAdvanceRatio;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'codePoint': codePoint,
    'advanceRatio': advanceRatio,
  };

  static GalLookupCharacterAdvanceV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    if (!_hasExactKeys(map, const <String>{'codePoint', 'advanceRatio'})) {
      return null;
    }
    final GalLookupCharacterAdvanceV1 advance = GalLookupCharacterAdvanceV1(
      codePoint: _exactInt(map['codePoint']) ?? -1,
      advanceRatio: _finiteDouble(map['advanceRatio']) ?? double.nan,
    );
    return advance.isValid ? advance : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupCharacterAdvanceV1 &&
      other.codePoint == codePoint &&
      other.advanceRatio == advanceRatio;

  @override
  int get hashCode => Object.hash(codePoint, advanceRatio);
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
    this.cellGrid,
    this.quotedTextOnly = false,
    this.punctuationVisualBounds = const <GalLookupPunctuationVisualBoundV1>[],
    this.characterAdvances = const <GalLookupCharacterAdvanceV1>[],
  });

  final String fontFamily;
  final double fontSizePerClientHeight;
  final double letterSpacingPerClientHeight;
  final double lineHeight;
  final String textAlign;
  final String verticalAlign;
  final double paddingPerClientHeight;
  final GalLookupCellGridV1? cellGrid;
  final bool quotedTextOnly;
  final List<GalLookupPunctuationVisualBoundV1> punctuationVisualBounds;
  final List<GalLookupCharacterAdvanceV1> characterAdvances;

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
      paddingPerClientHeight <= 0.25 &&
      (cellGrid == null || cellGrid!.isValid) &&
      punctuationVisualBounds.length <=
          GalLookupPunctuationVisualBoundV1.maxEntriesPerLayout &&
      characterAdvances.length <=
          GalLookupCharacterAdvanceV1.maxEntriesPerLayout &&
      (punctuationVisualBounds.isEmpty || cellGrid != null) &&
      (characterAdvances.isEmpty || cellGrid != null) &&
      punctuationVisualBounds.every(
        (GalLookupPunctuationVisualBoundV1 bound) => bound.isValid,
      ) &&
      punctuationVisualBounds
              .map((GalLookupPunctuationVisualBoundV1 bound) => bound.codePoint)
              .toSet()
              .length ==
          punctuationVisualBounds.length &&
      characterAdvances.every(
        (GalLookupCharacterAdvanceV1 advance) => advance.isValid,
      ) &&
      characterAdvances
              .map((GalLookupCharacterAdvanceV1 advance) => advance.codePoint)
              .toSet()
              .length ==
          characterAdvances.length;

  Map<String, Object?> toJson() {
    final Map<String, Object?> result = <String, Object?>{
      'fontFamily': fontFamily,
      'fontSizePerClientHeight': fontSizePerClientHeight,
      'letterSpacingPerClientHeight': letterSpacingPerClientHeight,
      'lineHeight': lineHeight,
      'textAlign': textAlign,
      'verticalAlign': verticalAlign,
      'paddingPerClientHeight': paddingPerClientHeight,
    };
    if (cellGrid != null) result['cellGrid'] = cellGrid!.toJson();
    if (quotedTextOnly) result['quotedTextOnly'] = true;
    if (punctuationVisualBounds.isNotEmpty) {
      final List<GalLookupPunctuationVisualBoundV1> sorted =
          List<GalLookupPunctuationVisualBoundV1>.of(punctuationVisualBounds)
            ..sort(
              (
                GalLookupPunctuationVisualBoundV1 a,
                GalLookupPunctuationVisualBoundV1 b,
              ) => a.codePoint.compareTo(b.codePoint),
            );
      result['punctuationVisualBounds'] = sorted
          .map((GalLookupPunctuationVisualBoundV1 bound) => bound.toJson())
          .toList(growable: false);
    }
    if (characterAdvances.isNotEmpty) {
      final List<GalLookupCharacterAdvanceV1> sorted =
          List<GalLookupCharacterAdvanceV1>.of(characterAdvances)..sort(
            (GalLookupCharacterAdvanceV1 a, GalLookupCharacterAdvanceV1 b) =>
                a.codePoint.compareTo(b.codePoint),
          );
      result['characterAdvances'] = sorted
          .map((GalLookupCharacterAdvanceV1 advance) => advance.toJson())
          .toList(growable: false);
    }
    return result;
  }

  static GalLookupTextLayoutV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    const Set<String> legacyKeys = <String>{
      'fontFamily',
      'fontSizePerClientHeight',
      'letterSpacingPerClientHeight',
      'lineHeight',
      'textAlign',
      'verticalAlign',
      'paddingPerClientHeight',
    };
    const Set<String> optionalKeys = <String>{
      'cellGrid',
      'quotedTextOnly',
      'punctuationVisualBounds',
      'characterAdvances',
    };
    if (!legacyKeys.every(map.containsKey) ||
        map.keys.any(
          (Object? key) =>
              key is! String ||
              (!legacyKeys.contains(key) && !optionalKeys.contains(key)),
        )) {
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
    final GalLookupCellGridV1? cellGrid = map.containsKey('cellGrid')
        ? GalLookupCellGridV1.tryFromJson(map['cellGrid'])
        : null;
    if (map.containsKey('cellGrid') && cellGrid == null) return null;
    if (map.containsKey('quotedTextOnly') && map['quotedTextOnly'] is! bool) {
      return null;
    }
    final List<GalLookupPunctuationVisualBoundV1> punctuationVisualBounds =
        <GalLookupPunctuationVisualBoundV1>[];
    if (map.containsKey('punctuationVisualBounds')) {
      final Object? rawBounds = map['punctuationVisualBounds'];
      if (rawBounds is! List ||
          rawBounds.isEmpty ||
          rawBounds.length >
              GalLookupPunctuationVisualBoundV1.maxEntriesPerLayout ||
          cellGrid == null) {
        return null;
      }
      for (final Object? rawBound in rawBounds) {
        final GalLookupPunctuationVisualBoundV1? bound =
            GalLookupPunctuationVisualBoundV1.tryFromJson(rawBound);
        if (bound == null ||
            punctuationVisualBounds.any(
              (GalLookupPunctuationVisualBoundV1 other) =>
                  other.codePoint == bound.codePoint,
            )) {
          return null;
        }
        punctuationVisualBounds.add(bound);
      }
    }
    final List<GalLookupCharacterAdvanceV1> characterAdvances =
        <GalLookupCharacterAdvanceV1>[];
    if (map.containsKey('characterAdvances')) {
      final Object? rawAdvances = map['characterAdvances'];
      if (rawAdvances is! List ||
          rawAdvances.length >
              GalLookupCharacterAdvanceV1.maxEntriesPerLayout) {
        return null;
      }
      for (final Object? rawAdvance in rawAdvances) {
        final GalLookupCharacterAdvanceV1? advance =
            GalLookupCharacterAdvanceV1.tryFromJson(rawAdvance);
        if (advance == null ||
            characterAdvances.any(
              (GalLookupCharacterAdvanceV1 other) =>
                  other.codePoint == advance.codePoint,
            )) {
          return null;
        }
        characterAdvances.add(advance);
      }
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
      cellGrid: cellGrid,
      quotedTextOnly: map['quotedTextOnly'] == true,
      punctuationVisualBounds: punctuationVisualBounds,
      characterAdvances: characterAdvances,
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
      other.paddingPerClientHeight == paddingPerClientHeight &&
      other.cellGrid == cellGrid &&
      other.quotedTextOnly == quotedTextOnly &&
      _samePunctuationVisualBounds(
        other.punctuationVisualBounds,
        punctuationVisualBounds,
      ) &&
      _sameCharacterAdvances(other.characterAdvances, characterAdvances);

  @override
  int get hashCode => Object.hash(
    fontFamily,
    fontSizePerClientHeight,
    letterSpacingPerClientHeight,
    lineHeight,
    textAlign,
    verticalAlign,
    paddingPerClientHeight,
    cellGrid,
    quotedTextOnly,
    Object.hashAll(punctuationVisualBounds),
    Object.hashAll(characterAdvances),
  );
}

bool _samePunctuationVisualBounds(
  List<GalLookupPunctuationVisualBoundV1> left,
  List<GalLookupPunctuationVisualBoundV1> right,
) {
  if (left.length != right.length) return false;
  for (int index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameCharacterAdvances(
  List<GalLookupCharacterAdvanceV1> left,
  List<GalLookupCharacterAdvanceV1> right,
) {
  if (left.length != right.length) return false;
  for (int index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class GalLookupSurfaceVariantV1 {
  const GalLookupSurfaceVariantV1({
    required this.aspectRatio,
    required this.referenceClient,
    required this.bodyRect,
    required this.layout,
    this.slot,
  });

  final double aspectRatio;
  final GalLookupReferenceClientV1 referenceClient;
  final GalLookupNormalizedRectV1 bodyRect;
  final GalLookupTextLayoutV1 layout;

  /// Null preserves the v1 shared calibration semantics.
  final GalLookupCalibrationSlotV1? slot;

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

  double relativeClientSizeError(GalLookupReferenceClientV1 client) => math.max(
    (client.widthPx - referenceClient.widthPx).abs() / referenceClient.widthPx,
    (client.heightPx - referenceClient.heightPx).abs() /
        referenceClient.heightPx,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'aspectRatio': aspectRatio,
    'referenceClient': referenceClient.toJson(),
    'bodyRect': bodyRect.toJson(),
    'layout': layout.toJson(),
    if (slot != null) 'slot': slot!.wireName,
  };

  static GalLookupSurfaceVariantV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final Map<Object?, Object?> map = value.cast<Object?, Object?>();
    const Set<String> legacyKeys = <String>{
      'aspectRatio',
      'referenceClient',
      'bodyRect',
      'layout',
    };
    final Set<String> slotKeys = <String>{...legacyKeys, 'slot'};
    if (!_hasExactKeys(map, legacyKeys) && !_hasExactKeys(map, slotKeys)) {
      return null;
    }
    final GalLookupCalibrationSlotV1? slot = map.containsKey('slot')
        ? GalLookupCalibrationSlotV1.fromWireName(map['slot'])
        : null;
    if (map.containsKey('slot') && slot == null) return null;
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
      slot: slot,
    );
    return variant.isValid ? variant : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalLookupSurfaceVariantV1 &&
      other.aspectRatio == aspectRatio &&
      other.referenceClient == referenceClient &&
      other.bodyRect == bodyRect &&
      other.layout == layout &&
      other.slot == slot;

  @override
  int get hashCode =>
      Object.hash(aspectRatio, referenceClient, bodyRect, layout, slot);
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
  // A normalized body can be scaled safely only across nearby client sizes.
  // Large jumps often mean a game reflowed or introduced black bars; silently
  // reusing the old profile would put every hit box in the wrong place.
  static const double maxRelativeClientSizeError = 0.12;

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
    double bestSizeError = double.infinity;
    double bestAspectError = double.infinity;
    for (final GalLookupSurfaceVariantV1 variant in variants) {
      final double aspectError = variant.relativeAspectError(
        client.aspectRatio,
      );
      final double sizeError = variant.relativeClientSizeError(client);
      // Screenshot-derived cell grids are normalized geometry: once the
      // aspect ratio is unchanged, their body and per-client-height metrics
      // scale with the live client. Allow Magpie/fullscreen resolution
      // changes for that explicit layout kind. Keep the conservative size
      // gate for legacy DirectWrite settings, whose reflow cannot be proved
      // from a normalized rectangle alone.
      final bool normalizedGrid = variant.layout.cellGrid != null;
      if (aspectError <= maxRelativeAspectError &&
          (normalizedGrid || sizeError <= maxRelativeClientSizeError) &&
          (sizeError < bestSizeError ||
              sizeError == bestSizeError && aspectError < bestAspectError)) {
        best = variant;
        bestSizeError = sizeError;
        bestAspectError = aspectError;
      }
    }
    return best;
  }

  GalLookupSurfaceVariantV1? bestVariantForSourceText(
    GalLookupReferenceClientV1 client,
    String sourceText,
  ) {
    if (!client.isValid) return null;
    final GalLookupSurfaceVariantV1? dialogue = _bestVariantForClient(
      client,
      slot: GalLookupCalibrationSlotV1.dialogue,
    );
    final GalLookupSurfaceVariantV1? narration = _bestVariantForClient(
      client,
      slot: GalLookupCalibrationSlotV1.narration,
    );
    // A slot only counts when it is usable at this client size. This keeps a
    // single matching slot as the shared fallback even if a stale second slot
    // exists for a different resolution.
    if (dialogue != null && narration != null) {
      return isGalLookupDialogueText(sourceText) ? dialogue : narration;
    }
    return dialogue ?? narration ?? bestVariantForClient(client);
  }

  GalLookupSurfaceVariantV1? _bestVariantForClient(
    GalLookupReferenceClientV1 client, {
    required GalLookupCalibrationSlotV1 slot,
  }) {
    GalLookupSurfaceVariantV1? best;
    double bestSizeError = double.infinity;
    double bestAspectError = double.infinity;
    for (final GalLookupSurfaceVariantV1 variant in variants) {
      if (variant.slot != slot) continue;
      final double aspectError = variant.relativeAspectError(
        client.aspectRatio,
      );
      final double sizeError = variant.relativeClientSizeError(client);
      final bool normalizedGrid = variant.layout.cellGrid != null;
      if (aspectError <= maxRelativeAspectError &&
          (normalizedGrid || sizeError <= maxRelativeClientSizeError) &&
          (sizeError < bestSizeError ||
              sizeError == bestSizeError && aspectError < bestAspectError)) {
        best = variant;
        bestSizeError = sizeError;
        bestAspectError = aspectError;
      }
    }
    return best;
  }

  GalLookupSurfaceVariantV1? nearestVariantForClient(
    GalLookupReferenceClientV1 client, {
    GalLookupCalibrationSlotV1? slot,
  }) {
    if (!client.isValid) return null;
    GalLookupSurfaceVariantV1? nearest;
    double nearestError = double.infinity;
    for (final GalLookupSurfaceVariantV1 variant in variants) {
      if (slot != null && variant.slot != slot) continue;
      final double error = variant.relativeAspectError(client.aspectRatio);
      if (error < nearestError) {
        nearest = variant;
        nearestError = error;
      }
    }
    if (nearest == null && slot != null) {
      return nearestVariantForClient(client);
    }
    return nearest;
  }

  static bool sameReferenceClient(
    GalLookupReferenceClientV1 left,
    GalLookupReferenceClientV1 right,
  ) =>
      left.widthPx == right.widthPx &&
      left.heightPx == right.heightPx &&
      left.dpi == right.dpi;

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
