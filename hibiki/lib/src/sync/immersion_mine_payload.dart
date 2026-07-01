import 'dart:convert';
import 'dart:typed_data';

/// server `/api/mine` 的扩展 body 解析（沉浸制卡：可带 timestamp + 截图字节 + netflix id
/// + clip 区间）。向后兼容：纯 `{fields, sentence}` 也能解析（timestamp/screenshot 为 null）。
class ImmersionMinePayload {
  const ImmersionMinePayload({
    required this.fields,
    required this.sentence,
    this.cueSentence,
    this.documentTitle,
    this.timestampMs,
    this.clipStartMs,
    this.clipEndMs,
    this.netflixVideoId,
    this.screenshotBytes,
  });

  final Map<String, String> fields;
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
  final int? timestampMs;
  final int? clipStartMs;
  final int? clipEndMs;
  final String? netflixVideoId;
  final Uint8List? screenshotBytes;

  /// true = 带了媒体/时间戳，走沉浸引擎路径；false = 纯文本挖词，走现有 mineEntry 回落。
  bool get isImmersion =>
      screenshotBytes != null ||
      timestampMs != null ||
      (netflixVideoId != null && clipStartMs != null && clipEndMs != null);

  static ImmersionMinePayload fromJson(Map<String, dynamic> json) {
    final Object? rawFields = json['fields'];
    if (rawFields is! Map) {
      throw const FormatException('fields must be an object');
    }
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<Object?, Object?> e in rawFields.entries) '${e.key}': '${e.value}',
    };
    final Object? b64 = json['screenshotBase64'];
    return ImmersionMinePayload(
      fields: fields,
      sentence: (json['sentence'] as String?) ?? (fields['sentence'] ?? ''),
      cueSentence: json['cueSentence'] as String?,
      documentTitle: json['documentTitle'] as String?,
      timestampMs: (json['timestampMs'] as num?)?.round(),
      clipStartMs: (json['clipStartMs'] as num?)?.round(),
      clipEndMs: (json['clipEndMs'] as num?)?.round(),
      netflixVideoId: json['netflixVideoId'] as String?,
      screenshotBytes: b64 is String && b64.isNotEmpty ? base64Decode(b64) : null,
    );
  }
}
