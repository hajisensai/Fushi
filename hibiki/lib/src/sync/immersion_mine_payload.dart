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
    this.youtubeVideoId,
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

  /// TODO-1000（批量制卡）：YouTube 视频 ID（youtube.com 扩展制卡）。非空 + [clipStartMs]/
  /// [clipEndMs]（**视频时间**窗，非段内偏移）时，服务端 resolveYoutubeSource 取真实流 ffmpeg
  /// 精确裁 GIF+音频（非 DRM，无需录屏/回放）。
  final String? youtubeVideoId;
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
      (netflixVideoId != null && clipStartMs != null && clipEndMs != null) ||
      (youtubeVideoId != null && clipStartMs != null && clipEndMs != null);

  static ImmersionMinePayload fromJson(Map<String, dynamic> json) {
    final Object? rawFields = json['fields'];
    if (rawFields is! Map) {
      throw const FormatException('fields must be an object');
    }
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<Object?, Object?> e in rawFields.entries)
        '${e.key}': _normalizeIncomingText('${e.value}'),
    };
    final String? sentence = json['sentence'] as String?;
    final String? cueSentence = json['cueSentence'] as String?;
    final String? documentTitle = json['documentTitle'] as String?;
    return ImmersionMinePayload(
      fields: fields,
      sentence: sentence == null
          ? (fields['sentence'] ?? '')
          : _normalizeIncomingText(sentence),
      cueSentence:
          cueSentence == null ? null : _normalizeIncomingText(cueSentence),
      documentTitle: documentTitle == null
          ? null
          : _stripImmersionAudioPaths(_normalizeIncomingText(documentTitle)),
      timestampMs: (json['timestampMs'] as num?)?.round(),
      clipStartMs: (json['clipStartMs'] as num?)?.round(),
      clipEndMs: (json['clipEndMs'] as num?)?.round(),
      netflixVideoId: json['netflixVideoId'] as String?,
      youtubeVideoId: json['youtubeVideoId'] as String?,
      // 截图 / clip 是**可选媒体**：base64 坏了就当没这个媒体（降级到截图/文本卡），
      // 绝不 throw 把整张卡 400 掉——只有 fields 缺失才是真正的坏请求。
      screenshotBytes: _tryDecodeBase64(json['screenshotBase64']),
      clipBytes: _tryDecodeBase64(json['clipBase64']),
      clipDurationMs: (json['clipDurationMs'] as num?)?.round(),
    );
  }

  /// 容错 base64 解码：非字符串/空/格式错都返回 null（媒体缺失即降级，不抛异常）。
  static Uint8List? _tryDecodeBase64(Object? value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }
}

final RegExp _percentEscape = RegExp(r'%[0-9A-Fa-f]{2}');
final RegExp _japaneseOrCjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');
final RegExp _immersionAudioPath = RegExp(
  r'''(^|\s)(?:/var/mobile/[^\s<>"']*|[^\s<>"']*[/\\])immersion_audio\.(?:aac|m4a|mp3|wav)\b''',
);

String _normalizeIncomingText(String value) {
  final hasPercentEscape = _percentEscape.hasMatch(value);
  final separatorPlusCount = _separatorPlusCount(value);
  final shouldTreatPlusAsSpace = hasPercentEscape ||
      separatorPlusCount >= 2 ||
      (separatorPlusCount == 1 && _japaneseOrCjk.hasMatch(value));
  if (!hasPercentEscape && !shouldTreatPlusAsSpace) return value;

  final candidate =
      shouldTreatPlusAsSpace ? _replaceSeparatorPluses(value) : value;
  if (!hasPercentEscape) return candidate;
  return _decodePercentEscapes(candidate);
}

int _separatorPlusCount(String value) {
  var count = 0;
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) != 0x2b) continue;
    final prevIsPlus = i > 0 && value.codeUnitAt(i - 1) == 0x2b;
    final nextIsPlus = i + 1 < value.length && value.codeUnitAt(i + 1) == 0x2b;
    if (!prevIsPlus && !nextIsPlus) count++;
  }
  return count;
}

String _replaceSeparatorPluses(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);
    if (codeUnit != 0x2b) {
      buffer.writeCharCode(codeUnit);
      continue;
    }
    final prevIsPlus = i > 0 && value.codeUnitAt(i - 1) == 0x2b;
    final nextIsPlus = i + 1 < value.length && value.codeUnitAt(i + 1) == 0x2b;
    buffer.write(prevIsPlus || nextIsPlus ? '+' : ' ');
  }
  return buffer.toString();
}

String _decodePercentEscapes(String value) {
  final buffer = StringBuffer();
  final bytes = <int>[];

  void flushBytes() {
    if (bytes.isEmpty) return;
    buffer.write(utf8.decode(bytes, allowMalformed: true));
    bytes.clear();
  }

  for (var i = 0; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);
    if (codeUnit == 0x25 && i + 2 < value.length) {
      final byte = _hexByte(value.codeUnitAt(i + 1), value.codeUnitAt(i + 2));
      if (byte != null) {
        bytes.add(byte);
        i += 2;
        continue;
      }
    }
    flushBytes();
    buffer.writeCharCode(codeUnit);
  }
  flushBytes();
  return buffer.toString();
}

int? _hexByte(int high, int low) {
  final highNibble = _hexNibble(high);
  final lowNibble = _hexNibble(low);
  if (highNibble == null || lowNibble == null) return null;
  return (highNibble << 4) | lowNibble;
}

int? _hexNibble(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  return null;
}

String _stripImmersionAudioPaths(String value) => value
    .replaceAll(_immersionAudioPath, ' ')
    .replaceAll(RegExp(r'[ \t]+\n'), '\n')
    .replaceAll(RegExp(r'\n{2,}'), '\n')
    .trim();
