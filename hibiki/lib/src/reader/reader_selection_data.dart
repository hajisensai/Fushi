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
}
