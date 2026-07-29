class ReaderSelectionData {
  ReaderSelectionData({
    required this.text,
    required this.sentence,
    this.rect,
    this.normalizedOffset,
    this.normalizedLength,
    this.sentenceOffset = 0,
    this.sentenceNormalizedOffset,
    this.sentenceNormalizedLength,
    this.verticalWriting = false,
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
      normalizedOffset: (json['normalizedOffset'] as num?)?.toInt(),
      normalizedLength: (json['normalizedLength'] as num?)?.toInt(),
      sentenceOffset: (json['sentenceOffset'] as num?)?.toInt() ?? 0,
      sentenceNormalizedOffset:
          (json['sentenceNormalizedOffset'] as num?)?.toInt(),
      sentenceNormalizedLength:
          (json['sentenceNormalizedLength'] as num?)?.toInt(),
      verticalWriting: json['verticalWriting'] as bool? ?? false,
    );
  }

  final String text;
  final String sentence;
  final Map<String, double>? rect;
  final int? normalizedOffset;
  final int? normalizedLength;
  final int sentenceOffset;
  final int? sentenceNormalizedOffset;
  final int? sentenceNormalizedLength;

  /// Whether the source glyph belongs to a vertical writing run.
  ///
  /// Most reader surfaces derive this from page settings. Manga OCR can mix
  /// horizontal and vertical blocks on one page, so its overlay reports the
  /// direction per hit and the popup host consumes it for anchor placement.
  final bool verticalWriting;
}
