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
    this.clipBytes,
    this.clipDurationMs,
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

  /// TODO-1000：浏览器扩展在播放中录到的字幕片段（webm/mp4 字节，DRM 需关硬件加速才非黑）。
  /// 非空时服务端用 ffmpeg 转 GIF + 抽音频 → 组卡（Netflix 唯一「不回放」的 GIF 路径）。
  final Uint8List? clipBytes;

  /// [clipBytes] 的时长（毫秒），供 ffmpeg 截取上界；null 时用默认上限。
  final int? clipDurationMs;

  /// true = 带了媒体/时间戳，走沉浸引擎路径；false = 纯文本挖词，走现有 mineEntry 回落。
  bool get isImmersion =>
      screenshotBytes != null ||
      clipBytes != null ||
      timestampMs != null ||
      (netflixVideoId != null && clipStartMs != null && clipEndMs != null);

  static ImmersionMinePayload fromJson(Map<String, dynamic> json) {
    final Object? rawFields = json['fields'];
    if (rawFields is! Map) {
      throw const FormatException('fields must be an object');
    }
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<Object?, Object?> e in rawFields.entries)
        '${e.key}': '${e.value}',
    };
    final Object? b64 = json['screenshotBase64'];
    final Object? clip64 = json['clipBase64'];
    return ImmersionMinePayload(
      fields: fields,
      sentence: (json['sentence'] as String?) ?? (fields['sentence'] ?? ''),
      cueSentence: json['cueSentence'] as String?,
      documentTitle: json['documentTitle'] as String?,
      timestampMs: (json['timestampMs'] as num?)?.round(),
      clipStartMs: (json['clipStartMs'] as num?)?.round(),
      clipEndMs: (json['clipEndMs'] as num?)?.round(),
      netflixVideoId: json['netflixVideoId'] as String?,
      screenshotBytes:
          b64 is String && b64.isNotEmpty ? base64Decode(b64) : null,
      clipBytes:
          clip64 is String && clip64.isNotEmpty ? base64Decode(clip64) : null,
      clipDurationMs: (json['clipDurationMs'] as num?)?.round(),
    );
  }
}
