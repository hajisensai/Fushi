class ReaderSelectionData {
  ReaderSelectionData({
    required this.text,
    required this.sentence,
    this.rect,
    this.handlesRect,
    this.normalizedOffset,
    this.normalizedLength,
    this.sentenceOffset = 0,
    this.sentenceNormalizedOffset,
    this.sentenceNormalizedLength,
    this.matchableOffset,
    this.matchableLength,
    this.sentenceMatchableOffset,
    this.sentenceMatchableLength,
    this.verticalWriting = false,
    this.mangaPageIndex,
    this.audioCuePayload,
    this.fromHover = false,
  });

  factory ReaderSelectionData.fromJson(Map<String, dynamic> json) {
    Map<String, double>? rect;
    if (json['rect'] is Map) {
      final Map<String, dynamic> r = json['rect'] as Map<String, dynamic>;
      rect = <String, double>{
        'x': (r['x'] as num?)?.toDouble() ?? 0,
        'y': (r['y'] as num?)?.toDouble() ?? 0,
        'width': (r['width'] as num?)?.toDouble() ?? 0,
        'height': (r['height'] as num?)?.toDouble() ?? 0,
      };
    }
    return ReaderSelectionData(
      text: json['text'] as String? ?? '',
      sentence: json['sentence'] as String? ?? '',
      rect: rect,
      handlesRect: _readHandlesRect(json['handlesRect']),
      normalizedOffset: (json['normalizedOffset'] as num?)?.toInt(),
      normalizedLength: (json['normalizedLength'] as num?)?.toInt(),
      sentenceOffset: (json['sentenceOffset'] as num?)?.toInt() ?? 0,
      sentenceNormalizedOffset: (json['sentenceNormalizedOffset'] as num?)
          ?.toInt(),
      sentenceNormalizedLength: (json['sentenceNormalizedLength'] as num?)
          ?.toInt(),
      matchableOffset: (json['matchableOffset'] as num?)?.toInt(),
      matchableLength: (json['matchableLength'] as num?)?.toInt(),
      sentenceMatchableOffset: (json['sentenceMatchableOffset'] as num?)
          ?.toInt(),
      sentenceMatchableLength: (json['sentenceMatchableLength'] as num?)
          ?.toInt(),
      verticalWriting: json['verticalWriting'] as bool? ?? false,
      mangaPageIndex: (json['mangaPageIndex'] as num?)?.toInt(),
      audioCuePayload: json['audioCuePayload'] as String?,
      fromHover: json['fromHover'] as bool? ?? false,
    );
  }

  final String text;

  /// Cue identity from the rendered DOM, independent of study-unit offsets.
  final String? audioCuePayload;
  final String sentence;
  final Map<String, double>? rect;

  /// Union of the two grip touch targets in WebView viewport CSS pixels.
  /// Separate from the glyph anchor used by dictionary lookup.
  final Map<String, double>? handlesRect;

  /// Chapter learning-unit coordinates for navigation and persisted favorites.
  final int? normalizedOffset;
  final int? normalizedLength;
  final int sentenceOffset;
  final int? sentenceNormalizedOffset;
  final int? sentenceNormalizedLength;

  /// Audio matching coordinates, measured in normalized UTF-16 code units.
  /// Never substitute learning-unit offsets when these are unavailable.
  final int? matchableOffset;
  final int? matchableLength;
  final int? sentenceMatchableOffset;
  final int? sentenceMatchableLength;

  /// Whether the source glyph belongs to a vertical writing run.
  ///
  /// Most reader surfaces derive this from page settings. Manga OCR can mix
  /// horizontal and vertical blocks on one page, so its overlay reports the
  /// direction per hit and the popup host consumes it for anchor placement.
  final bool verticalWriting;

  /// Exact 0-based manga page containing the selected OCR glyph.
  ///
  /// This is null for EPUB and legacy manga payloads. In a two-page spread the
  /// reader must use this page, rather than the spread's first page, as the
  /// image attached to a mined card.
  final int? mangaPageIndex;

  /// 这次选词来自指针扫过（Shift 悬停 / 悬停查词），而不是一次明确的点击 / 按键。
  ///
  /// 悬停一行就会连查十几个词，宿主据此跳过「每查一次就付费一次」的旁路工作
  /// （查词按句意自动挑词条，见 `LookupOrigin.hover`）。旧 payload 没有该字段 = false。
  final bool fromHover;
}

Map<String, double>? _readHandlesRect(Object? raw) {
  if (raw is! Map) return null;
  final Map<String, double> result = <String, double>{};
  for (final String key in <String>['x', 'y', 'width', 'height']) {
    final Object? value = raw[key];
    if (value is! num || !value.toDouble().isFinite) return null;
    result[key] = value.toDouble();
  }
  if (result['width']! <= 0 || result['height']! <= 0) return null;
  return result;
}
